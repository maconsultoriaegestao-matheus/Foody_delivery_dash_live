-- 026 · Turnos da unidade (ex.: almoço e jantar). O painel ao vivo mostra só o turno atual.
-- Formato: [{"nome":"Almoço","inicio":"10:00","fim":"15:30"},{"nome":"Jantar","inicio":"17:00","fim":"01:00"}]
-- Horários no fuso da loja; fim menor que início = passa da meia-noite. Nulo = sem turnos (dia inteiro).
alter table public.lojas add column if not exists turnos jsonb
  check (turnos is null or jsonb_typeof(turnos) = 'array');
comment on column public.lojas.turnos is 'Turnos [{nome, inicio "HH:MM", fim "HH:MM"}]; o painel ao vivo filtra pelo turno atual';
