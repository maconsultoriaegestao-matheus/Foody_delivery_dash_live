-- 017 · papel "gestor" (vê e fecha pagamentos dos entregadores) ao lado de "admin" e "leitura"
do $$
declare c record;
begin
  for c in select conname from pg_constraint
           where conrelid = 'public.acessos'::regclass and contype = 'c' and pg_get_constraintdef(oid) ilike '%papel%' loop
    execute format('alter table public.acessos drop constraint %I', c.conname);
  end loop;
end $$;
alter table public.acessos add constraint acessos_papel_check check (papel in ('admin', 'gestor', 'leitura'));
