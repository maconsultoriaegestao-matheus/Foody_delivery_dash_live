create extension if not exists pg_cron;
create extension if not exists pg_net;

-- URL e chave pública guardadas no Vault (a chave anon é pública; o coletor se protege com intervalo mínimo de 20 s)
-- Ao recriar o banco, troque <ANON_KEY> pela chave anon do projeto (Project Settings → API). Não versionar a chave.
select vault.create_secret('https://wqntpofzgefubkorcltq.supabase.co', 'project_url', 'URL do projeto');
select vault.create_secret('<ANON_KEY>', 'anon_key', 'Chave pública para o cron chamar o coletor');

select cron.schedule('coletor-foody-30s', '30 seconds', $$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url') || '/functions/v1/coletor',
    headers := jsonb_build_object('Content-Type','application/json',
      'Authorization','Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'anon_key')),
    body := '{}'::jsonb,
    timeout_milliseconds := 25000
  );
$$);

-- Limpeza: respostas do pg_net com mais de 1 dia
select cron.schedule('limpa-net-respostas', '17 4 * * *', $$ delete from net._http_response where created < now() - interval '1 day' $$);
