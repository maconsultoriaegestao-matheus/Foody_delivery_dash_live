-- 015 · Retaguarda: regras de pagamento dos entregadores e fechamento diário/semanal
-- Pagamento = diária (por dia trabalhado) + valor por entrega conforme faixa de km
--             + ajuste até o mínimo garantido (opcional) + extras − descontos/vales.
-- Só gestores (papel 'gestor') e administradores veem e alteram valores.

-- 1) km em linha reta (raio) ao lado do km de rota estimado
alter table public.pedidos add column if not exists km_raio numeric;
update public.pedidos set km_raio = round(greatest(km_rota - 0.55, 0) / 1.18, 2)
 where km_raio is null and km_rota is not null;

-- 2) permissão de gestão (admin global, ou gestor da unidade / do cliente)
create or replace function privado.pode_gerir_loja(p_loja uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.acessos a
    left join public.lojas l on l.id = p_loja
    where a.user_id = (select auth.uid())
      and a.papel in ('admin', 'gestor')
      and (a.loja_id = p_loja
           or (a.cliente_id is not null and a.cliente_id = l.cliente_id)
           or (a.loja_id is null and a.cliente_id is null)));
$$;

-- 3) regras (versionadas por data de início)
create table if not exists public.regras_pagamento (
  id bigint generated always as identity primary key,
  loja_id uuid not null references public.lojas(id) on delete cascade,
  vigente_desde date not null,
  diaria numeric(10,2) not null default 0 check (diaria >= 0),
  base_km text not null default 'rota' check (base_km in ('raio', 'rota')),
  minimo_dia numeric(10,2) check (minimo_dia is null or minimo_dia >= 0),
  faixas jsonb not null check (jsonb_typeof(faixas) = 'array' and jsonb_array_length(faixas) > 0),
  obs text,
  criado_em timestamptz not null default now(),
  criado_por uuid default auth.uid(),
  unique (loja_id, vigente_desde)
);
comment on column public.regras_pagamento.faixas is
  '[{"ate_km":3,"valor":6},{"ate_km":5,"valor":8},{"ate_km":null,"valor":12}] — ate_km null = acima da faixa anterior';

-- 4) lançamentos manuais
create table if not exists public.lancamentos_entregador (
  id bigint generated always as identity primary key,
  loja_id uuid not null references public.lojas(id) on delete cascade,
  dia date not null,
  entregador text not null,
  tipo text not null check (tipo in ('extra', 'desconto', 'vale')),
  valor numeric(10,2) not null check (valor > 0),
  descricao text,
  criado_em timestamptz not null default now(),
  criado_por uuid default auth.uid()
);
create index if not exists lancamentos_entregador_loja_dia on public.lancamentos_entregador (loja_id, dia);

-- 5) fechamentos (fotografia dos valores no momento do fechamento)
create table if not exists public.fechamentos (
  id bigint generated always as identity primary key,
  loja_id uuid not null references public.lojas(id) on delete cascade,
  inicio date not null,
  fim date not null check (fim >= inicio),
  total numeric(12,2) not null,
  itens jsonb not null,
  fechado_em timestamptz not null default now(),
  fechado_por uuid default auth.uid(),
  fechado_por_email text
);
create index if not exists fechamentos_loja on public.fechamentos (loja_id, inicio, fim);

-- lançamento não pode cair em dia já fechado
create or replace function privado.tg_lancamento_dia_aberto() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_loja uuid; v_dia date;
begin
  v_loja := coalesce(new.loja_id, old.loja_id);
  for v_dia in select x from unnest(array[case when tg_op <> 'INSERT' then old.dia end,
                                          case when tg_op <> 'DELETE' then new.dia end]) x where x is not null loop
    if exists (select 1 from public.fechamentos f where f.loja_id = v_loja and v_dia between f.inicio and f.fim) then
      raise exception 'O dia % já está fechado. Reabra o fechamento para alterar.', to_char(v_dia, 'DD/MM/YYYY');
    end if;
  end loop;
  return coalesce(new, old);
end $$;
drop trigger if exists lancamento_dia_aberto on public.lancamentos_entregador;
create trigger lancamento_dia_aberto before insert or update or delete on public.lancamentos_entregador
  for each row execute function privado.tg_lancamento_dia_aberto();

-- RLS
alter table public.regras_pagamento enable row level security;
alter table public.lancamentos_entregador enable row level security;
alter table public.fechamentos enable row level security;

drop policy if exists regras_gestor on public.regras_pagamento;
create policy regras_gestor on public.regras_pagamento for all to authenticated
  using (privado.pode_gerir_loja(loja_id)) with check (privado.pode_gerir_loja(loja_id));
drop policy if exists lanc_gestor on public.lancamentos_entregador;
create policy lanc_gestor on public.lancamentos_entregador for all to authenticated
  using (privado.pode_gerir_loja(loja_id)) with check (privado.pode_gerir_loja(loja_id));
drop policy if exists fech_ler on public.fechamentos;
create policy fech_ler on public.fechamentos for select to authenticated using (privado.pode_gerir_loja(loja_id));
-- fechar/reabrir só pelas funções abaixo

-- 6) cálculo por entrega
create or replace function public.fechamento_entregas(p_loja uuid, p_ini date, p_fim date)
returns table (dia date, entregador text, uid text, numero text, entregue_em timestamptz,
               km numeric, base_km text, valor numeric, regra_id bigint, alerta text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not privado.pode_gerir_loja(p_loja) then raise exception 'Sem permissão para esta unidade.'; end if;
  if p_fim < p_ini or p_fim - p_ini > 62 then raise exception 'Período inválido (máximo 63 dias).'; end if;
  return query
  select p.dia, p.entregador, p.uid, p.numero, p.entregue_em,
         round(k.km, 2), r.base_km,
         coalesce(fx.valor, 0)::numeric,
         r.id,
         case when r.id is null then 'sem regra'
              when k.km is null then 'sem km (1ª faixa)'
              when fx.acima then 'acima da última faixa' end
  from public.pedidos p
  left join lateral (select * from public.regras_pagamento r
                      where r.loja_id = p_loja and r.vigente_desde <= p.dia
                      order by r.vigente_desde desc limit 1) r on true
  cross join lateral (select case when r.base_km = 'raio' then p.km_raio else p.km_rota end as km) k
  left join lateral (
    with f as (select (x->>'ate_km')::numeric as ate, (x->>'valor')::numeric as valor
               from jsonb_array_elements(r.faixas) x)
    select coalesce(
             (select f.valor from f where k.km is not null and (f.ate is null or round(k.km, 2) <= f.ate)
               order by f.ate nulls last limit 1),
             case when k.km is null then (select f.valor from f order by f.ate nulls last limit 1)
                  else (select f.valor from f order by f.ate desc nulls first limit 1) end) as valor,
           (k.km is not null and not exists (select 1 from f where f.ate is null or round(k.km, 2) <= f.ate)) as acima
  ) fx on r.id is not null
  where p.loja_id = p_loja and p.dia between p_ini and p_fim
    and p.status in ('delivered', 'closed')
    and p.entregador is not null and p.entregue_em is not null
  order by p.dia, p.entregador, p.entregue_em;
end $$;

-- 7) resumo por dia e entregador
create or replace function public.fechamento_resumo(p_loja uuid, p_ini date, p_fim date)
returns table (dia date, entregador text, entregas int, km numeric, valor_entregas numeric, diaria numeric,
               ajuste_minimo numeric, extras numeric, descontos numeric, total numeric, alertas int)
language sql stable security definer set search_path = public as $$
  with e as (select * from public.fechamento_entregas(p_loja, p_ini, p_fim)),
  d as (select e.dia, e.entregador, count(*)::int entregas, sum(e.km) km, sum(e.valor) valor_entregas,
               count(e.alerta)::int alertas, max(e.regra_id) regra_id
        from e group by 1, 2),
  l as (select x.dia, x.entregador,
               coalesce(sum(x.valor) filter (where x.tipo = 'extra'), 0) extras,
               coalesce(sum(x.valor) filter (where x.tipo in ('desconto', 'vale')), 0) descontos
        from public.lancamentos_entregador x
        where x.loja_id = p_loja and x.dia between p_ini and p_fim group by 1, 2),
  j as (select coalesce(d.dia, l.dia) dia, coalesce(d.entregador, l.entregador) entregador,
               coalesce(d.entregas, 0) entregas, round(d.km, 1) km, coalesce(d.valor_entregas, 0) valor_entregas,
               case when d.entregas > 0 then coalesce(r.diaria, 0) else 0 end diaria,
               r.minimo_dia, coalesce(l.extras, 0) extras, coalesce(l.descontos, 0) descontos, coalesce(d.alertas, 0) alertas
        from d full join l on l.dia = d.dia and l.entregador = d.entregador
        left join public.regras_pagamento r on r.id = d.regra_id),
  m as (select j.*, case when j.entregas > 0 and j.minimo_dia is not null
                         then greatest(j.minimo_dia - (j.diaria + j.valor_entregas), 0) else 0 end ajuste_minimo
        from j)
  select m.dia, m.entregador, m.entregas, m.km, m.valor_entregas, m.diaria, m.ajuste_minimo, m.extras, m.descontos,
         m.valor_entregas + m.diaria + m.ajuste_minimo + m.extras - m.descontos, m.alertas
  from m order by m.dia, m.entregador;
$$;

-- 8) fechar / reabrir
create or replace function public.fechar_periodo(p_loja uuid, p_ini date, p_fim date) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_id bigint; v_res jsonb; v_ent jsonb; v_tot numeric;
begin
  if not privado.pode_gerir_loja(p_loja) then raise exception 'Sem permissão para esta unidade.'; end if;
  if exists (select 1 from public.fechamentos f where f.loja_id = p_loja and f.inicio <= p_fim and f.fim >= p_ini) then
    raise exception 'Parte deste período já está fechada. Reabra o fechamento anterior ou escolha outro período.';
  end if;
  if p_fim >= (now() at time zone 'America/Sao_Paulo' - interval '5 hours')::date then
    raise exception 'Só é possível fechar dias já encerrados (o dia operacional vira às 05h).';
  end if;
  select coalesce(jsonb_agg(to_jsonb(r)), '[]'), coalesce(sum(r.total), 0) into v_res, v_tot
    from public.fechamento_resumo(p_loja, p_ini, p_fim) r;
  select coalesce(jsonb_agg(to_jsonb(e)), '[]') into v_ent from public.fechamento_entregas(p_loja, p_ini, p_fim) e;
  insert into public.fechamentos (loja_id, inicio, fim, total, itens, fechado_por_email)
  values (p_loja, p_ini, p_fim, v_tot,
          jsonb_build_object('resumo', v_res, 'entregas', v_ent,
            'regras', (select coalesce(jsonb_agg(to_jsonb(r)), '[]') from public.regras_pagamento r
                        where r.id in (select distinct (x->>'regra_id')::bigint from jsonb_array_elements(v_ent) x))),
          (select email from auth.users where id = auth.uid()))
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.reabrir_periodo(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare v_loja uuid;
begin
  select loja_id into v_loja from public.fechamentos where id = p_id;
  if v_loja is null then raise exception 'Fechamento não encontrado.'; end if;
  if not privado.pode_gerir_loja(v_loja) then raise exception 'Sem permissão para esta unidade.'; end if;
  delete from public.fechamentos where id = p_id;
end $$;

revoke all on function public.fechamento_entregas(uuid, date, date) from public, anon;
revoke all on function public.fechamento_resumo(uuid, date, date) from public, anon;
revoke all on function public.fechar_periodo(uuid, date, date) from public, anon;
revoke all on function public.reabrir_periodo(bigint) from public, anon;
grant execute on function public.fechamento_entregas(uuid, date, date) to authenticated;
grant execute on function public.fechamento_resumo(uuid, date, date) to authenticated;
grant execute on function public.fechar_periodo(uuid, date, date) to authenticated;
grant execute on function public.reabrir_periodo(bigint) to authenticated;
grant select, insert, update, delete on public.regras_pagamento, public.lancamentos_entregador to authenticated;
grant select on public.fechamentos to authenticated;

-- 9) a tela pergunta se o usuário pode ver a aba Fechamento
create or replace function public.posso_gerir(p_loja uuid) returns boolean
language sql stable security definer set search_path = public as $$ select privado.pode_gerir_loja(p_loja) $$;
revoke all on function public.posso_gerir(uuid) from public, anon;
grant execute on function public.posso_gerir(uuid) to authenticated;
