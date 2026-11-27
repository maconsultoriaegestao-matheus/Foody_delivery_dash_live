alter table public.lojas drop column if exists meta_vendas_dia, drop column if exists meta_viagens_dia;

-- Metas diárias por dia da semana (0 = domingo ... 6 = sábado, pelo dia operacional)
create table public.metas_semana (
  loja_id uuid not null references public.lojas(id) on delete cascade,
  dia_semana smallint not null check (dia_semana between 0 and 6),
  meta_vendas numeric(12,2),
  meta_viagens int,
  atualizado_em timestamptz not null default now(),
  primary key (loja_id, dia_semana)
);
alter table public.metas_semana enable row level security;
create policy metas_leitura on public.metas_semana for select to authenticated using (privado.pode_ver_loja(loja_id));

-- Sugestão a partir do histórico: por dia da semana, últimas N semanas (dias com pedidos)
create or replace function public.sugestao_metas(p_loja uuid, p_semanas int default 8)
returns table (dia_semana int, dias int, vendas_media numeric, vendas_p75 numeric, viagens_media numeric, viagens_p75 numeric)
language sql stable security definer set search_path = public as $$
  with d as (
    select dia, sum(valor_total) vendas
    from pedidos where loja_id = p_loja and status not in ('cancelled','rejected')
      and dia >= (current_date - (p_semanas * 7)) and dia < ((now() at time zone 'America/Sao_Paulo') - interval '5 hours')::date
    group by dia),
  v as (select dia, count(*) viagens from viagens where loja_id = p_loja group by dia)
  select extract(dow from d.dia)::int, count(*)::int,
    round(avg(d.vendas)), round(percentile_cont(0.75) within group (order by d.vendas)::numeric),
    round(avg(coalesce(v.viagens,0))), round(percentile_cont(0.75) within group (order by coalesce(v.viagens,0))::numeric)
  from d left join v using (dia)
  group by 1 order by 1;
$$;
revoke all on function public.sugestao_metas(uuid, int) from public, anon, authenticated;
grant execute on function public.sugestao_metas(uuid, int) to service_role;
