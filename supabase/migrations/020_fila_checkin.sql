-- 020 · Fila de motoboys por check-in na loja ("motoboy da vez")
-- O motoboy toca no próprio nome num tablet ao chegar; a ordem dos toques é a fila.
-- Sai da fila sozinho quando coleta o próximo pedido (ou manualmente pelo painel).
create table if not exists public.fila_checkin (
  id bigint generated always as identity primary key,
  loja_id uuid not null references public.lojas(id) on delete cascade,
  dia date not null,
  entregador text not null check (length(trim(entregador)) between 1 and 80),
  chegou_em timestamptz not null default now(),
  saiu_em timestamptz,
  motivo_saida text check (motivo_saida in ('coleta', 'manual')),
  uid_coleta text,
  criado_por uuid default auth.uid()
);
create index if not exists fila_loja_dia on public.fila_checkin (loja_id, dia);

-- um motoboy só pode estar uma vez na fila aberta da unidade
create unique index if not exists fila_um_por_motoboy on public.fila_checkin (loja_id, lower(trim(entregador))) where saiu_em is null;

-- dia operacional (vira às 05h) e fecha check-ins esquecidos de dias anteriores
create or replace function public.tg_fila_checkin() returns trigger
language plpgsql set search_path = public as $$
declare v_fuso text;
begin
  select fuso into v_fuso from public.lojas where id = new.loja_id;
  new.entregador := trim(new.entregador);
  new.dia := ((new.chegou_em at time zone coalesce(v_fuso, 'America/Sao_Paulo')) - interval '5 hours')::date;
  update public.fila_checkin set saiu_em = new.chegou_em, motivo_saida = 'manual'
   where loja_id = new.loja_id and saiu_em is null and dia < new.dia;
  return new;
end $$;
drop trigger if exists fila_checkin_dia on public.fila_checkin;
create trigger fila_checkin_dia before insert on public.fila_checkin
  for each row execute function public.tg_fila_checkin();

-- coleta (ou aceite/finalização, para lojas que pulam o "a caminho") tira o motoboy da fila
create or replace function public.tg_pedidos_sai_fila() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_mom timestamptz;
begin
  if coalesce(trim(new.entregador), '') = '' then return null; end if;
  v_mom := coalesce(new.coletado_em,
                    case when new.status in ('onGoing', 'delivered', 'closed') then coalesce(new.aceito_em, new.finalizado_em) end);
  if v_mom is null then return null; end if;
  update public.fila_checkin f set saiu_em = v_mom, motivo_saida = 'coleta', uid_coleta = new.uid
   where f.loja_id = new.loja_id and f.saiu_em is null
     and lower(trim(f.entregador)) = lower(trim(new.entregador))
     and v_mom >= f.chegou_em - interval '2 minutes';
  return null;
end $$;
drop trigger if exists pedidos_sai_fila on public.pedidos;
create trigger pedidos_sai_fila after insert or update on public.pedidos
  for each row execute function public.tg_pedidos_sai_fila();

-- RLS: quem vê a unidade (inclusive o usuário do tablet/TV) pode entrar na fila e tirar da fila
alter table public.fila_checkin enable row level security;
drop policy if exists fila_ler on public.fila_checkin;
create policy fila_ler on public.fila_checkin for select to authenticated using (privado.pode_ver_loja(loja_id));
drop policy if exists fila_entrar on public.fila_checkin;
create policy fila_entrar on public.fila_checkin for insert to authenticated
  with check (privado.pode_ver_loja(loja_id) and saiu_em is null);
drop policy if exists fila_sair on public.fila_checkin;
create policy fila_sair on public.fila_checkin for update to authenticated
  using (privado.pode_ver_loja(loja_id)) with check (privado.pode_ver_loja(loja_id));
grant select on public.fila_checkin to authenticated;
grant insert (loja_id, entregador) on public.fila_checkin to authenticated;
grant update (saiu_em, motivo_saida) on public.fila_checkin to authenticated;

-- nomes para os botões do tablet: motoboys da unidade nos últimos 30 dias (mais recentes primeiro)
create or replace function public.motoboys_recentes(p_loja uuid)
returns table (entregador text, ultimo date, dias int)
language sql stable security definer set search_path = public as $$
  select min(trim(p.entregador)), max(p.dia), count(distinct p.dia)::int
  from public.pedidos p
  where privado.pode_ver_loja(p_loja) and p.loja_id = p_loja
    and p.dia >= current_date - 30 and coalesce(trim(p.entregador), '') <> ''
  group by lower(trim(p.entregador))
  order by max(p.dia) desc, count(distinct p.dia) desc, 1;
$$;
revoke all on function public.motoboys_recentes(uuid) from public, anon;
grant execute on function public.motoboys_recentes(uuid) to authenticated;

alter publication supabase_realtime add table public.fila_checkin;
