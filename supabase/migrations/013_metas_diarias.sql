-- (substituída pela 014: metas por dia da semana)
alter table public.lojas
  add column if not exists meta_vendas_dia numeric(12,2),
  add column if not exists meta_viagens_dia int;
comment on column public.lojas.meta_vendas_dia is 'Meta diária de vendas (R$, soma dos pedidos do dia não cancelados). Nulo = sem meta';
comment on column public.lojas.meta_viagens_dia is 'Meta diária de viagens concluídas. Nulo = sem meta';
