alter table public.pedidos add column if not exists qtd_pizzas int;
comment on column public.pedidos.qtd_pizzas is 'Pizzas no pedido, contadas a partir de orderDetails (o texto dos itens não é guardado)';
