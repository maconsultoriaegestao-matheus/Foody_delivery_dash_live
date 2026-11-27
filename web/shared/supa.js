// Conexão com o Supabase + tela de login compartilhada pelas páginas.
// A chave abaixo é a chave PÚBLICA (publishable): o acesso aos dados é controlado pelo login + RLS.
(function () {
  const URL = "https://wqntpofzgefubkorcltq.supabase.co";
  const KEY = "sb_publishable_RXTp2PLdnSSF7T3MkThYIQ_IvBUVN3G";
  const sb = window.supabase.createClient(URL, KEY, { auth: { persistSession: true, autoRefreshToken: true } });


  // ---------- Marca Dobra ----------
  const SIMBOLO = `<svg viewBox="310 300 310 285" aria-hidden="true" focusable="false"><path fill="#fe7237" d="M421,381V330q0,-23,23,-23H590q23,0,23,23V467H506V381Z"/><path fill="currentColor" d="M353,397H490V579H353q-37,0,-37,-37V434q0,-37,37,-37Z"/><path fill="currentColor" d="M506,483H613V552q0,27,-27,27H506Z"/></svg>`;
  function selo() {
    if (document.querySelector(".dobra-selo")) return;
    const st = document.createElement("style");
    st.textContent = `.dobra-selo{display:flex;justify-content:flex-end;align-items:center;gap:7px;font:500 12px/1 system-ui,sans-serif;
      color:var(--dobra-ink,#421f4a);opacity:.6;padding:10px max(2vw,16px) 14px}
      .dobra-selo svg{width:18px;height:17px;color:var(--dobra-roxo,#421f4a)}.dobra-selo b{font-weight:700}`;
    document.head.appendChild(st);
    const a = document.createElement("div");
    a.className = "dobra-selo"; a.title = "Este é um produto desenvolvido por Dobra SaaS";
    a.innerHTML = SIMBOLO + "<span>Um produto <b>Dobra SaaS</b></span>";
    document.body.appendChild(a);
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", selo); else selo();
  const css = `
  .lg-wrap{position:fixed;inset:0;z-index:50;display:grid;place-items:center;padding:20px;background:var(--bg,#fff);color:var(--ink,#141414)}
  .lg-box{width:min(380px,100%);display:flex;flex-direction:column;gap:12px}
  .lg-box h1{font:800 34px/1.05 "Sofia Sans Condensed","Barlow Condensed",system-ui,sans-serif;margin:0 0 6px}
  .lg-box p{margin:0 0 6px;color:var(--mute,#5f5f5f)}
  .lg-box label{display:flex;flex-direction:column;gap:4px;font-size:14px;color:var(--mute,#5f5f5f)}
  .lg-box input{font:inherit;font-size:16px;min-height:46px;padding:0 12px;border-radius:8px;border:1px solid var(--line,#ccc);background:transparent;color:inherit}
  .lg-box button{font:inherit;font-size:16px;min-height:46px;border-radius:8px;border:0;background:var(--ink,#141414);color:var(--bg,#fff);cursor:pointer;font-weight:600}
  .lg-err{color:#dc3c3d;font-size:14px;min-height:1.2em}
  .lg-marca{display:flex;align-items:center;gap:10px;margin-bottom:18px;color:var(--dobra-roxo,#421f4a);font:700 26px/1 "Outfit","Instrument Sans",system-ui,sans-serif}
  .lg-marca svg{width:38px;height:35px}
  .lg-box .lg-esq{background:none;color:inherit;border:1px solid var(--line,#ccc);font-weight:400}
  .lg-err.ok{color:#0aac23}`;

  function telaLogin(titulo) {
    return new Promise((resolve) => {
      const st = document.createElement("style"); st.textContent = css; document.head.appendChild(st);
      const w = document.createElement("div"); w.className = "lg-wrap";
      w.innerHTML = `<form class="lg-box"><div class="lg-marca">${SIMBOLO}<span>Dobra</span></div><h1></h1><p>Entre com o e-mail e a senha do seu acesso.</p>
        <label>E-mail<input type="email" name="e" autocomplete="username" required></label>
        <label>Senha<input type="password" name="s" autocomplete="current-password" required></label>
        <button type="submit">Entrar</button>
        <button type="button" class="lg-esq">Esqueci minha senha</button><div class="lg-err" role="alert"></div></form>`;
      w.querySelector("h1").textContent = titulo;
      document.body.appendChild(w);
      const f = w.querySelector("form"), err = w.querySelector(".lg-err");
      w.querySelector(".lg-esq").addEventListener("click", async () => {
        const email = f.e.value.trim();
        if (!email) { err.className = "lg-err"; err.textContent = "Digite seu e-mail acima e clique de novo."; return; }
        err.className = "lg-err"; err.textContent = "Enviando…";
        const { error } = await sb.auth.resetPasswordForEmail(email, { redirectTo: location.origin + "/senha/" });
        err.className = error ? "lg-err" : "lg-err ok";
        err.textContent = error ? "Não foi possível enviar agora. Tente de novo em alguns minutos." : "Se o e-mail estiver cadastrado, você vai receber um link para criar uma nova senha.";
      });
      f.addEventListener("submit", async (ev) => {
        ev.preventDefault(); err.textContent = "Entrando…";
        const { data, error } = await sb.auth.signInWithPassword({ email: f.e.value.trim(), password: f.s.value });
        if (error) { err.textContent = "E-mail ou senha incorretos."; return; }
        w.remove(); st.remove(); resolve(data.session);
      });
    });
  }

  async function exigirLogin(titulo) {
    const { data: { session } } = await sb.auth.getSession();
    return session || telaLogin(titulo || "Foody Painel");
  }

  async function lojas() {
    const { data, error } = await sb.from("lojas").select("*, clientes(nome)").eq("ativa", true).order("nome");
    if (error) throw error;
    // nome exibido: "Cliente · Unidade"
    return (data || []).map((l) => ({ ...l, unidade: l.nome, nome: l.clientes?.nome ? `${l.clientes.nome} · ${l.nome}` : l.nome }))
      .sort((a, b) => a.nome.localeCompare(b.nome));
  }

  function lojaPreferida(lista) {
    let id = null;
    try { id = localStorage.getItem("foody_loja"); } catch (_) {}
    return lista.find((l) => l.id === id) || lista[0] || null;
  }
  function guardarLoja(id) { try { localStorage.setItem("foody_loja", id); } catch (_) {} }

  async function tudo(consulta, passo = 1000) {
    const out = [];
    for (let de = 0; ; de += passo) {
      const { data, error } = await consulta().range(de, de + passo - 1);
      if (error) throw error;
      out.push(...data);
      if (data.length < passo) break;
    }
    return out;
  }

  // chama a função de administração (só administradores)
  async function admin(acao, dados = {}) {
    const { data, error } = await sb.functions.invoke("admin", { body: { acao, ...dados } });
    if (error) {
      let msg = error.message;
      try { const j = await error.context.json(); msg = j.erro || msg; } catch (_) {}
      throw new Error(msg);
    }
    return data;
  }

  async function sair() { await sb.auth.signOut(); location.reload(); }

  // dia operacional (corte às 05h, fuso de São Paulo)
  function diaOperacional(d = new Date()) {
    const sp = new Date(d.getTime() - 3 * 3600e3 - 5 * 3600e3);
    return sp.toISOString().slice(0, 10);
  }

  window.Painel = { SIMBOLO, sb, exigirLogin, lojas, lojaPreferida, guardarLoja, tudo, sair, diaOperacional, admin };
})();
