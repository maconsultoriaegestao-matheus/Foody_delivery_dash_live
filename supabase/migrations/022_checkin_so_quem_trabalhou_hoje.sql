-- 022 · Tablet de check-in: só aparecem motoboys que já coletaram ao menos um pedido no dia operacional
-- (mesma regra do fechamento). Ordem alfabética, para o motoboy achar o nome rápido.
create or replace function public.motoboys_recentes(p_loja uuid)
returns table (entregador text, ultimo date, dias int)
language sql stable security definer set search_path = public as $$
  select min(trim(p.entregador)), max(p.dia), 1
  from public.pedidos p
  join public.lojas l on l.id = p.loja_id
  where privado.pode_ver_loja(p_loja) and p.loja_id = p_loja
    and p.dia = ((now() at time zone coalesce(l.fuso, 'America/Sao_Paulo')) - interval '5 hours')::date
    and p.status not in ('cancelled', 'rejected')
    and coalesce(trim(p.entregador), '') <> ''
    and (p.coletado_em is not null or p.entregue_em is not null)
  group by lower(trim(p.entregador))
  order by 1;
$$;
