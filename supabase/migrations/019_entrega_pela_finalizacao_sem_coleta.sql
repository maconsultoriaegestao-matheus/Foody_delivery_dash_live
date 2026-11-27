-- 019 · amplia a 018: também vale quando o motoboy aceitou mas não marcou "a caminho" (sem coleta),
-- desde que o pedido tenha entregador. Pedido finalizado sem entregador (balcão/retirada) não vira entrega.
create or replace function public.tg_pedidos_entrega() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.status = 'closed' and new.finalizado_em is not null
     and (new.coletado_em is not null or coalesce(trim(new.entregador), '') <> '')
     and (new.entregue_em is null or (new.entrega_pela_finalizacao and new.entregue_em = new.finalizado_em)) then
    new.entregue_em := new.finalizado_em;
    new.entrega_pela_finalizacao := true;
  elsif new.entregue_em is not null and new.entregue_em is distinct from new.finalizado_em then
    new.entrega_pela_finalizacao := false;
  end if;
  return new;
end $$;

update public.pedidos set status = status
 where status = 'closed' and entregue_em is null and finalizado_em is not null and coalesce(trim(entregador), '') <> '';
