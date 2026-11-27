create or replace view public.v_dash_pedidos with (security_invoker = true) as
select m.loja_id, m.dia,
  extract(hour from p.aberto_em at time zone l.fuso)::int as hora,
  m.entregador, m.t_ate_despacho_min as t1, m.t_espera_saida_min as t2, m.t_transito_min as t3, m.t_total_min as total,
  m.no_prazo, m.motivo_exclusao, m.excluir_despacho, m.excluir_total,
  m.pedidos_na_viagem as nv, m.posicao as pos, m.km_rota as km, p.valor_total as valor, p.canal, m.viagem_id as viagem
from public.pedido_metricas m
join public.pedidos p using (uid)
join public.lojas l on l.id = m.loja_id;

create or replace view public.v_dash_viagens with (security_invoker = true) as
select v.loja_id, v.id as viagem, v.dia, v.entregador as motoboy,
  extract(hour from v.saida_em at time zone l.fuso)::int as hora_saida,
  v.pedidos, v.tempo_rota_min as rota, v.hiato_depois_min as hiato, v.retorno_ocioso_depois_min as ocioso, v.baixa_suspeita as suspeita
from public.viagens v join public.lojas l on l.id = v.loja_id;

grant select on public.v_dash_pedidos, public.v_dash_viagens, public.v_produtividade to authenticated;
revoke select on public.v_dash_pedidos, public.v_dash_viagens, public.v_produtividade from anon;
