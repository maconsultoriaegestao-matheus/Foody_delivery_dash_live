# Migrations do banco (Supabase)

Aplicadas no projeto `wqntpofzgefubkorcltq`, nesta ordem. Os arquivos são a cópia fiel do que rodou
(tirada de `supabase_migrations.schema_migrations`), com uma exceção: na 004 a chave anon foi trocada por `<ANON_KEY>`.

- **011 (mover `pg_net` para o schema `extensions`) ainda não foi aplicada.** Pendente no cronograma (item 1.5); precisa de aprovação no Supabase.
- A 013 foi desfeita pela 014 (metas passaram a ser por dia da semana).
- Funções privadas ficam no schema `privado`; tokens Foody ficam só no Vault (`foody_cred_<id da credencial>`), nunca no repositório.
