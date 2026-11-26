#!/usr/bin/env python3
"""
Teste exploratório da Foody Delivery API v1.2
------------------------------------------------
Só leitura: NÃO cria, altera nem cancela pedidos.

O que faz:
  1. GET /orders por período (com paginação de 500)  -> mede tempo de resposta
  2. Inventário de campos: quais vêm preenchidos e com que frequência
  3. Indicadores de exemplo: status, tempos por etapa, taxas, entregadores
  4. POST /orders/checkupdates com alguns uids        -> testa o polling leve
  5. GET /orders/{uid} e /orders/tracking/{uid} (se houver pedido em rota)

Uso (Python 3.8+, sem dependências):
  python3 foody_api_teste.py                 # pede o token de forma oculta
  python3 foody_api_teste.py --dias 3        # janela dos últimos 3 dias (padrão: 1)
  FOODY_TOKEN=xxxx python3 foody_api_teste.py

Saída (pasta ./foody_teste_<data>/):
  relatorio.md       -> resumo para ler/compartilhar (dados pessoais mascarados)
  pedidos_raw.json   -> resposta bruta da API (CONTÉM dados pessoais: não compartilhe)
  amostra_pedido.json, checkupdates.json, tracking.json
"""
import argparse
import getpass
import json
import os
import statistics
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone

BASE = "https://app.foodydelivery.com/rest/1.2"
TZ = timezone(timedelta(hours=-3))  # America/Sao_Paulo
PII_KEYS = {"customerName", "customerPhone", "customerEmail", "courierPhone",
            "address", "street", "houseNumber", "complement", "postalCode",
            "coordinates", "courierLocationCoordinates"}
DATE_FIELDS = ["creationDate", "date", "readyDate", "despatchDate",
               "collectedDate", "deliveryDate", "deliveryDueDate", "updateDate"]


# ---------------------------------------------------------------- HTTP
class Api:
    def __init__(self, token, partner_token=None):
        self.headers = {"Authorization": token,
                        "Content-Type": "application/json;charset=UTF-8",
                        "Accept": "application/json"}
        if partner_token:
            self.headers["SoftwareCompanyPartnerToken"] = partner_token
        self.calls = []  # (método, rota, status, ms)

    def req(self, method, path, body=None):
        url = BASE + path
        data = json.dumps(body).encode() if body is not None else None
        r = urllib.request.Request(url, data=data, method=method, headers=self.headers)
        t0 = time.perf_counter()
        status, payload = None, None
        try:
            with urllib.request.urlopen(r, timeout=30) as resp:
                status = resp.status
                raw = resp.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            status = e.code
            raw = e.read().decode("utf-8", "replace")
        ms = (time.perf_counter() - t0) * 1000
        self.calls.append((method, path.split("?")[0], status, round(ms)))
        try:
            payload = json.loads(raw) if raw else None
        except json.JSONDecodeError:
            payload = raw
        time.sleep(0.5)  # educado com a API
        return status, payload


def as_list(payload):
    """A listagem pode vir como lista ou embrulhada num objeto."""
    if isinstance(payload, list):
        return payload
    if isinstance(payload, dict):
        for k in ("orders", "data", "items", "content", "result"):
            if isinstance(payload.get(k), list):
                return payload[k]
    return []


# ---------------------------------------------------------------- util
def fmt_date(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%S") + "-03:00"


def parse_date(s):
    if not s or not isinstance(s, str):
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None


def flatten(obj, prefix=""):
    out = {}
    if isinstance(obj, dict):
        for k, v in obj.items():
            key = f"{prefix}.{k}" if prefix else k
            if isinstance(v, dict):
                out.update(flatten(v, key))
            else:
                out[key] = v
    return out


def mask(key, value):
    if PII_KEYS & set(key.split(".")) and value not in (None, ""):
        return "«oculto»"
    s = json.dumps(value, ensure_ascii=False) if not isinstance(value, str) else value
    return (s[:60] + "…") if len(s) > 60 else s


def mins(a, b):
    da, db = parse_date(a), parse_date(b)
    if da and db:
        return (db - da).total_seconds() / 60
    return None


def stats_line(vals):
    vals = [v for v in vals if v is not None and 0 <= v < 24 * 60]
    if not vals:
        return "sem dados"
    return (f"n={len(vals)} | média {statistics.mean(vals):.1f} min | "
            f"mediana {statistics.median(vals):.1f} | máx {max(vals):.1f}")


# ---------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dias", type=float, default=1, help="janela de consulta em dias")
    ap.add_argument("--partner-token", default=os.getenv("FOODY_PARTNER_TOKEN"))
    args = ap.parse_args()

    token = os.getenv("FOODY_TOKEN") or getpass.getpass("Token Foody (não aparece ao digitar): ").strip()
    if not token:
        sys.exit("Token não informado.")
    api = Api(token, args.partner_token)

    fim = datetime.now(TZ)
    inicio = fim - timedelta(days=args.dias)
    pasta = f"foody_teste_{fim.strftime('%Y%m%d_%H%M')}"
    os.makedirs(pasta, exist_ok=True)

    # 1. Listagem paginada --------------------------------------------
    print(f"Consultando pedidos de {fmt_date(inicio)} até {fmt_date(fim)}…")
    pedidos, cursor, paginas, erro = [], inicio, 0, None
    while True:
        q = urllib.parse.urlencode({"startDate": fmt_date(cursor), "endDate": fmt_date(fim)})
        st, payload = api.req("GET", f"/orders?{q}")
        if st == 404:  # variação de rota: com barra final
            st, payload = api.req("GET", f"/orders/?{q}")
        if st != 200:
            erro = (st, payload)
            break
        lote = as_list(payload)
        paginas += 1
        pedidos.extend(lote)
        print(f"  página {paginas}: {len(lote)} pedidos")
        if len(lote) < 500 or paginas >= 20:
            break
        ultimo = parse_date(lote[-1].get("date"))
        if not ultimo:
            break
        cursor = (ultimo + timedelta(seconds=1)).astimezone(TZ)

    if erro:
        msg = (f"Erro na listagem: HTTP {erro[0]} -> {erro[1]}\n"
               "Dicas: 401/E19 = token inválido | 403/E11 = plano gratuito sem API | 400/E09 = datas.\n")
        print("\n" + msg)
        with open(f"{pasta}/erro.txt", "w", encoding="utf-8") as f:
            f.write(msg)
        if not pedidos:
            return

    with open(f"{pasta}/pedidos_raw.json", "w", encoding="utf-8") as f:
        json.dump(pedidos, f, ensure_ascii=False, indent=2)

    # 2. Inventário de campos -----------------------------------------
    preench, exemplo = Counter(), {}
    for p in pedidos:
        for k, v in flatten(p).items():
            if v not in (None, "", [], {}):
                preench[k] += 1
                exemplo.setdefault(k, v)
    todos_campos = sorted({k for p in pedidos for k in flatten(p)})

    # 3. Indicadores ----------------------------------------------------
    status = Counter(p.get("status") for p in pedidos)
    t_preparo = [mins(p.get("date") or p.get("creationDate"), p.get("readyDate")) for p in pedidos]
    t_ate_despacho = [mins(p.get("readyDate"), p.get("despatchDate")) for p in pedidos]
    t_coleta = [mins(p.get("despatchDate"), p.get("collectedDate")) for p in pedidos]
    t_rota = [mins(p.get("collectedDate"), p.get("deliveryDate")) for p in pedidos]
    t_total = [mins(p.get("date") or p.get("creationDate"), p.get("deliveryDate")) for p in pedidos]
    no_prazo = [parse_date(p.get("deliveryDate")) <= parse_date(p.get("deliveryDueDate"))
                for p in pedidos if parse_date(p.get("deliveryDate")) and parse_date(p.get("deliveryDueDate"))]

    def soma(campo):
        return sum(float(p.get(campo) or 0) for p in pedidos if isinstance(p.get(campo), (int, float, str))
                   and str(p.get(campo)).replace(".", "", 1).isdigit())

    entregadores = defaultdict(list)
    for p in pedidos:
        nome = (p.get("courier") or {}).get("courierName")
        if nome:
            entregadores[nome].append(mins(p.get("collectedDate"), p.get("deliveryDate")))
    pagamento = Counter(p.get("paymentMethod") for p in pedidos)
    despacho = Counter(p.get("despatchMode") for p in pedidos)
    coleta = Counter((p.get("collectionPoint") or {}).get("name") for p in pedidos)

    # 4. checkupdates (polling leve) ----------------------------------
    uids = [p["uid"] for p in pedidos if p.get("uid")][:20]
    cu_status, cu = (None, None)
    if uids:
        cu_status, cu = api.req("POST", "/orders/checkupdates", uids)
        if cu_status != 200:  # algumas APIs esperam objeto em vez de lista
            cu_status, cu = api.req("POST", "/orders/checkupdates", {"uids": uids})
        with open(f"{pasta}/checkupdates.json", "w", encoding="utf-8") as f:
            json.dump({"http": cu_status, "resposta": cu}, f, ensure_ascii=False, indent=2)

    # 5. Detalhe de 1 pedido + tracking ------------------------------
    det_status = None
    if uids:
        det_status, det = api.req("GET", f"/orders/{uids[0]}")
        with open(f"{pasta}/amostra_pedido.json", "w", encoding="utf-8") as f:
            json.dump(det, f, ensure_ascii=False, indent=2)
    em_rota = [p["uid"] for p in pedidos if p.get("status") == "onGoing" and p.get("uid")]
    tr_status = None
    if em_rota:
        tr_status, tr = api.req("GET", f"/orders/tracking/{em_rota[0]}")
        with open(f"{pasta}/tracking.json", "w", encoding="utf-8") as f:
            json.dump({"http": tr_status, "resposta": tr}, f, ensure_ascii=False, indent=2)

    # ---------------------------------------------------------------- relatório
    n = len(pedidos) or 1
    L = []
    L.append("# Teste Foody Delivery API v1.2\n")
    L.append(f"- Executado em: {fim.strftime('%d/%m/%Y %H:%M')} (UTC-3)")
    L.append(f"- Janela: {fmt_date(inicio)} → {fmt_date(fim)}")
    L.append(f"- Pedidos retornados: **{len(pedidos)}** em {paginas} página(s)\n")

    L.append("## Chamadas e tempo de resposta\n")
    L.append("| Método | Rota | HTTP | ms |\n|---|---|---|---|")
    for m, r, s, ms in api.calls:
        L.append(f"| {m} | `{r}` | {s} | {ms} |")
    if uids:
        L.append(f"\n- checkupdates com {len(uids)} uids: HTTP {cu_status}")
    L.append(f"- Tracking: {'HTTP ' + str(tr_status) if em_rota else 'nenhum pedido em onGoing na janela'}\n")

    L.append("## Pedidos por status\n")
    for s, c in status.most_common():
        L.append(f"- `{s}`: {c} ({c / n:.0%})")

    L.append("\n## Tempos por etapa (min)\n")
    L.append(f"- Pedido → pronto (`date`→`readyDate`): {stats_line(t_preparo)}")
    L.append(f"- Pronto → despacho (`readyDate`→`despatchDate`): {stats_line(t_ate_despacho)}")
    L.append(f"- Despacho → coleta (`despatchDate`→`collectedDate`): {stats_line(t_coleta)}")
    L.append(f"- Coleta → entrega (`collectedDate`→`deliveryDate`): {stats_line(t_rota)}")
    L.append(f"- Total (`date`→`deliveryDate`): {stats_line(t_total)}")
    if no_prazo:
        L.append(f"- Entregues até o `deliveryDueDate`: {sum(no_prazo)}/{len(no_prazo)} ({sum(no_prazo) / len(no_prazo):.0%})")

    L.append("\n## Valores (soma na janela)\n")
    for c in ("orderTotal", "deliveryFee", "courierFee"):
        L.append(f"- `{c}`: R$ {soma(c):,.2f}".replace(",", "X").replace(".", ",").replace("X", "."))
    L.append(f"- Formas de pagamento: {dict(pagamento.most_common())}")
    L.append(f"- Modo de despacho: {dict(despacho.most_common())}")
    L.append(f"- Pontos de coleta (lojas): {dict(coleta.most_common(10))}")

    L.append("\n## Entregadores (top 10 por volume)\n")
    L.append("| Entregador | Entregas | Tempo médio coleta→entrega |\n|---|---|---|")
    for nome, ts in sorted(entregadores.items(), key=lambda x: -len(x[1]))[:10]:
        v = [t for t in ts if t is not None and 0 <= t < 1440]
        L.append(f"| {nome} | {len(ts)} | {statistics.mean(v):.1f} min |" if v else f"| {nome} | {len(ts)} | – |")

    L.append("\n## Inventário de campos\n")
    L.append("Preenchimento = % dos pedidos com valor. Dados pessoais aparecem como «oculto».\n")
    L.append("| Campo | Preenchido | Exemplo |\n|---|---|---|")
    for k in todos_campos:
        L.append(f"| `{k}` | {preench[k] / n:.0%} | {mask(k, exemplo.get(k, '')) if k in exemplo else ''} |")

    with open(f"{pasta}/relatorio.md", "w", encoding="utf-8") as f:
        f.write("\n".join(L) + "\n")

    print(f"\nPronto. Resultados em ./{pasta}/")
    print("  relatorio.md      -> pode compartilhar (dados pessoais mascarados)")
    print("  pedidos_raw.json  -> contém dados pessoais, não compartilhe")


if __name__ == "__main__":
    import traceback
    try:
        main()
    except SystemExit as e:
        if e.code not in (None, 0):
            print(e.code)
    except Exception:
        txt = traceback.format_exc()
        print("\nERRO INESPERADO:\n" + txt)
        with open("erro_foody_teste.txt", "w", encoding="utf-8") as f:
            f.write(txt)
        print("Detalhes salvos em erro_foody_teste.txt")
    input("\nPressione Enter para fechar…")
