-- 024 · Check-in não aceita motoboy que ainda está em rota
-- Em rota = tem pedido coletado e não entregue na unidade, coletado dentro do limite de rota da loja
-- (acima do limite o pedido já vai para "Verificar" e não bloqueia mais).
create or replace function privado.motoboy_em_rota(p_loja uuid, p_nome text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.pedidos p join public.lojas l on l.id = p.loja_id
    where p.loja_id = p_loja and lower(trim(p.entregador)) = lower(trim(p_nome))
      and p.coletado_em is not null and p.entregue_em is null
      and p.status not in ('cancelled', 'rejected', 'delivered', 'closed')
      and p.coletado_em > now() - make_interval(mins => coalesce(l.limite_rota_min, 60)));
$$;
revoke all on function privado.motoboy_em_rota(uuid, text) from public, anon;
grant execute on function privado.motoboy_em_rota(uuid, text) to authenticated;

create or replace function public.tg_fila_checkin() returns trigger
language plpgsql set search_path = public as $$
declare v_fuso text;
begin
  select fuso into v_fuso from public.lojas where id = new.loja_id;
  new.entregador := trim(new.entregador);
  if privado.motoboy_em_rota(new.loja_id, new.entregador) then
    raise exception 'EM_ROTA: % ainda tem entrega em aberto. Marque a entrega no app da Foody e toque de novo.', new.entregador;
  end if;
  new.dia := ((new.chegou_em at time zone coalesce(v_fuso, 'America/Sao_Paulo')) - interval '5 hours')::date;
  update public.fila_checkin set saiu_em = new.chegou_em, motivo_saida = 'manual'
   where loja_id = new.loja_id and saiu_em is null and dia < new.dia;
  return new;
end $$;

drop function if exists public.motoboys_recentes(uuid);
create function public.motoboys_recentes(p_loja uuid)
returns table (entregador text, ultimo date, em_rota boolean)
language sql stable security definer set search_path = public as $$
  select min(trim(p.entregador)), max(p.dia), privado.motoboy_em_rota(p_loja, min(trim(p.entregador)))
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
revoke all on function public.motoboys_recentes(uuid) from public, anon;
grant execute on function public.motoboys_recentes(uuid) to authenticated;
