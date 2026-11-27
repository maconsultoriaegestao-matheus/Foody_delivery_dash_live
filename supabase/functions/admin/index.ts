// Administração: clientes, unidades, tokens Foody e acessos. Só para administradores globais.
// O token Foody entra aqui uma vez, é testado na API e vai direto para o Vault; nunca é devolvido.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const URL = Deno.env.get("SUPABASE_URL")!;
const svc = createClient(URL, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const FOODY = "https://app.foodydelivery.com/rest/1.2";
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...CORS, "Content-Type": "application/json" } });

const fmt = (d: Date) => new Date(d.getTime() - 3 * 3600e3).toISOString().slice(0, 19) + "-03:00";

async function testarToken(token: string) {
  const fim = new Date(), ini = new Date(fim.getTime() - 3 * 86400e3);
  const q = `?startDate=${encodeURIComponent(fmt(ini))}&endDate=${encodeURIComponent(fmt(fim))}`;
  for (const rota of ["/orders", "/orders/"]) {
    const r = await fetch(FOODY + rota + q, { headers: { Authorization: token, Accept: "application/json" }, signal: AbortSignal.timeout(15000) });
    if (r.status === 404) continue;
    const txt = await r.text();
    if (r.status !== 200) return { ok: false, status: r.status, msg: txt.slice(0, 200) };
    const lista = JSON.parse(txt || "[]");
    const arr = Array.isArray(lista) ? lista : [];
    const pontos = new Map<string, { id: string; nome: string; pedidos: number }>();
    for (const p of arr) {
      const cp = p?.collectionPoint;
      if (!cp?.id) continue;
      const k = String(cp.id);
      const atual = pontos.get(k) || { id: k, nome: cp.name || "", pedidos: 0 };
      atual.pedidos++;
      pontos.set(k, atual);
    }
    return { ok: true, pedidos_3_dias: arr.length, pontos_coleta: [...pontos.values()] };
  }
  return { ok: false, status: 404, msg: "rota de pedidos não encontrada" };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ erro: "use POST" }, 405);

  // quem está chamando?
  const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  const { data: u, error: eu } = await svc.auth.getUser(jwt);
  if (eu || !u?.user) return json({ erro: "não autenticado" }, 401);
  const { data: adm } = await svc.from("acessos").select("user_id").eq("user_id", u.user.id)
    .is("loja_id", null).is("cliente_id", null).eq("papel", "admin").limit(1);
  if (!adm?.length) return json({ erro: "acesso restrito a administradores" }, 403);

  let b: any = {};
  try { b = await req.json(); } catch { /* vazio */ }

  try {
    switch (b.acao) {
      case "listar": {
        const [cli, cred, lojas, acessos, est] = await Promise.all([
          svc.from("clientes").select("*").order("nome"),
          svc.from("credenciais_foody").select("id,cliente_id,nome,ativa,token_definido,token_definido_em,ultimo_sucesso,ultimo_erro,total_429"),
          svc.from("lojas").select("*").order("nome"),
          svc.from("acessos").select("user_id,cliente_id,loja_id,papel,criado_em"),
          svc.from("coletor_estado").select("loja_id,ultimo_sucesso,ultimo_erro"),
        ]);
        const { data: us } = await svc.auth.admin.listUsers({ perPage: 1000 });
        const email = new Map((us?.users || []).map((x) => [x.id, x.email]));
        return json({
          clientes: cli.data, credenciais: cred.data, lojas: lojas.data, estado: est.data,
          acessos: (acessos.data || []).map((a) => ({ ...a, email: email.get(a.user_id) || "?" })),
        });
      }

      case "salvar_cliente": {
        if (!b.nome?.trim()) return json({ erro: "nome obrigatório" }, 400);
        const q = b.id ? svc.from("clientes").update({ nome: b.nome.trim(), ativo: b.ativo ?? true }).eq("id", b.id)
                       : svc.from("clientes").insert({ nome: b.nome.trim() });
        const { data, error } = await q.select().single();
        if (error) return json({ erro: error.message }, 400);
        return json({ cliente: data });
      }

      case "salvar_loja": {
        // cria/edita a unidade; na criação, cria também a credencial (1 token por unidade)
        const campos: Record<string, unknown> = {};
        for (const k of ["nome", "ativa", "meta_despacho_min", "meta_espera_min", "meta_transito_min", "meta_total_min",
                         "limite_cozinha_min", "limite_espera_min", "limite_rota_min", "collection_point_id"]) {
          if (b[k] !== undefined) campos[k] = b[k];
        }
        if (b.id) {
          const { data, error } = await svc.from("lojas").update(campos).eq("id", b.id).select().single();
          if (error) return json({ erro: error.message }, 400);
          if (b.nome) await svc.from("credenciais_foody").update({ nome: b.nome }).eq("id", data.credencial_id);
          if (b.ativa !== undefined && data.credencial_id) await svc.from("credenciais_foody").update({ ativa: b.ativa }).eq("id", data.credencial_id);
          return json({ loja: data });
        }
        if (!b.cliente_id || !b.nome?.trim()) return json({ erro: "cliente e nome obrigatórios" }, 400);
        let credId = b.credencial_id;
        if (!credId) {
          const { data: c, error: ec } = await svc.from("credenciais_foody").insert({ cliente_id: b.cliente_id, nome: b.nome.trim() }).select().single();
          if (ec) return json({ erro: ec.message }, 400);
          credId = c.id;
        }
        const { data, error } = await svc.from("lojas").insert({ ...campos, nome: b.nome.trim(), cliente_id: b.cliente_id, credencial_id: credId }).select().single();
        if (error) return json({ erro: error.message }, 400);
        return json({ loja: data });
      }

      case "testar_token": {
        if (!b.token?.trim()) return json({ erro: "token obrigatório" }, 400);
        return json(await testarToken(b.token.trim()));
      }

      case "definir_token": {
        if (!b.credencial_id || !b.token?.trim()) return json({ erro: "credencial e token obrigatórios" }, 400);
        const t = await testarToken(b.token.trim());
        if (!t.ok) return json({ erro: `a Foody recusou o token (HTTP ${t.status})`, teste: t }, 400);
        const { error } = await svc.rpc("definir_token_cred", { p_cred: b.credencial_id, p_token: b.token.trim() });
        if (error) return json({ erro: error.message }, 400);
        return json({ ok: true, teste: t });
      }

      case "criar_usuario": {
        // escopo: global | cliente | loja
        const { email, senha, escopo, cliente_id, loja_id } = b;
        if (!email || !senha || senha.length < 8) return json({ erro: "e-mail e senha (mín. 8 caracteres) obrigatórios" }, 400);
        let uid: string | undefined;
        const cr = await svc.auth.admin.createUser({ email, password: senha, email_confirm: true });
        if (cr.error) {
          const { data: us } = await svc.auth.admin.listUsers({ perPage: 1000 });
          uid = us?.users.find((x) => x.email?.toLowerCase() === String(email).toLowerCase())?.id;
          if (!uid) return json({ erro: cr.error.message }, 400);
        } else uid = cr.data.user?.id;
        const acesso = {
          user_id: uid, papel: escopo === "global" ? "admin" : "leitura",
          cliente_id: escopo === "cliente" ? cliente_id : null, loja_id: escopo === "loja" ? loja_id : null,
        };
        const { error } = await svc.from("acessos").insert(acesso);
        if (error) return json({ erro: error.message }, 400);
        return json({ ok: true, user_id: uid });
      }

      case "remover_acesso": {
        let q = svc.from("acessos").delete().eq("user_id", b.user_id);
        q = b.cliente_id ? q.eq("cliente_id", b.cliente_id) : q.is("cliente_id", null);
        q = b.loja_id ? q.eq("loja_id", b.loja_id) : q.is("loja_id", null);
        const { error } = await q;
        if (error) return json({ erro: error.message }, 400);
        return json({ ok: true });
      }

      default:
        return json({ erro: "ação desconhecida" }, 400);
    }
  } catch (e) {
    return json({ erro: String(e) }, 500);
  }
});
