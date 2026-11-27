-- 016 · ordem estável na lista de entregas do fechamento (a tela pagina de 1.000 em 1.000)
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
  order by p.dia, p.entregador, p.entregue_em, p.uid;
end $$;
