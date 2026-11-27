-- Lojas monitoradas e metas operacionais
create table public.lojas (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  cliente text,
  ativa boolean not null default true,
  fuso text not null default 'America/Sao_Paulo',
  meta_despacho_min int not null default 15,
  meta_espera_min int not null default 5,
  meta_transito_min int not null default 20,
  meta_total_min int not null default 30,
  criado_em timestamptz not null default now()
);

-- Quem pode ver cada loja (TV da loja, cliente, consultoria)
create table public.acessos (
  user_id uuid not null references auth.users(id) on delete cascade,
  loja_id uuid references public.lojas(id) on delete cascade, -- null = todas as lojas
  papel text not null default 'leitura' check (papel in ('leitura','admin')),
  criado_em timestamptz not null default now(),
  unique (user_id, loja_id)
);

-- Pedidos (sem nome, telefone, e-mail ou endereço do cliente final)
create table public.pedidos (
  uid text primary key,
  loja_id uuid not null references public.lojas(id) on delete cascade,
  numero text,
  origem text not null default 'api' check (origem in ('api','relatorio')),
  status text not null,
  canal text,
  entregador text,
  tipo_entregador text,
  modo_despacho text,
  valor_total numeric(10,2),
  taxa_entrega numeric(10,2),
  taxa_entregador numeric(10,2),
  km_rota numeric(6,2),
  aberto_em timestamptz,
  pronto_em timestamptz,
  despachado_em timestamptz,
  aceito_em timestamptz,
  coletado_em timestamptz,
  entregue_em timestamptz,
  finalizado_em timestamptz,
  cancelado_em timestamptz,
  prazo_em timestamptz,
  atualizado_em timestamptz,
  dia date,                       -- dia operacional (corte às 05h, fuso da loja)
  sincronizado_em timestamptz not null default now()
);
create index pedidos_loja_dia on public.pedidos (loja_id, dia);
create index pedidos_loja_status on public.pedidos (loja_id, status);

create or replace function public.tg_pedidos_dia() returns trigger
language plpgsql set search_path = public as $$
declare v_fuso text;
begin
  select fuso into v_fuso from public.lojas where id = new.loja_id;
  new.dia := ((coalesce(new.aberto_em, new.atualizado_em) at time zone coalesce(v_fuso,'America/Sao_Paulo')) - interval '5 hours')::date;
  new.sincronizado_em := now();
  return new;
end $$;
create trigger pedidos_dia before insert or update on public.pedidos
for each row execute function public.tg_pedidos_dia();

-- Histórico de mudanças de status detectadas pelo coletor/webhook
create table public.eventos_status (
  id bigint generated always as identity primary key,
  uid text not null references public.pedidos(uid) on delete cascade,
  loja_id uuid not null references public.lojas(id) on delete cascade,
  status_anterior text,
  status_novo text not null,
  atualizado_api timestamptz,
  detectado_em timestamptz not null default now(),
  fonte text not null default 'polling'
);
create index eventos_loja_tempo on public.eventos_status (loja_id, detectado_em desc);

-- Posição do motoboy em pedidos em rota
create table public.rastreio (
  id bigint generated always as identity primary key,
  uid text not null references public.pedidos(uid) on delete cascade,
  loja_id uuid not null references public.lojas(id) on delete cascade,
  capturado_em timestamptz not null default now(),
  lat double precision,
  lng double precision
);
create index rastreio_uid_tempo on public.rastreio (uid, capturado_em desc);

-- Estado do coletor por loja
create table public.coletor_estado (
  loja_id uuid primary key references public.lojas(id) on delete cascade,
  ultima_execucao timestamptz,
  ultimo_sucesso timestamptz,
  ultimo_erro text,
  rastreio_pausado_ate timestamptz,
  total_429 int not null default 0
);

-- Métricas calculadas
create table public.viagens (
  id bigint generated always as identity primary key,
  loja_id uuid not null references public.lojas(id) on delete cascade,
  dia date not null,
  entregador text not null,
  saida_em timestamptz not null,
  fim_em timestamptz,
  pedidos int not null,
  tempo_rota_min numeric(7,2),
  hiato_depois_min numeric(7,2),          -- para horas ativas (tempo real, até 60 min)
  retorno_ocioso_depois_min numeric(7,2), -- para médias (exclui hiato após baixa suspeita)
  baixa_suspeita boolean not null default false
);
create index viagens_loja_dia on public.viagens (loja_id, dia);

create table public.pedido_metricas (
  uid text primary key references public.pedidos(uid) on delete cascade,
  loja_id uuid not null references public.lojas(id) on delete cascade,
  dia date not null,
  viagem_id bigint references public.viagens(id) on delete cascade,
  entregador text,
  posicao int,
  pedidos_na_viagem int,
  t_ate_despacho_min numeric(7,2),
  t_espera_saida_min numeric(7,2),
  t_transito_min numeric(7,2),
  t_total_min numeric(7,2),
  km_rota numeric(6,2),
  vel_kmh numeric(8,1),
  no_prazo boolean,
  baixa text,               -- imediata | retorno | null
  motivo_exclusao text,     -- motivo para sair da média de trânsito
  excluir_despacho boolean not null default false,
  excluir_total boolean not null default false
);
create index pm_loja_dia on public.pedido_metricas (loja_id, dia);

-- RLS: tudo fechado; leitura só para quem tem acesso à loja
alter table public.lojas enable row level security;
alter table public.acessos enable row level security;
alter table public.pedidos enable row level security;
alter table public.eventos_status enable row level security;
alter table public.rastreio enable row level security;
alter table public.coletor_estado enable row level security;
alter table public.viagens enable row level security;
alter table public.pedido_metricas enable row level security;

create or replace function public.pode_ver_loja(p_loja uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.acessos a
                 where a.user_id = (select auth.uid()) and (a.loja_id = p_loja or a.loja_id is null));
$$;
revoke all on function public.pode_ver_loja(uuid) from public, anon;
grant execute on function public.pode_ver_loja(uuid) to authenticated;

create policy lojas_leitura on public.lojas for select to authenticated using (public.pode_ver_loja(id));
create policy acessos_proprio on public.acessos for select to authenticated using (user_id = (select auth.uid()));
create policy pedidos_leitura on public.pedidos for select to authenticated using (public.pode_ver_loja(loja_id));
create policy eventos_leitura on public.eventos_status for select to authenticated using (public.pode_ver_loja(loja_id));
create policy rastreio_leitura on public.rastreio for select to authenticated using (public.pode_ver_loja(loja_id));
create policy coletor_leitura on public.coletor_estado for select to authenticated using (public.pode_ver_loja(loja_id));
create policy viagens_leitura on public.viagens for select to authenticated using (public.pode_ver_loja(loja_id));
create policy pm_leitura on public.pedido_metricas for select to authenticated using (public.pode_ver_loja(loja_id));

-- Tempo real para o painel da TV
alter publication supabase_realtime add table public.pedidos, public.rastreio;

-- Token da Foody por loja: guardado no Vault, lido só pelo coletor (service_role)
create or replace function public.foody_token(p_loja uuid) returns text
language sql stable security definer set search_path = public, vault as $$
  select decrypted_secret from vault.decrypted_secrets where name = 'foody_token_' || p_loja::text limit 1;
$$;
revoke all on function public.foody_token(uuid) from public, anon, authenticated;
grant execute on function public.foody_token(uuid) to service_role;

create or replace function public.definir_foody_token(p_loja uuid, p_token text) returns void
language plpgsql security definer set search_path = public, vault as $$
declare v_id uuid;
begin
  select id into v_id from vault.secrets where name = 'foody_token_' || p_loja::text;
  if v_id is null then
    perform vault.create_secret(p_token, 'foody_token_' || p_loja::text, 'Token Foody da loja');
  else
    perform vault.update_secret(v_id, p_token);
  end if;
end $$;
revoke all on function public.definir_foody_token(uuid, text) from public, anon, authenticated;
grant execute on function public.definir_foody_token(uuid, text) to service_role;
