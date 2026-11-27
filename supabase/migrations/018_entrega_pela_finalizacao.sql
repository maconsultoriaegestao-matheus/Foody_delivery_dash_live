-- 018 · Pedido finalizado sem a baixa "entregue"
-- Em algumas lojas (ex.: Clube do Queijo Cabral) o pedido vai de "A caminho" direto para "Finalizado",
-- sem deliveryDate. Sem isso o pedido ficava "em rota" para sempre no painel, fora das métricas e do fechamento.
-- Regra: status finalizado + coletado + sem data de entrega → entrega = horário da finalização (marcado).
alter table public.pedidos add column if not exists entrega_pela_finalizacao boolean not null default false;
comment on column public.pedidos.entrega_pela_finalizacao is
  'true = a Foody não informou a entrega; entregue_em foi preenchido com o horário da finalização';

create or replace function public.tg_pedidos_entrega() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.status = 'closed' and new.coletado_em is not null and new.finalizado_em is not null
     and (new.entregue_em is null or (new.entrega_pela_finalizacao and new.entregue_em = new.finalizado_em)) then
    new.entregue_em := new.finalizado_em;
    new.entrega_pela_finalizacao := true;
  elsif new.entregue_em is not null and new.entregue_em is distinct from new.finalizado_em then
    new.entrega_pela_finalizacao := false;
  end if;
  return new;
end $$;
drop trigger if exists pedidos_entrega on public.pedidos;
create trigger pedidos_entrega before insert or update on public.pedidos
  for each row execute function public.tg_pedidos_entrega();

-- corrige o que já está no banco e recalcula as métricas desses dias
update public.pedidos set status = status
 where status = 'closed' and entregue_em is null and coletado_em is not null and finalizado_em is not null;

do $$
declare r record;
begin
  for r in select distinct loja_id, dia from public.pedidos where entrega_pela_finalizacao and dia is not null loop
    perform public.recalcular_metricas(r.loja_id, r.dia);
  end loop;
end $$;
