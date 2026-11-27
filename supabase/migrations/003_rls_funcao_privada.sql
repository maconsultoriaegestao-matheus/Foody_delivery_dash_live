create schema if not exists privado;
revoke all on schema privado from public, anon;
grant usage on schema privado to authenticated;

create or replace function privado.pode_ver_loja(p_loja uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.acessos a
                 where a.user_id = (select auth.uid()) and (a.loja_id = p_loja or a.loja_id is null));
$$;
revoke all on function privado.pode_ver_loja(uuid) from public, anon;
grant execute on function privado.pode_ver_loja(uuid) to authenticated;

alter policy lojas_leitura on public.lojas using (privado.pode_ver_loja(id));
alter policy pedidos_leitura on public.pedidos using (privado.pode_ver_loja(loja_id));
alter policy eventos_leitura on public.eventos_status using (privado.pode_ver_loja(loja_id));
alter policy rastreio_leitura on public.rastreio using (privado.pode_ver_loja(loja_id));
alter policy coletor_leitura on public.coletor_estado using (privado.pode_ver_loja(loja_id));
alter policy viagens_leitura on public.viagens using (privado.pode_ver_loja(loja_id));
alter policy pm_leitura on public.pedido_metricas using (privado.pode_ver_loja(loja_id));
drop function public.pode_ver_loja(uuid);
