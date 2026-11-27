// Conexão com o Supabase + tela de login compartilhada pelas páginas.
// A chave abaixo é a chave PÚBLICA (publishable): o acesso aos dados é controlado pelo login + RLS.
(function () {
  const URL = "https://wqntpofzgefubkorcltq.supabase.co";
  const KEY = "sb_publishable_RXTp2PLdnSSF7T3MkThYIQ_IvBUVN3G";
  const sb = window.supabase.createClient(URL, KEY, { auth: { persistSession: true, autoRefreshToken: true } });

  const css = `
  .lg-wrap{position:fixed;inset:0;z-index:50;display:grid;place-items:center;padding:20px;background:var(--bg,#fff);color:var(--ink,#141414)}
  .lg-box{width:min(380px,100%);display:flex;flex-direction:column;gap:12px}
  .lg-box h1{font:800 34px/1.05 "Sofia Sans Condensed","Barlow Condensed",system-ui,sans-serif;margin:0 0 6px}
  .lg-box p{margin:0 0 6px;color:var(--mute,#5f5f5f)}
  .lg-box label{display:flex;flex-direction:column;gap:4px;font-size:14px;color:var(--mute,#5f5f5f)}
  .lg-box input{font:inherit;font-size:16px;min-height:46px;padding:0 12px;border-radius:8px;border:1px solid var(--line,#ccc);background:transparent;color:inherit}
  .lg-box button{font:inherit;font-size:16px;min-height:46px;border-radius:8px;border:0;background:var(--ink,#141414);color:var(--bg,#fff);cursor:pointer;font-weight:600}
  .lg-err{color:#dc3c3d;font-size:14px;min-height:1.2em}`;

  function telaLogin(titulo) {
    return new Promise((resolve) => {
      const st = document.createElement("style"); st.textContent = css; document.head.appendChild(st);
      const w = document.createElement("div"); w.className = "lg-wrap";
      w.innerHTML = `<form class="lg-box"><h1></h1><p>Entre com o e-mail e a senha do seu acesso.</p>
        <label>E-mail<input type="email" name="e" autocomplete="username" required></label>
        <label>Senha<input type="password" name="s" autocomplete="current-password" required></label>
        <button type="submit">Entrar</button><div class="lg-err" role="alert"></div></form>`;
      w.querySelector("h1").textContent = titulo;
      document.body.appendChild(w);
      const f = w.querySelector("form"), err = w.querySelector(".lg-err");
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
    const { data, error } = await sb.from("lojas").select("*").eq("ativa", true).order("nome");
    if (error) throw error;
    return data || [];
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

  async function sair() { await sb.auth.signOut(); location.reload(); }

  // dia operacional (corte às 05h, fuso de São Paulo)
  function diaOperacional(d = new Date()) {
    const sp = new Date(d.getTime() - 3 * 3600e3 - 5 * 3600e3);
    return sp.toISOString().slice(0, 10);
  }

  window.Painel = { sb, exigirLogin, lojas, lojaPreferida, guardarLoja, tudo, sair, diaOperacional };
})();
