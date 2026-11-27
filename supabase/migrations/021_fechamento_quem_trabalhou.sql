-- 021 · Fechamento: entra todo motoboy que trabalhou no dia (fez coleta), mesmo sem entrega concluída
-- Antes, quem estava na 1ª viagem do dia não aparecia na prévia (só entregas concluídas contavam).
-- Diária: devida a quem coletou ao menos um pedido no dia. Entregas: só as concluídas são pagas.
-- Nova coluna em_aberto: pedidos coletados e ainda não concluídos (aparece como "em rota" na prévia).
drop function if exists public.fechamento_resumo(uuid, date, date);
create function public.fechamento_resumo(p_loja uuid, p_ini date, p_fim date)
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
  r as (select j.*, rg.diaria rdiaria, rg.minimo_dia
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
