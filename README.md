# Foody Painel

Painel ao vivo (TV da cozinha) e dashboard histórico das entregas dos clientes que usam o Foody Delivery.

## Estrutura

- `web/live/` — painel kanban ao vivo (hoje: simulação de 25/11; depois: Supabase Realtime)
- `web/dash/` — dashboard histórico (hoje: `data/*.json` da base 01/10–22/11; depois: views do Supabase)
- `scripts/foody_metricas.py` — regras de cálculo (viagens, trânsito, retorno, exclusões, produtividade); referência para as views SQL
- `scripts/foody_monitor.py` / `foody_api_teste.py` — testes de leitura da API v1.2
- `supabase/` — migrations e Edge Functions (coletor a cada 30 s via Supabase Cron, receptor de webhook)

## Deploy

- Netlify: publica `web/` a cada push (só chave pública do Supabase no front)
- Supabase: migrations e funções via Supabase CLI / GitHub Actions; tokens Foody no Vault
