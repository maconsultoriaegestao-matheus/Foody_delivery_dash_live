alter table public.lojas
  add column if not exists limite_cozinha_min int not null default 90,
  add column if not exists limite_espera_min int not null default 60,
  add column if not exists limite_rota_min int not null default 60;
comment on column public.lojas.limite_rota_min is 'Em rota sem baixa acima disso = desvio: sai do kanban e vai para "Verificar"';
