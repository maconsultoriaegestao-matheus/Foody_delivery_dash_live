-- 025 · Duas correções em recalcular_metricas
-- a) Prazo anterior à abertura do pedido não vale (ex.: pedido reenviado pela Brendi com o prazo do original):
--    o pedido fica sem prazo, não conta como atrasado e sai do "% no prazo".
-- c) Pedido que mudou de unidade deixava a métrica antiga na outra unidade (chave duplicada): agora a métrica
--    do pedido é apagada pelo uid antes de regravar.
-- b) Viagens do mesmo motoboy com a mesma hora de saída duplicavam as métricas (erro de chave duplicada que
--    impedia o recálculo do dia). Agora o id de cada viagem é reservado antes, sem depender de entregador+saída.
do $$
declare d text;
begin
  d := pg_get_functiondef('public.recalcular_metricas(uuid,date)'::regprocedure);
  d := replace(d, 'case when p.prazo_em is not null and p.entregue_em is not null then p.entregue_em <= p.prazo_em end no_prazo',
                  'case when p.prazo_em is not null and p.prazo_em > p.aberto_em and p.entregue_em is not null then p.entregue_em <= p.prazo_em end no_prazo');
  d := replace(d, $old$  create temp table _ids (trip int, id bigint) on commit drop;
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
  insert into _ids select g.trip, ins.id from ins join _vg g on g.entregador = ins.entregador and g.saida_em = ins.saida_em;$old$,
  $new$  create temp table _ids on commit drop as
    select trip, nextval(pg_get_serial_sequence('public.viagens', 'id')) as id from _vg;
  insert into public.viagens (id, loja_id, dia, entregador, saida_em, fim_em, pedidos, tempo_rota_min,
                              hiato_depois_min, retorno_ocioso_depois_min, baixa_suspeita)
  overriding system value
  select i.id, p_loja, p_dia, g.entregador, g.saida_em, g.fim_em, g.n, round(g.rota::numeric,2),
         case when g.gap between 0 and 60 then round(g.gap::numeric,2) end,
         case when g.gap between 0 and 60 and not g.suspeita then round(g.gap::numeric,2) end,
         g.suspeita
  from _vg g join _ids i using (trip) order by g.trip;$new$);
  d := replace(d, 'delete from public.pedido_metricas where loja_id = p_loja and dia = p_dia;',
                  'delete from public.pedido_metricas where loja_id = p_loja and dia = p_dia;
  delete from public.pedido_metricas where uid in (select uid from _p);');
  if position('where uid in (select uid from _p)' in d) = 0 then raise exception 'trecho do delete não encontrado'; end if;
  if position('p.prazo_em > p.aberto_em' in d) = 0 then raise exception 'trecho do prazo não encontrado'; end if;
  if position('overriding system value' in d) = 0 then raise exception 'trecho das viagens não encontrado'; end if;
  execute d;
end $$;

-- recalcula os dias afetados (prazo inválido ou métricas desatualizadas de hoje e ontem)
do $$
declare r record;
begin
  for r in select distinct loja_id, dia from public.pedidos
            where dia is not null and ((prazo_em is not null and prazo_em <= aberto_em) or dia >= current_date - 1) loop
    perform public.recalcular_metricas(r.loja_id, r.dia);
  end loop;
end $$;
