-- Três níveis: cliente → credencial Foody (um token) → unidade (loja)
create table public.clientes (
  id uuid primary key default gen_random_uuid(),
  nome text not null unique,
  ativo boolean not null default true,
  criado_em timestamptz not null default now()
);

create table public.credenciais_foody (
  id uuid primary key default gen_random_uuid(),
  cliente_id uuid not null references public.clientes(id) on delete cascade,
  nome text not null,
  ativa boolean not null default true,
  token_definido boolean not null default false,
  token_definido_em timestamptz,
  ultima_execucao timestamptz,
  ultimo_sucesso timestamptz,
  ultimo_erro text,
  rastreio_pausado_ate timestamptz,
  total_429 int not null default 0,
  criado_em timestamptz not null default now()
);

alter table public.lojas
  add column cliente_id uuid references public.clientes(id) on delete cascade,
  add column credencial_id uuid references public.credenciais_foody(id) on delete set null,
  add column collection_point_id text; -- só quando uma credencial atende várias unidades

-- Migração da loja atual
do $$
declare v_cli uuid; v_cred uuid; v_tok text;
begin
  insert into public.clientes (nome) values ('Pitizza') returning id into v_cli;
  insert into public.credenciais_foody (cliente_id, nome) values (v_cli, 'Água Verde') returning id into v_cred;
  update public.lojas set cliente_id = v_cli, credencial_id = v_cred, nome = 'Água Verde'
   where id = 'ad103097-a634-4f28-a977-39fa64a19f88';
  select decrypted_secret into v_tok from vault.decrypted_secrets where name = 'foody_token_ad103097-a634-4f28-a977-39fa64a19f88';
  if v_tok is not null then
    perform vault.create_secret(v_tok, 'foody_cred_' || v_cred::text, 'Token Foody');
    update public.credenciais_foody set token_definido = true, token_definido_em = now() where id = v_cred;
  end if;
end $$;

alter table public.lojas alter column cliente_id set not null;

-- Token por credencial (lido só pelo servidor)
create or replace function public.foody_token_cred(p_cred uuid) returns text
language sql stable security definer set search_path = public, vault as $$
  select decrypted_secret from vault.decrypted_secrets where name = 'foody_cred_' || p_cred::text limit 1;
$$;
revoke all on function public.foody_token_cred(uuid) from public, anon, authenticated;
grant execute on function public.foody_token_cred(uuid) to service_role;

create or replace function public.definir_token_cred(p_cred uuid, p_token text) returns void
language plpgsql security definer set search_path = public, vault as $$
declare v_id uuid;
begin
  select id into v_id from vault.secrets where name = 'foody_cred_' || p_cred::text;
  if v_id is null then perform vault.create_secret(p_token, 'foody_cred_' || p_cred::text, 'Token Foody');
  else perform vault.update_secret(v_id, p_token); end if;
  update public.credenciais_foody set token_definido = true, token_definido_em = now(), ultimo_erro = null where id = p_cred;
end $$;
revoke all on function public.definir_token_cred(uuid, text) from public, anon, authenticated;
grant execute on function public.definir_token_cred(uuid, text) to service_role;

-- Acessos: global (loja e cliente nulos), por cliente, ou por unidade
alter table public.acessos add column cliente_id uuid references public.clientes(id) on delete cascade;
alter table public.acessos drop constraint if exists acessos_user_id_loja_id_key;
alter table public.acessos add constraint acessos_escopo check (not (loja_id is not null and cliente_id is not null));
create unique index acessos_unico on public.acessos (user_id, coalesce(cliente_id, '00000000-0000-0000-0000-000000000000'::uuid), coalesce(loja_id, '00000000-0000-0000-0000-000000000000'::uuid));

create or replace function privado.pode_ver_loja(p_loja uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.acessos a
    left join public.lojas l on l.id = p_loja
    where a.user_id = (select auth.uid())
      and (a.loja_id = p_loja
           or (a.cliente_id is not null and a.cliente_id = l.cliente_id)
           or (a.loja_id is null and a.cliente_id is null)));
$$;

create or replace function privado.pode_ver_cliente(p_cliente uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.acessos a
    where a.user_id = (select auth.uid())
      and (a.cliente_id = p_cliente
           or (a.loja_id is null and a.cliente_id is null)
           or a.loja_id in (select id from public.lojas where cliente_id = p_cliente)));
$$;
revoke all on function privado.pode_ver_cliente(uuid) from public, anon;
grant execute on function privado.pode_ver_cliente(uuid) to authenticated;

create or replace function privado.eh_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.acessos a where a.user_id = (select auth.uid())
                 and a.loja_id is null and a.cliente_id is null and a.papel = 'admin');
$$;
revoke all on function privado.eh_admin() from public, anon;
grant execute on function privado.eh_admin() to authenticated;

alter table public.clientes enable row level security;
alter table public.credenciais_foody enable row level security;
create policy clientes_leitura on public.clientes for select to authenticated using (privado.pode_ver_cliente(id));
create policy credenciais_admin on public.credenciais_foody for select to authenticated using (privado.eh_admin());
