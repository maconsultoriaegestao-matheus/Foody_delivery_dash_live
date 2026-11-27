// Coletor Foody Delivery: chamado a cada 30 s pelo Supabase Cron.
// Só leitura na Foody. Não grava nome, telefone, e-mail nem endereço do cliente final.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const FOODY = "https://app.foodydelivery.com/rest/1.2";
const JANELA_H = 10;            // horas para trás na listagem
const PAUSA_429_MS = 120_000;   // pausa do rastreio após um 429
const INTERVALO_MIN_MS = 20_000; // proteção: ignora chamadas a menos de 20 s da anterior
const LOTE = 5;                 // lojas em paralelo

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});

type Res = { status: number; data: any; ms: number };

async function foody(token: string, method: string, path: string, body?: unknown): Promise<Res> {
  const t0 = Date.now();
  try {
    const r = await fetch(FOODY + path, {
      method,
      headers: { Authorization: token, "Content-Type": "application/json;charset=UTF-8", Accept: "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: AbortSignal.timeout(15_000),
    });
    const txt = await r.text();
    let data: any = null;
    try { data = txt ? JSON.parse(txt) : null; } catch { data = txt; }
    return { status: r.status, data, ms: Date.now() - t0 };
  } catch (e) {
    return { status: 0, data: String(e), ms: Date.now() - t0 };
  }
}

const fmt = (d: Date) => new Date(d.getTime() - 3 * 3600e3).toISOString().slice(0, 19) + "-03:00";
const lista = (p: any): any[] => Array.isArray(p) ? p : (p && ["orders", "data", "items", "content"].map((k) => p[k]).find(Array.isArray)) || [];

function canal(notes?: string) {
  const n = notes || "";
  return n.includes("Localizer") || n.includes("IFOOD") ? "iFood" : n.includes("BRENDI") ? "Brendi" : "Direto";
}

// km rota estimado pela linha reta (calibrado com o relatório: rota ≈ 1,18 × raio + 0,55)
function kmRota(p: any): number | null {
  const a = p?.collectionPoint?.coordinates, b = p?.deliveryPoint?.coordinates;
  if (!a || !b) return null;
  const r = Math.PI / 180, dLa = (b.lat - a.lat) * r, dLo = (b.lng - a.lng) * r;
  const h = Math.sin(dLa / 2) ** 2 + Math.cos(a.lat * r) * Math.cos(b.lat * r) * Math.sin(dLo / 2) ** 2;
  return Math.round((1.18 * 2 * 6371 * Math.asin(Math.sqrt(h)) + 0.55) * 100) / 100;
}

function mapear(p: any, loja: string) {
  return {
    uid: p.uid, loja_id: loja, numero: p.id ?? null, origem: "api", status: p.status,
    canal: canal(p.notes),
    entregador: p.courier?.courierName?.trim() || null,
    tipo_entregador: p.courier?.courierType ?? null,
    modo_despacho: p.despatchMode ?? null,
    valor_total: p.orderTotal ?? null, taxa_entrega: p.deliveryFee ?? null, taxa_entregador: p.courierFee ?? null,
    km_rota: kmRota(p),
    aberto_em: p.date ?? null, pronto_em: p.readyDate ?? null, despachado_em: p.despatchDate ?? null,
    aceito_em: p.acceptanceDate ?? null, coletado_em: p.collectedDate ?? null, entregue_em: p.deliveryDate ?? null,
    finalizado_em: p.closedDate ?? null, prazo_em: p.deliveryDueDate ?? null, atualizado_em: p.updateDate ?? null,
  };
}

async function coletarLoja(loja: { id: string }) {
  const agora = new Date();
  const { data: est } = await sb.from("coletor_estado").select("*").eq("loja_id", loja.id).maybeSingle();
  if (est?.ultima_execucao && agora.getTime() - new Date(est.ultima_execucao).getTime() < INTERVALO_MIN_MS) {
    return { loja: loja.id, pulado: "intervalo" };
  }
  const estado: Record<string, unknown> = { loja_id: loja.id, ultima_execucao: agora.toISOString(), total_429: est?.total_429 ?? 0 };
  const salvar = async (extra: Record<string, unknown>) =>
    await sb.from("coletor_estado").upsert({ ...estado, ...extra }, { onConflict: "loja_id" });

  const { data: token } = await sb.rpc("foody_token", { p_loja: loja.id });
  if (!token) { await salvar({ ultimo_erro: "sem token no Vault" }); return { loja: loja.id, erro: "sem token" }; }

  // 1) Listagem paginada
  const pedidos: any[] = [];
  let cursor = new Date(agora.getTime() - JANELA_H * 3600e3);
  const fim = new Date(agora.getTime() + 5 * 60e3);
  let rota = "/orders";
  for (let i = 0; i < 5; i++) {
    const q = `?startDate=${encodeURIComponent(fmt(cursor))}&endDate=${encodeURIComponent(fmt(fim))}`;
    let r = await foody(token, "GET", rota + q);
    if (r.status === 404 && rota === "/orders") { rota = "/orders/"; r = await foody(token, "GET", rota + q); }
    if (r.status !== 200) {
      await salvar({ ultimo_erro: `listagem HTTP ${r.status}: ${String(JSON.stringify(r.data)).slice(0, 200)}` });
      return { loja: loja.id, erro: `listagem ${r.status}` };
    }
    const lote = lista(r.data);
    pedidos.push(...lote);
    if (lote.length < 500) break;
    cursor = new Date(new Date(lote[lote.length - 1].date).getTime() + 1000);
  }

  // 2) Gravação + eventos de status
  const linhas = pedidos.filter((p) => p?.uid).map((p) => mapear(p, loja.id));
  let eventos: any[] = [];
  if (linhas.length) {
    const { data: atuais } = await sb.from("pedidos").select("uid,status").in("uid", linhas.map((l) => l.uid));
    const antes = new Map((atuais || []).map((a: any) => [a.uid, a.status]));
    eventos = linhas.filter((l) => antes.get(l.uid) !== l.status).map((l) => ({
      uid: l.uid, loja_id: loja.id, status_anterior: antes.get(l.uid) ?? null, status_novo: l.status,
      atualizado_api: l.atualizado_em, fonte: "polling",
    }));
    const up = await sb.from("pedidos").upsert(linhas, { onConflict: "uid" });
    if (up.error) { await salvar({ ultimo_erro: "gravação: " + up.error.message }); return { loja: loja.id, erro: up.error.message }; }
    if (eventos.length) await sb.from("eventos_status").insert(eventos);
  }

  // 3) Rastreio: 1 pedido em rota por ciclo, em rodízio, com pausa após 429
  let rastreio = "sem pedidos em rota";
  const emRota = linhas.filter((l) => l.status === "onGoing").map((l) => l.uid).sort();
  const pausado = est?.rastreio_pausado_ate && new Date(est.rastreio_pausado_ate) > agora;
  if (emRota.length && pausado) rastreio = "pausado";
  else if (emRota.length) {
    const uid = emRota[Math.floor(agora.getTime() / 30_000) % emRota.length];
    const r = await foody(token, "GET", `/orders/tracking/${uid}`);
    const loc = r.data?.courierLocationCoordinates;
    if (r.status === 429) {
      estado.rastreio_pausado_ate = new Date(agora.getTime() + PAUSA_429_MS).toISOString();
      estado.total_429 = (est?.total_429 ?? 0) + 1;
      rastreio = "429, pausado";
    } else if (r.status === 200 && loc?.lat != null) {
      await sb.from("rastreio").insert({ uid, loja_id: loja.id, lat: loc.lat, lng: loc.lng });
      rastreio = "ok";
    } else rastreio = `HTTP ${r.status}`;
  }

  // 4) Recalcula métricas do dia quando algum pedido termina
  const terminou = eventos.some((e) => ["delivered", "closed", "cancelled", "rejected"].includes(e.status_novo));
  let erroMetricas: string | null = null;
  if (terminou) {
    const { data: dias } = await sb.from("pedidos").select("dia").in("uid", eventos.map((e) => e.uid));
    for (const d of new Set((dias || []).map((x: any) => x.dia))) {
      const { error } = await sb.rpc("recalcular_metricas", { p_loja: loja.id, p_dia: d });
      if (error) erroMetricas = `métricas ${d}: ${error.message}`;
    }
  }

  await salvar({ ultimo_sucesso: new Date().toISOString(), ultimo_erro: erroMetricas });
  return { loja: loja.id, pedidos: linhas.length, eventos: eventos.length, rastreio, recalculou: terminou };
}

Deno.serve(async () => {
  const { data: lojas, error } = await sb.from("lojas").select("id").eq("ativa", true);
  if (error) return new Response(JSON.stringify({ erro: error.message }), { status: 500 });
  const out: unknown[] = [];
  for (let i = 0; i < (lojas || []).length; i += LOTE) {
    const r = await Promise.allSettled(lojas!.slice(i, i + LOTE).map(coletarLoja));
    out.push(...r.map((x) => (x.status === "fulfilled" ? x.value : { erro: String(x.reason) })));
  }
  return new Response(JSON.stringify({ em: new Date().toISOString(), lojas: out }), {
    headers: { "Content-Type": "application/json" },
  });
});
