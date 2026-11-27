-- 023 · Diária e mínimo garantido diferentes por dia da semana
-- Arrays de 7 posições (1 = domingo ... 7 = sábado). Posição vazia (null) = usa a diária/mínimo padrão da regra.
alter table public.regras_pagamento
  add column if not exists diaria_semana numeric(10,2)[],
  add column if not exists minimo_semana numeric(10,2)[];
alter table public.regras_pagamento drop constraint if exists regras_semana_7;
alter table public.regras_pagamento add constraint regras_semana_7 check (
  (diaria_semana is null or array_length(diaria_semana, 1) = 7) and
  (minimo_semana is null or array_length(minimo_semana, 1) = 7));
comment on column public.regras_pagamento.diaria_semana is 'Diária por dia da semana [dom, seg, ter, qua, qui, sex, sáb]; null na posição = diária padrão';
comment on column public.regras_pagamento.minimo_semana is 'Mínimo garantido por dia da semana [dom..sáb]; null na posição = mínimo padrão';

create or replace function public.fechamento_resumo(p_loja uuid, p_ini date, p_fim date)
returns table (dia date, entregador text, entregas int, km numeric, valor_entregas numeric, diaria numeric,
               ajuste_minimo numeric, extras numeric, descontos numeric, total numeric, alertas int, em_aberto int)
language sql stable security definer set search_path = public as $$
  with e as (select * from public.fechamento_entregas(p_loja, p_ini, p_fim)),
  d as (select e.dia, e.entregador, count(*)::int entregas, sum(e.km) km, sum(e.valor) valor_entregas,
               count(e.alerta)::int alertas
        from e group by 1, 2),
  t as (select p.dia, min(trim(p.entregador)) entregador,
               count(*) filter (where not (p.status in ('delivered', 'closed') and p.entregue_em is not null))::int em_aberto
        from public.pedidos p
        where p.loja_id = p_loja and p.dia between p_ini and p_fim
          and p.status not in ('cancelled', 'rejected')
          and coalesce(trim(p.entregador), '') <> ''
          and (p.coletado_em is not null or p.entregue_em is not null)
        group by p.dia, lower(trim(p.entregador))),
  l as (select x.dia, x.entregador,
               coalesce(sum(x.valor) filter (where x.tipo = 'extra'), 0) extras,
               coalesce(sum(x.valor) filter (where x.tipo in ('desconto', 'vale')), 0) descontos
        from public.lancamentos_entregador x
        where x.loja_id = p_loja and x.dia between p_ini and p_fim group by 1, 2),
  base as (select coalesce(t.dia, d.dia) dia, coalesce(d.entregador, t.entregador) entregador,
                  coalesce(d.entregas, 0) entregas, d.km, coalesce(d.valor_entregas, 0) valor_entregas,
                  coalesce(d.alertas, 0) alertas, coalesce(t.em_aberto, 0) em_aberto
           from t full join d on d.dia = t.dia and lower(d.entregador) = lower(t.entregador)),
  j as (select coalesce(b.dia, l.dia) dia, coalesce(b.entregador, l.entregador) entregador,
               coalesce(b.entregas, 0) entregas, round(b.km, 1) km, coalesce(b.valor_entregas, 0) valor_entregas,
               (b.entregador is not null) trabalhou, coalesce(l.extras, 0) extras, coalesce(l.descontos, 0) descontos,
               coalesce(b.alertas, 0) alertas, coalesce(b.em_aberto, 0) em_aberto
        from base b full join l on l.dia = b.dia and lower(l.entregador) = lower(b.entregador)),
  r as (select j.*,
               coalesce(rg.diaria_semana[extract(dow from j.dia)::int + 1], rg.diaria) rdiaria,
               coalesce(rg.minimo_semana[extract(dow from j.dia)::int + 1], rg.minimo_dia) minimo_dia
        from j left join lateral (select * from public.regras_pagamento x
                                   where x.loja_id = p_loja and x.vigente_desde <= j.dia
                                   order by x.vigente_desde desc limit 1) rg on true),
  m as (select r.*, case when r.trabalhou then coalesce(r.rdiaria, 0) else 0 end diaria from r),
  n as (select m.*, case when m.trabalhou and m.minimo_dia is not null
                         then greatest(m.minimo_dia - (m.diaria + m.valor_entregas), 0) else 0 end ajuste_minimo
        from m)
  select n.dia, n.entregador, n.entregas, n.km, n.valor_entregas, n.diaria, n.ajuste_minimo, n.extras, n.descontos,
         n.valor_entregas + n.diaria + n.ajuste_minimo + n.extras - n.descontos, n.alertas, n.em_aberto
  from n order by n.dia, n.entregador;
$$;
revoke all on function public.fechamento_resumo(uuid, date, date) from public, anon;
grant execute on function public.fechamento_resumo(uuid, date, date) to authenticated;
