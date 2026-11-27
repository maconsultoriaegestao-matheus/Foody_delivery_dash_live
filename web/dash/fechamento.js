// Retaguarda · fechamento dos entregadores (aba do dashboard; só gestores e administradores)
{
const $ = (id) => document.getElementById(id);
const esc = (v) => String(v ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const R$ = (v) => Number(v || 0).toLocaleString("pt-BR", { style: "currency", currency: "BRL" });
const nf = (v, d = 1) => (v == null ? "–" : Number(v).toLocaleString("pt-BR", { minimumFractionDigits: d, maximumFractionDigits: d }));
const addD = (s, n) => { const d = new Date(s + "T12:00:00Z"); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
const dowI = (s) => new Date(s + "T12:00:00Z").getUTCDay();
const DW = ["dom", "seg", "ter", "qua", "qui", "sex", "sáb"];
const br = (s) => s.slice(8, 10) + "/" + s.slice(5, 7);
const brA = (s) => br(s) + "/" + s.slice(0, 4);
const hora = (t) => (t ? new Date(t).toLocaleTimeString("pt-BR", { timeZone: "America/Sao_Paulo", hour: "2-digit", minute: "2-digit" }) : "–");
const quando = (t) => new Date(t).toLocaleString("pt-BR", { timeZone: "America/Sao_Paulo", day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit" });
const msg = (f, t, tipo) => { const m = f.querySelector(".msg"); m.textContent = t; m.className = "msg " + (tipo || ""); };
const hoje = () => Painel.diaOperacional();
const sb = () => Painel.sb;

let L = null, MODO = "dia", REF = null, A = null, REGRAS = [], PODE = false, ABERTO = new Set();

function periodo() {
  if (MODO === "dia") return [REF, REF];
  const ini = addD(REF, -((dowI(REF) + 6) % 7));
  return [ini, addD(ini, 6)];
}

// ---------- abas ----------
function aba(q) {
  const f = q === "fech" && PODE;
  $("v_ind").hidden = f; $("v_fech").hidden = !f;
  $("t_ind").setAttribute("aria-selected", String(!f)); $("t_fech").setAttribute("aria-selected", String(f));
  history.replaceState(null, "", f ? "#fechamento" : location.pathname + location.search);
  if (f) carregar().catch(falha);
  else window.dispatchEvent(new Event("resize"));
}
$("t_ind").onclick = () => aba("ind");
$("t_fech").onclick = () => aba("fech");

window.onLojaMudou = async (loja) => {
  L = loja; ABERTO.clear();
  const { data } = await sb().rpc("posso_gerir", { p_loja: L.id });
  PODE = !!data;
  $("t_fech").hidden = !PODE;
  if (!REF) REF = addD(hoje(), -1);
  aba(PODE && (location.hash === "#fechamento" || !$("v_fech").hidden) ? "fech" : "ind");
};

const falha = (e) => { $("fx_tab").innerHTML = `<tr><td colspan="11">Não foi possível carregar: ${esc(e.message || e)}</td></tr>`; };

// ---------- período ----------
function modo(m) {
  MODO = m;
  $("m_dia").setAttribute("aria-pressed", String(m === "dia")); $("m_sem").setAttribute("aria-pressed", String(m === "sem"));
  $("l_ref").textContent = m === "dia" ? "Dia" : "Qualquer dia da semana";
  carregar().catch(falha);
}
$("m_dia").onclick = () => modo("dia");
$("m_sem").onclick = () => modo("sem");
$("p_ant").onclick = () => { REF = addD(REF, MODO === "dia" ? -1 : -7); carregar().catch(falha); };
$("p_prox").onclick = () => { REF = addD(REF, MODO === "dia" ? 1 : 7); carregar().catch(falha); };
$("f_ref").onchange = () => { if ($("f_ref").value) { REF = $("f_ref").value; carregar().catch(falha); } };

// ---------- dados ----------
async function carregar() {
  if (!L || !PODE) return;
  const [ini, fim] = periodo();
  $("f_ref").value = REF;
  $("per_txt").textContent = MODO === "dia" ? `${DW[dowI(ini)]} ${brA(ini)}` : `${br(ini)} a ${brA(fim)} (seg a dom)`;
  $("fx_tab").innerHTML = '<tr><td colspan="11" class="note">Carregando…</td></tr>';
  $("fx_tot").innerHTML = "";
  const [rg, fc, ln] = await Promise.all([
    sb().from("regras_pagamento").select("*").eq("loja_id", L.id).order("vigente_desde", { ascending: false }),
    sb().from("fechamentos").select("id,inicio,fim,total,fechado_em,fechado_por_email").eq("loja_id", L.id).order("inicio", { ascending: false }).limit(100),
    sb().from("lancamentos_entregador").select("*").eq("loja_id", L.id).gte("dia", ini).lte("dia", fim).order("dia").order("id"),
  ]);
  for (const r of [rg, fc, ln]) if (r.error) throw r.error;
  REGRAS = rg.data || [];
  const FS = fc.data || [];
  const exato = FS.find((f) => f.inicio === ini && f.fim === fim) || null;
  const sobre = FS.filter((f) => f.inicio <= fim && f.fim >= ini && f !== exato);
  let res, ent;
  if (exato) {
    const { data, error } = await sb().from("fechamentos").select("itens").eq("id", exato.id).single();
    if (error) throw error;
    res = data.itens.resumo || []; ent = data.itens.entregas || [];
  } else {
    const a = await sb().rpc("fechamento_resumo", { p_loja: L.id, p_ini: ini, p_fim: fim });
    if (a.error) throw a.error;
    res = a.data || [];
    ent = await Painel.tudo(() => sb().rpc("fechamento_entregas", { p_loja: L.id, p_ini: ini, p_fim: fim }));
  }
  A = { ini, fim, exato, sobre, res, ent, lanc: ln.data || [] };
  desenhar(); desenharRegras(); desenharHist(FS);
}

function porEntregador() {
  const M = {};
  for (const r of A.res) {
    const m = M[r.entregador] || (M[r.entregador] = { nome: r.entregador, dias: 0, entregas: 0, km: 0, valor_entregas: 0, diaria: 0, ajuste_minimo: 0, extras: 0, descontos: 0, total: 0, alertas: 0, linhas: [] });
    if (r.entregas > 0) m.dias++;
    for (const k of ["entregas", "km", "valor_entregas", "diaria", "ajuste_minimo", "extras", "descontos", "total", "alertas"]) m[k] += +(r[k] || 0);
    m.linhas.push(r);
  }
  return Object.values(M).sort((a, b) => b.total - a.total || a.nome.localeCompare(b.nome));
}

// ---------- tela ----------
function desenhar() {
  const E = porEntregador(), tot = (k) => E.reduce((s, m) => s + m[k], 0);
  const fechado = !!A.exato, emAndamento = A.fim >= hoje();
  const totalGeral = tot("total");

  // estado + ações
  let est = "";
  if (fechado) est = `<span class="tag fechado">Fechado</span><span>em ${quando(A.exato.fechado_em)}${A.exato.fechado_por_email ? " por " + esc(A.exato.fechado_por_email) : ""}. Valores congelados.</span>
    <button type="button" id="b_reabrir">Reabrir</button>`;
  else {
    const motivo = emAndamento ? "Período em andamento: prévia." : A.sobre.length ? `Parte deste período já foi fechada (${A.sobre.map((f) => f.inicio === f.fim ? br(f.inicio) : br(f.inicio) + "–" + br(f.fim)).join(", ")}). Reabra para fechar este período.` : "";
    est = `<span class="tag aberto">${emAndamento ? "Prévia" : "Aberto"}</span>${motivo ? `<span>${esc(motivo)}</span>` : ""}
      <button type="button" class="pri" id="b_fechar" ${emAndamento || A.sobre.length || !E.length ? "disabled" : ""}>Fechar período</button>`;
  }
  est += `<button type="button" id="b_imp" ${E.length ? "" : "disabled"}>Imprimir</button>`;
  $("fx_estado").innerHTML = est;

  $("fx_kpis").innerHTML = [["Entregadores", E.filter((m) => m.entregas).length, MODO === "dia" ? "trabalharam no dia" : `${tot("dias")} diárias na semana`],
    ["Entregas", tot("entregas").toLocaleString("pt-BR"), `${nf(tot("km"), 0)} km no total`],
    ["Por entrega", R$(tot("valor_entregas")), `diárias ${R$(tot("diaria"))}`],
    ["Total a pagar", R$(totalGeral), tot("extras") || tot("descontos") ? `extras ${R$(tot("extras"))} · descontos ${R$(tot("descontos"))}` : "sem lançamentos"]]
    .map(([l, b, s]) => `<div class="kpi"><small>${l}</small><div class="big">${b}</div><div class="sub">${s}</div></div>`).join("");

  // avisos
  const al = {}; for (const e of A.ent) if (e.alerta) al[e.alerta] = (al[e.alerta] || 0) + 1;
  const av = [], pl = (n, um, varios) => `${n} ${n === 1 ? um : varios}`;
  if (!REGRAS.length) av.push('Nenhuma regra de pagamento cadastrada para esta unidade. Cadastre uma em "Regra de pagamento", abaixo.');
  if (al["sem regra"]) av.push(`${pl(al["sem regra"], "entrega", "entregas")} sem regra vigente na data (valor R$ 0,00). Cadastre uma regra com início até ${br(A.ini)}.`);
  if (al["sem km (1ª faixa)"]) av.push(`${pl(al["sem km (1ª faixa)"], "entrega sem coordenadas: paga", "entregas sem coordenadas: pagas")} pela 1ª faixa.`);
  if (al["acima da última faixa"]) av.push(`${pl(al["acima da última faixa"], "entrega acima da última faixa: paga", "entregas acima da última faixa: pagas")} pelo valor de "acima".`);
  $("fx_alerta").innerHTML = av.map((t) => `<p class="aviso">${esc(t)}</p>`).join("");

  // tabela
  $("fx_tab").innerHTML = E.map((m) => {
    const id = encodeURIComponent(m.nome), ab = ABERTO.has(m.nome);
    return `<tr><td><b>${esc(m.nome)}</b>${m.alertas ? ` <span class="badge b-at" title="entregas com aviso">${m.alertas} aviso${m.alertas > 1 ? "s" : ""}</span>` : ""}</td>
      <td>${m.dias}</td><td>${m.entregas}</td><td>${nf(m.km)}</td><td>${R$(m.diaria)}</td><td>${R$(m.valor_entregas)}</td>
      <td>${m.ajuste_minimo ? R$(m.ajuste_minimo) : "–"}</td><td>${m.extras ? R$(m.extras) : "–"}</td><td>${m.descontos ? "−" + R$(m.descontos) : "–"}</td>
      <td><b>${R$(m.total)}</b></td>
      <td class="acoes"><button type="button" class="lnk" data-det="${id}" aria-expanded="${ab}">${ab ? "Fechar" : "Detalhes"}</button>${fechado ? "" : `<button type="button" class="lnk" data-lan="${id}">Lançar</button>`}</td></tr>
      ${ab ? `<tr class="det"><td colspan="11">${detalhe(m)}</td></tr>` : ""}`;
  }).join("") || `<tr><td colspan="11">Nenhuma entrega concluída ${MODO === "dia" ? "neste dia" : "nesta semana"}.</td></tr>`;
  $("fx_tot").innerHTML = E.length ? `<tr><td>Total</td><td>${tot("dias")}</td><td>${tot("entregas")}</td><td>${nf(tot("km"))}</td><td>${R$(tot("diaria"))}</td><td>${R$(tot("valor_entregas"))}</td>
    <td>${tot("ajuste_minimo") ? R$(tot("ajuste_minimo")) : "–"}</td><td>${tot("extras") ? R$(tot("extras")) : "–"}</td><td>${tot("descontos") ? "−" + R$(tot("descontos")) : "–"}</td><td>${R$(totalGeral)}</td><td></td></tr>` : "";

  // eventos
  $("fx_tab").querySelectorAll("[data-det]").forEach((b) => (b.onclick = () => { const n = decodeURIComponent(b.dataset.det); ABERTO.has(n) ? ABERTO.delete(n) : ABERTO.add(n); desenhar(); }));
  $("fx_tab").querySelectorAll("[data-lan]").forEach((b) => (b.onclick = () => abrirLanc(decodeURIComponent(b.dataset.lan))));
  $("fx_tab").querySelectorAll("[data-rmlan]").forEach((b) => (b.onclick = () => duasVezes(b, "Confirmar exclusão", async () => {
    const { error } = await sb().from("lancamentos_entregador").delete().eq("id", +b.dataset.rmlan);
    if (error) throw error; await carregar();
  })));
  $("fx_tab").querySelectorAll("[data-wa]").forEach((b) => (b.onclick = () => { const m = E.find((x) => x.nome === decodeURIComponent(b.dataset.wa)); window.open("https://wa.me/?text=" + encodeURIComponent(textoWA(m)), "_blank", "noopener"); }));
  $("fx_tab").querySelectorAll("[data-cp]").forEach((b) => (b.onclick = async () => { const m = E.find((x) => x.nome === decodeURIComponent(b.dataset.cp)); try { await navigator.clipboard.writeText(textoWA(m)); b.textContent = "Copiado ✓"; } catch (_) { b.textContent = "Não foi possível copiar"; } }));
  const bf = $("b_fechar");
  if (bf) bf.onclick = () => duasVezes(bf, `Confirmar: fechar ${R$(totalGeral)}`, async () => {
    const { error } = await sb().rpc("fechar_periodo", { p_loja: L.id, p_ini: A.ini, p_fim: A.fim });
    if (error) throw error; await carregar();
  });
  const br_ = $("b_reabrir");
  if (br_) br_.onclick = () => duasVezes(br_, "Confirmar reabertura", async () => {
    const { error } = await sb().rpc("reabrir_periodo", { p_id: A.exato.id });
    if (error) throw error; await carregar();
  });
  $("b_imp").onclick = () => imprimir(E);
}

// primeiro clique pede confirmação; segundo executa
function duasVezes(b, txt, fn) {
  if (!b.dataset.conf) { b.dataset.conf = b.textContent; b.textContent = txt; setTimeout(() => { if (b.isConnected && b.dataset.conf) { b.textContent = b.dataset.conf; delete b.dataset.conf; } }, 5000); return; }
  b.disabled = true; b.textContent = "Aguarde…";
  fn().catch((e) => { b.disabled = false; b.textContent = e.message || String(e); delete b.dataset.conf; });
}

function detalhe(m) {
  const fechado = !!A.exato;
  const ents = A.ent.filter((e) => e.entregador === m.nome);
  const dias = MODO === "sem" ? `<h3>Por dia</h3><div class="scroll"><table><thead><tr><th>Dia</th><th>Entregas</th><th>Km</th><th>Diária</th><th>Por entrega</th><th>Mínimo</th><th>Extras</th><th>Descontos</th><th>Total</th></tr></thead><tbody>
    ${m.linhas.map((r) => `<tr><td>${DW[dowI(r.dia)]} ${br(r.dia)}</td><td>${r.entregas}</td><td>${nf(r.km)}</td><td>${R$(r.diaria)}</td><td>${R$(r.valor_entregas)}</td><td>${+r.ajuste_minimo ? R$(r.ajuste_minimo) : "–"}</td><td>${+r.extras ? R$(r.extras) : "–"}</td><td>${+r.descontos ? "−" + R$(r.descontos) : "–"}</td><td><b>${R$(r.total)}</b></td></tr>`).join("")}
    </tbody></table></div>` : "";
  const lis = ents.map((e) => `<span class="${e.alerta ? "al" : ""}" title="${esc(e.alerta || "")}">${MODO === "sem" ? DW[dowI(e.dia)] + " " : ""}#${esc(e.numero || "?")} · ${hora(e.entregue_em)} · ${nf(e.km)} km · ${R$(e.valor)}${e.alerta ? " ⚠" : ""}</span>`).join("");
  const lanc = A.lanc.filter((l) => l.entregador === m.nome);
  const tipos = { extra: "Extra", desconto: "Desconto", vale: "Vale" };
  return `${dias}<h3>Entregas (${ents.length})</h3><div class="ents">${lis || '<span class="sm">nenhuma</span>'}</div>
    <h3>Lançamentos</h3>${lanc.length ? `<div class="scroll"><table><tbody>${lanc.map((l) => `<tr><td>${br(l.dia)} · ${tipos[l.tipo]}${l.descricao ? " · " + esc(l.descricao) : ""}</td><td>${l.tipo === "extra" ? "" : "−"}${R$(l.valor)}</td><td>${fechado ? "" : `<button type="button" class="lnk" data-rmlan="${l.id}">Excluir</button>`}</td></tr>`).join("")}</tbody></table></div>` : '<p class="sm" style="margin:0">Nenhum.</p>'}
    <div style="margin-top:10px;display:flex;gap:8px;flex-wrap:wrap"><button type="button" data-wa="${encodeURIComponent(m.nome)}">Enviar no WhatsApp</button><button type="button" data-cp="${encodeURIComponent(m.nome)}">Copiar texto</button></div>`;
}

function textoWA(m) {
  const per = A.ini === A.fim ? `${DW[dowI(A.ini)]} ${brA(A.ini)}` : `${br(A.ini)} a ${brA(A.fim)}`;
  const ln = [`*Fechamento · ${L.nome}*`, `Período: ${per}${A.exato ? "" : " (prévia)"}`, `Entregador: ${m.nome}`, ""];
  if (MODO === "sem") ln.push(`Dias trabalhados: ${m.dias}`);
  ln.push(`Entregas: ${m.entregas} (${nf(m.km)} km)`, `Diárias: ${R$(m.diaria)}`, `Por entrega: ${R$(m.valor_entregas)}`);
  if (m.ajuste_minimo) ln.push(`Complemento do mínimo: ${R$(m.ajuste_minimo)}`);
  for (const l of A.lanc.filter((x) => x.entregador === m.nome))
    ln.push(`${l.tipo === "extra" ? "Extra" : l.tipo === "vale" ? "Vale" : "Desconto"} ${br(l.dia)}${l.descricao ? " (" + l.descricao + ")" : ""}: ${l.tipo === "extra" ? "" : "−"}${R$(l.valor)}`);
  ln.push("", `*Total a receber: ${R$(m.total)}*`);
  return ln.join("\n");
}

function imprimir(E) {
  const per = A.ini === A.fim ? `${DW[dowI(A.ini)]} ${brA(A.ini)}` : `${br(A.ini)} a ${brA(A.fim)}`;
  const st = A.exato ? `Fechado em ${quando(A.exato.fechado_em)}${A.exato.fechado_por_email ? " por " + esc(A.exato.fechado_por_email) : ""}` : "Prévia — período não fechado";
  const resumo = `<h1>Fechamento dos entregadores · ${esc(L.nome)}</h1><div>${per} · ${st}</div>
    <table style="width:100%;margin-top:10px"><thead><tr><th style="text-align:left">Entregador</th><th>Dias</th><th>Entregas</th><th>Km</th><th>Diárias</th><th>Por entrega</th><th>Mínimo</th><th>Extras</th><th>Descontos</th><th>Total</th></tr></thead><tbody>
    ${E.map((m) => `<tr><td>${esc(m.nome)}</td><td>${m.dias}</td><td>${m.entregas}</td><td>${nf(m.km)}</td><td>${R$(m.diaria)}</td><td>${R$(m.valor_entregas)}</td><td>${R$(m.ajuste_minimo)}</td><td>${R$(m.extras)}</td><td>${R$(m.descontos)}</td><td><b>${R$(m.total)}</b></td></tr>`).join("")}
    <tr><td><b>Total</b></td><td></td><td>${E.reduce((s, m) => s + m.entregas, 0)}</td><td></td><td></td><td></td><td></td><td></td><td></td><td><b>${R$(E.reduce((s, m) => s + m.total, 0))}</b></td></tr></tbody></table>`;
  const recibos = E.map((m) => `<div class="recibo"><h1>Recibo · ${esc(m.nome)}</h1><div>${esc(L.nome)} · ${per}${A.exato ? "" : " · prévia"}</div>
    <pre style="font:inherit;white-space:pre-wrap;margin:12px 0">${esc(textoWA(m).replace(/\*/g, ""))}</pre>
    <h2>Entregas</h2><table><tbody>${A.ent.filter((e) => e.entregador === m.nome).map((e) => `<tr><td>${br(e.dia)}</td><td>#${esc(e.numero || "?")}</td><td>${hora(e.entregue_em)}</td><td>${nf(e.km)} km</td><td>${R$(e.valor)}</td></tr>`).join("")}</tbody></table>
    <div class="assina">Recebi o valor acima · ${esc(m.nome)}</div></div>`).join("");
  $("impressao").innerHTML = resumo + recibos + '<p style="margin-top:20px;font-size:10px">Um produto Dobra SaaS</p>';
  window.print();
}

// ---------- lançamentos ----------
function abrirLanc(nome) {
  const f = $("f_lanc"); f.reset(); msg(f, "");
  f.entregador.value = nome || "";
  $("dl_ent").innerHTML = [...new Set(A.res.map((r) => r.entregador))].map((n) => `<option value="${esc(n)}">`).join("");
  f.dia.min = A.ini; f.dia.max = A.fim; f.dia.value = A.fim;
  $("d_lanc").showModal();
}
$("f_lanc").onsubmit = async (e) => {
  e.preventDefault(); const f = e.target; msg(f, "Salvando…");
  const { error } = await sb().from("lancamentos_entregador").insert({ loja_id: L.id, dia: f.dia.value, entregador: f.entregador.value.trim(), tipo: f.tipo.value, valor: +f.valor.value, descricao: f.descricao.value.trim() || null });
  if (error) { msg(f, error.message, "err"); return; }
  $("d_lanc").close(); ABERTO.add(f.entregador.value.trim()); await carregar().catch(falha);
};

// ---------- regras ----------
function txtFaixas(fx) {
  let ant = 0;
  return fx.map((x) => {
    const t = x.ate_km == null ? `acima de ${nf(ant)} km` : `${ant ? "de " + nf(ant) + " a " : "até "}${nf(x.ate_km)} km`;
    if (x.ate_km != null) ant = x.ate_km;
    return `${t}: <b>${R$(x.valor)}</b>`;
  }).join(" · ");
}
function txtRegra(r) {
  return `Diária <b>${R$(r.diaria)}</b> · distância: ${r.base_km === "raio" ? "raio (linha reta)" : "km de rota estimado"}${r.minimo_dia != null ? ` · mínimo <b>${R$(r.minimo_dia)}</b>/dia` : ""}<br>${txtFaixas(r.faixas)}`;
}
function desenharRegras() {
  const ref = A.fim, atual = REGRAS.find((r) => r.vigente_desde <= ref) || null, fut = REGRAS.filter((r) => r.vigente_desde > ref);
  $("rg_atual").innerHTML = atual ? `<div class="regra"><div class="sm">Vale desde ${brA(atual.vigente_desde)} (aplicada a este período)</div>${txtRegra(atual)}</div>`
    : '<p class="aviso">Nenhuma regra vigente neste período.</p>';
  const outras = REGRAS.filter((r) => r !== atual);
  $("rg_hist").innerHTML = outras.length ? `<details style="margin-top:16px"><summary>Outras regras (${outras.length})</summary>${outras.map((r) => `<div class="regra"><div class="sm">${fut.includes(r) ? "Começa em" : "Valeu desde"} ${brA(r.vigente_desde)} <button type="button" class="lnk" data-rmrg="${r.id}">Excluir</button></div>${txtRegra(r)}</div>`).join("")}</details>` : "";
  $("rg_hist").querySelectorAll("[data-rmrg]").forEach((b) => (b.onclick = () => duasVezes(b, "Confirmar exclusão", async () => {
    const { error } = await sb().from("regras_pagamento").delete().eq("id", +b.dataset.rmrg);
    if (error) throw error; await carregar();
  })));
}
function linhaFx(ate, val) {
  const d = document.createElement("div"); d.className = "fxr"; d.dataset.f = "1";
  d.innerHTML = `<label>Até (km)<input type="number" name="ate" min="0.1" step="0.1" required value="${ate ?? ""}"></label><label>Valor (R$)<input type="number" name="val" min="0" step="0.01" required value="${val ?? ""}"></label><button type="button" class="lnk">Remover</button>`;
  d.querySelector("button").onclick = () => d.remove();
  $("rg_fx").appendChild(d);
}
$("b_addfx").onclick = () => linhaFx();
$("b_regra").onclick = () => {
  const f = $("f_regra"); f.reset(); msg(f, ""); $("rg_fx").innerHTML = "";
  const base = REGRAS[0];
  f.vigente_desde.value = A ? A.ini : hoje();
  if (base) {
    f.diaria.value = base.diaria; f.base_km.value = base.base_km; f.minimo_dia.value = base.minimo_dia ?? "";
    base.faixas.filter((x) => x.ate_km != null).forEach((x) => linhaFx(x.ate_km, x.valor));
    f.acima.value = (base.faixas.find((x) => x.ate_km == null) || {}).valor ?? "";
  } else [3, 5, 8].forEach((k) => linhaFx(k));
  $("d_regra").showModal();
};
$("f_regra").onsubmit = async (e) => {
  e.preventDefault(); const f = e.target;
  const fx = [...$("rg_fx").querySelectorAll(".fxr[data-f]")].map((d) => ({ ate_km: parseFloat(d.querySelector("[name=ate]").value), valor: parseFloat(d.querySelector("[name=val]").value) }));
  for (let i = 1; i < fx.length; i++) if (!(fx[i].ate_km > fx[i - 1].ate_km)) { msg(f, "As faixas precisam estar em ordem crescente de km, sem repetir.", "err"); return; }
  const faixas = [...fx, { ate_km: null, valor: parseFloat(f.acima.value) }];
  if (faixas.some((x) => !isFinite(x.valor) || x.valor < 0)) { msg(f, "Preencha todos os valores das faixas.", "err"); return; }
  msg(f, "Salvando…");
  const { error } = await sb().from("regras_pagamento").upsert({
    loja_id: L.id, vigente_desde: f.vigente_desde.value, diaria: +f.diaria.value, base_km: f.base_km.value,
    minimo_dia: f.minimo_dia.value === "" ? null : +f.minimo_dia.value, faixas,
  }, { onConflict: "loja_id,vigente_desde" });
  if (error) { msg(f, error.message, "err"); return; }
  $("d_regra").close(); await carregar().catch(falha);
};

// ---------- histórico ----------
function desenharHist(FS) {
  $("fh_tab").innerHTML = FS.map((f) => `<tr><td>${f.inicio === f.fim ? `${DW[dowI(f.inicio)]} ${brA(f.inicio)}` : `${br(f.inicio)} a ${brA(f.fim)}`}</td><td>${R$(f.total)}</td><td class="sm">${esc(f.fechado_por_email || "")}<br>${quando(f.fechado_em)}</td>
    <td><button type="button" class="lnk" data-ab="${f.inicio}|${f.fim}">Abrir</button></td></tr>`).join("") || '<tr><td colspan="4" class="sm">Nenhum fechamento ainda.</td></tr>';
  $("fh_tab").querySelectorAll("[data-ab]").forEach((b) => (b.onclick = () => { const [i, fi] = b.dataset.ab.split("|"); REF = i; modo(i === fi ? "dia" : "sem"); scrollTo({ top: 0, behavior: "smooth" }); }));
}

// a loja pode ter sido escolhida antes deste arquivo carregar
if (window.LOJA_ATUAL) window.onLojaMudou(window.LOJA_ATUAL);
document.querySelectorAll("#d_regra [data-fechar], #d_lanc [data-fechar]").forEach((b) => (b.onclick = () => b.closest("dialog").close()));
}
