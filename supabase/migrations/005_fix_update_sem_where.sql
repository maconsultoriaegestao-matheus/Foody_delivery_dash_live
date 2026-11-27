-- pg_safeupdate bloqueia UPDATE sem WHERE quando chamado pela API
do $$
declare d text;
begin
  d := pg_get_functiondef('public.recalcular_metricas(uuid,date)'::regprocedure);
  d := replace(d, 'update _p a set imediata = coalesce(a.imediata,false);',
                  'update _p a set imediata = false where a.imediata is null;');
  if position('where a.imediata is null' in d) = 0 then raise exception 'trecho não encontrado'; end if;
  execute d;
end $$;
