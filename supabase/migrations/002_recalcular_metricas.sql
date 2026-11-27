-- Regras (iguais a scripts/foody_metricas.py):
-- viagem = pedidos do mesmo entregador coletados antes da 1ª entrega válida da viagem (tolerância 2 min);
-- baixa imediata: coleta→entrega < 2 min; baixa no retorno: entrega a ±2 min de uma coleta posterior;
-- lote: 2º+ pedido < 1 min após o anterior; rápido: 1º trecho > 45 km/h; trânsito > 60 min;
-- despacho fora de 2–60 min e total > 120 min saem das médias; hiato > 60 min = pausa.
create or replace function public.recalcular_metricas(p_loja uuid, p_dia date)
returns int language plpgsql security definer set search_path = public as $$
declare
  r record;
  v_ent text := null;
  v_trip int := 0;
  v_min_valid timestamptz;
  v_max_col timestamptz;
  v_novo boolean;
  v_n int;
begin
  drop table if exists _p;
  create temp table _p on commit drop as
  select p.uid, p.entregador, p.aberto_em, p.despachado_em, p.coletado_em, p.entregue_em, p.prazo_em, p.km_rota,
         (p.entregue_em - p.coletado_em) < interval '2 minutes' as imediata,
         false as retorno, 0 as trip
  from public.pedidos p
  where p.loja_id = p_loja and p.dia = p_dia
    and p.status not in ('cancelled','rejected')
    and coalesce(trim(p.entregador),'') <> '' and p.coletado_em is not null;

  update _p a set imediata = coalesce(a.imediata,false);
  update _p a set retorno = true
  where not a.imediata and a.entregue_em is not null and exists (
    select 1 from _p b where b.entregador = a.entregador and b.coletado_em > a.coletado_em
      and abs(extract(epoch from (a.entregue_em - b.coletado_em))) <= 120);

  for r in select uid, entregador, coletado_em from _p order by entregador, coletado_em, uid loop
    if v_ent is distinct from r.entregador then
      v_novo := true;
    else
      select min(entregue_em) filter (where not imediata), max(coletado_em)
        into v_min_valid, v_max_col from _p where trip = v_trip;
      if v_min_valid is not null then
        v_novo := r.coletado_em > v_min_valid - interval '2 minutes';
      else
        v_novo := r.coletado_em - v_max_col > interval '5 minutes';
      end if;
    end if;
    if v_novo then v_trip := v_trip + 1; end if;
    update _p set trip = v_trip where uid = r.uid;
    v_ent := r.entregador;
  end loop;

  delete from public.pedido_metricas where loja_id = p_loja and dia = p_dia;
  delete from public.viagens where loja_id = p_loja and dia = p_dia;

  drop table if exists _v;
  create temp table _v on commit drop as
  select trip, min(entregador) entregador, max(coletado_em) saida_em, max(entregue_em) fim_em, count(*)::int n,
         bool_or(imediata or retorno) suspeita
  from _p group by trip;

  drop table if exists _vg;
  create temp table _vg on commit drop as
  select v.*,
         extract(epoch from (fim_em - saida_em))/60 as rota,
         extract(epoch from (lead(saida_em) over w - fim_em))/60 as gap
  from _v v window w as (partition by entregador order by saida_em);

  drop table if exists _ids;
  create temp table _ids (trip int, id bigint) on commit drop;
  with ins as (
    insert into public.viagens (loja_id, dia, entregador, saida_em, fim_em, pedidos, tempo_rota_min,
                                hiato_depois_min, retorno_ocioso_depois_min, baixa_suspeita)
    select p_loja, p_dia, entregador, saida_em, fim_em, n, round(rota::numeric,2),
           case when gap between 0 and 60 then round(gap::numeric,2) end,
           case when gap between 0 and 60 and not suspeita then round(gap::numeric,2) end,
           suspeita
    from _vg order by trip
    returning id, entregador, saida_em
  )
  insert into _ids select g.trip, ins.id from ins join _vg g on g.entregador = ins.entregador and g.saida_em = ins.saida_em;

  insert into public.pedido_metricas (uid, loja_id, dia, viagem_id, entregador, posicao, pedidos_na_viagem,
    t_ate_despacho_min, t_espera_saida_min, t_transito_min, t_total_min, km_rota, vel_kmh, no_prazo, baixa,
    motivo_exclusao, excluir_despacho, excluir_total)
  select x.uid, p_loja, p_dia, i.id, x.entregador, x.pos, x.n, x.t1, x.t2, x.t3, x.tot, x.km_rota,
         x.vel, x.no_prazo,
         case when x.imediata then 'imediata' when x.retorno then 'retorno' end,
         case when x.imediata then 'baixa imediata'
              when x.retorno then 'baixa no retorno'
              when x.pos > 1 and x.t3 < 1 then 'baixa em lote'
              when x.vel > 45 then 'rápido demais'
              when x.t3 > 60 then 'trânsito > 60 min' end,
         (x.t1 is null or x.t1 < 2 or x.t1 > 60),
         (x.tot is null or x.tot > 120)
  from (
    select p.*, v.n,
      row_number() over w as pos,
      round((extract(epoch from (p.despachado_em - p.aberto_em))/60)::numeric,2) t1,
      round((extract(epoch from (v.saida_em - p.despachado_em))/60)::numeric,2) t2,
      round((extract(epoch from (p.entregue_em - coalesce(lag(p.entregue_em) over w, v.saida_em)))/60)::numeric,2) t3,
      round((extract(epoch from (p.entregue_em - p.aberto_em))/60)::numeric,2) tot,
      case when p.prazo_em is not null and p.entregue_em is not null then p.entregue_em <= p.prazo_em end no_prazo,
      case when row_number() over w = 1 and p.km_rota is not null and p.entregue_em > v.saida_em
           then round((p.km_rota / (extract(epoch from (p.entregue_em - v.saida_em))/3600))::numeric,1) end vel
    from _p p join _v v using (trip)
    where p.entregue_em is not null
    window w as (partition by p.trip order by p.entregue_em, p.uid)
  ) x join _ids i on i.trip = x.trip;

  get diagnostics v_n = row_count;
  return v_n;
end $$;
revoke all on function public.recalcular_metricas(uuid, date) from public, anon, authenticated;
grant execute on function public.recalcular_metricas(uuid, date) to service_role;

-- Produtividade por entregador e dia (horas ativas = rota + hiatos até 60 min)
create or replace view public.v_produtividade with (security_invoker = true) as
select v.loja_id, v.dia, v.entregador,
  sum(v.pedidos)::int as entregas,
  round((sum(coalesce(v.tempo_rota_min,0)) + sum(coalesce(v.hiato_depois_min,0)))/60, 2) as horas_ativas,
  round(sum(coalesce(v.tempo_rota_min,0)) / nullif(sum(coalesce(v.tempo_rota_min,0)) + sum(coalesce(v.hiato_depois_min,0)),0) * 100, 1) as pct_em_rota,
  (select round(avg(m.t_transito_min),1) from public.pedido_metricas m
     where m.loja_id = v.loja_id and m.dia = v.dia and m.entregador = v.entregador and m.motivo_exclusao is null) as transito_medio_min,
  (select round(avg(case when m.no_prazo then 100 else 0 end),1) from public.pedido_metricas m
     where m.loja_id = v.loja_id and m.dia = v.dia and m.entregador = v.entregador and m.no_prazo is not null) as pct_no_prazo,
  (select round(avg(case when m.baixa is not null then 100 else 0 end),1) from public.pedido_metricas m
     where m.loja_id = v.loja_id and m.dia = v.dia and m.entregador = v.entregador) as pct_baixa_suspeita
from public.viagens v
group by v.loja_id, v.dia, v.entregador;
