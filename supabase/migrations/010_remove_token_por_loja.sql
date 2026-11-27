delete from vault.secrets where name like 'foody_token_%';
drop function if exists public.foody_token(uuid);
drop function if exists public.definir_foody_token(uuid, text);
