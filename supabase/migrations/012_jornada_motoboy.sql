alter table public.lojas add column if not exists teto_viagem_min int not null default 60;
comment on column public.lojas.teto_viagem_min is 'Hora trabalhada: viagem cuja última entrega passa disso após a saída conta como este teto';

-- Jornada do motoboy no dia: da 1ª coleta até a última entrega.
-- A viagem que fecha o dia é limitada ao teto (saída + teto_viagem_min) para não inflar a jornada com baixa esquecida.
create or replace view public.v_jornada with (security_invoker = true) as
with ped as (
  select m.loja_id, m.dia, m.entregador, p.coletado_em, p.entregue_em, p.qtd_pizzas
  from public.pedido_metricas m join public.pedidos p using (uid)
  where m.entregador is not null
),
agg as (
  select loja_id, dia, entregador, min(coletado_em) primeira_coleta, max(entregue_em) ultima_entrega,
         count(*) entregas, sum(qtd_pizzas) pizzas
  from ped group by 1,2,3
),
via as (
  select v.loja_id, v.dia, v.entregador, count(*) viagens,
         sum(least(coalesce(v.tempo_rota_min,0), l.teto_viagem_min)) rota_min_limitada,
         (array_agg(least(coalesce(v.fim_em, v.saida_em), v.saida_em + make_interval(mins => l.teto_viagem_min))
                    order by v.saida_em desc))[1] fim_limitado
  from public.viagens v join public.lojas l on l.id = v.loja_id
  group by 1,2,3
)
select a.loja_id, a.dia, a.entregador, a.primeira_coleta, a.ultima_entrega, v.fim_limitado,
  a.entregas, v.viagens, a.pizzas,
  round((extract(epoch from (greatest(v.fim_limitado, a.primeira_coleta) - a.primeira_coleta))/3600)::numeric, 2) as horas_trabalhadas,
  round((v.rota_min_limitada/60)::numeric, 2) as horas_em_rota
from agg a join via v using (loja_id, dia, entregador);

grant select on public.v_jornada to authenticated;
revoke select on public.v_jornada from anon;
