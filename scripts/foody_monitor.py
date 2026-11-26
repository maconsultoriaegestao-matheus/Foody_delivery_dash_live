#!/usr/bin/env python3
"""
Foody Delivery - MODO MONITOR (teste de polling)
------------------------------------------------
Só leitura: NÃO cria, altera nem cancela pedidos.

Simula o painel: a cada N segundos (padrão 30) consulta a API e registra
  - cada mudança de status dos pedidos, com horário
  - posição do motoboy nos pedidos em rota (onGoing)
  - todas as chamadas, tempo de resposta e erros (ex.: 429 = excesso de consultas)

Uso (Windows):
  python foody_monitor.py                       # começa agora, roda 60 min
  python foody_monitor.py --duracao 120         # roda 2 horas
  python foody_monitor.py --inicio 19:00        # espera até 19:00 para começar
  Para parar antes: Ctrl + C (o resumo é gerado mesmo assim)

Saída (pasta ./foody_monitor_<data>/), atualizada a cada ciclo:
  resumo.md       -> pode compartilhar (sem dados pessoais de clientes)
  eventos.csv     -> mudanças de status (sem dados pessoais de clientes)
  chamadas.csv    -> cada chamada à API, HTTP e tempo
  tracking.csv    -> posição dos motoboys por ciclo
  pedidos_final.json -> última foto completa (CONTÉM dados pessoais: não compartilhe)
"""
import argparse
import csv
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
TZ = timezone(timedelta(hours=-3))
PAUSA_TRACKING_429_S = 120  # após um 429 no rastreio, pausa o rastreio por 2 min


def agora():
    return datetime.now(TZ)


def fmt(dt):
    return dt.astimezone(TZ).strftime("%Y-%m-%dT%H:%M:%S") + "-03:00"


def parse(s):
    if not s or not isinstance(s, str):
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None


class Api:
    def __init__(self, token, pasta):
        self.h = {"Authorization": token,
                  "Content-Type": "application/json;charset=UTF-8",
                  "Accept": "application/json"}
        self.calls = []
        self.f = open(f"{pasta}/chamadas.csv", "w", newline="", encoding="utf-8-sig")
        self.w = csv.writer(self.f, delimiter=";")
        self.w.writerow(["horario", "metodo", "rota", "http", "ms", "erro"])

    def req(self, method, path, body=None):
        data = json.dumps(body).encode() if body is not None else None
        r = urllib.request.Request(BASE + path, data=data, method=method, headers=self.h)
        t0 = time.perf_counter()
        st, raw, err = None, "", ""
        try:
            with urllib.request.urlopen(r, timeout=20) as resp:
                st, raw = resp.status, resp.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            st, raw = e.code, e.read().decode("utf-8", "replace")
            err = raw[:200]
        except Exception as e:  # rede, timeout, SSL
            st, err = 0, f"{type(e).__name__}: {e}"[:200]
        ms = round((time.perf_counter() - t0) * 1000)
        rota = path.split("?")[0]
        rota_log = "/orders/tracking/{uid}" if "/tracking/" in rota else rota
        self.calls.append((agora(), method, rota_log, st, ms))
        self.w.writerow([agora().strftime("%H:%M:%S"), method, rota_log, st, ms, err])
        self.f.flush()
        try:
            payload = json.loads(raw) if raw else None
        except json.JSONDecodeError:
            payload = raw
        return st, payload


def as_list(p):
    if isinstance(p, list):
        return p
    if isinstance(p, dict):
        for k in ("orders", "data", "items", "content", "result"):
            if isinstance(p.get(k), list):
                return p[k]
    return []


def listar(api, inicio, rota_lista):
    """GET /orders com paginação de 500."""
    todos, cursor = [], inicio
    for _ in range(10):
        q = urllib.parse.urlencode({"startDate": fmt(cursor), "endDate": fmt(agora() + timedelta(minutes=5))})
        st, p = api.req("GET", f"{rota_lista}?{q}")
        if st != 200:
            return None, st
        lote = as_list(p)
        todos.extend(lote)
        if len(lote) < 500:
            break
        ult = parse(lote[-1].get("date"))
        if not ult:
            break
        cursor = ult + timedelta(seconds=1)
    return todos, 200


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--intervalo", type=int, default=30, help="segundos entre ciclos (mínimo 30)")
    ap.add_argument("--duracao", type=float, default=60, help="minutos de monitoramento")
    ap.add_argument("--inicio", help="HH:MM para começar (espera até lá)")
    ap.add_argument("--janela-horas", type=float, default=8, help="horas para trás na listagem")
    ap.add_argument("--tracking-por-ciclo", type=int, default=1, help="pedidos rastreados por ciclo (alternando)")
    a = ap.parse_args()
    intervalo = max(30, a.intervalo)

    token = os.getenv("FOODY_TOKEN") or getpass.getpass("Token Foody (não aparece ao digitar): ").strip()
    if not token:
        sys.exit("Token não informado.")

    if a.inicio:
        hh, mm = map(int, a.inicio.split(":"))
        alvo = agora().replace(hour=hh, minute=mm, second=0, microsecond=0)
        while agora() < alvo:
            falta = alvo - agora()
            print(f"\rAguardando {a.inicio}… faltam {str(falta).split('.')[0]}   ", end="", flush=True)
            time.sleep(min(30, max(1, falta.total_seconds())))
        print()

    t_ini = agora()
    pasta = f"foody_monitor_{t_ini.strftime('%Y%m%d_%H%M')}"
    os.makedirs(pasta, exist_ok=True)
    api = Api(token, pasta)
    inicio_lista = t_ini - timedelta(hours=a.janela_horas)
    fim = t_ini + timedelta(minutes=a.duracao)

    fe = open(f"{pasta}/eventos.csv", "w", newline="", encoding="utf-8-sig")
    we = csv.writer(fe, delimiter=";")
    we.writerow(["detectado_em", "pedido_id", "uid", "status_anterior", "status_novo",
                 "updateDate_api", "atraso_deteccao_s", "fonte", "entregador"])
    ft = open(f"{pasta}/tracking.csv", "w", newline="", encoding="utf-8-sig")
    wt = csv.writer(ft, delimiter=";")
    wt.writerow(["horario", "pedido_id", "http", "status", "lat_motoboy", "lng_motoboy", "pontos_entrega"])

    estado = {}          # uid -> status
    caminho = defaultdict(list)
    info = {}            # uid -> (id, entregador)
    atrasos_det = []
    divergencias = 0
    tracking_ok = tracking_vazio = 0
    posicoes = defaultdict(set)
    ciclos = 0
    rota_lista = "/orders"
    ultima_lista = []
    tracking_pausado_ate = 0.0
    fila_tracking = []
    pausas_429 = 0

    def registrar(uid, novo, upd, fonte):
        nonlocal atrasos_det
        ant = estado.get(uid)
        if ant == novo:
            return
        estado[uid] = novo
        caminho[uid].append(novo)
        d_upd = parse(upd)
        atraso = round((agora() - d_upd).total_seconds()) if d_upd else ""
        if ant is not None and isinstance(atraso, int):
            atrasos_det.append(atraso)
        pid, ent = info.get(uid, ("", ""))
        we.writerow([agora().strftime("%H:%M:%S"), pid, uid, ant or "(novo)", novo, upd, atraso, fonte, ent])
        fe.flush()
        if ant is not None:
            print(f"  {agora().strftime('%H:%M:%S')}  pedido {pid}: {ant} → {novo}  (atraso {atraso}s)")
        else:
            print(f"  {agora().strftime('%H:%M:%S')}  pedido {pid}: visto pela 1ª vez como {novo}")

    def escrever_resumo(final=False):
        L = ["# Foody Delivery – teste de polling (modo monitor)\n"]
        L.append(f"- Início: {t_ini.strftime('%d/%m/%Y %H:%M:%S')} | Última atualização: {agora().strftime('%H:%M:%S')}"
                 + (" (FINAL)" if final else " (em andamento)"))
        L.append(f"- Intervalo: {intervalo}s | Ciclos: {ciclos} | Pedidos acompanhados: {len(estado)}\n")
        L.append("## Chamadas à API\n")
        L.append("| Rota | Chamadas | Erros | HTTP recebidos | Média ms | p95 ms | Máx ms |\n|---|---|---|---|---|---|---|")
        por = defaultdict(list)
        for _, m, r, s, ms in api.calls:
            por[f"{m} {r}"].append((s, ms))
        for r, v in por.items():
            mss = sorted(x[1] for x in v)
            p95 = mss[min(len(mss) - 1, int(len(mss) * 0.95))]
            cods = Counter(x[0] for x in v)
            L.append(f"| `{r}` | {len(v)} | {sum(1 for x in v if x[0] != 200)} | {dict(cods)} | "
                     f"{statistics.mean(mss):.0f} | {p95} | {max(mss)} |")
        total = len(api.calls)
        mins = max(1e-9, (agora() - t_ini).total_seconds() / 60)
        n429 = sum(1 for c in api.calls if c[3] == 429)
        L.append(f"\n- Total: {total} chamadas ({total / mins:.1f}/min) | **HTTP 429: {n429}** | "
                 f"falhas de rede: {sum(1 for c in api.calls if c[3] == 0)}")

        L.append("\n## Mudanças de status\n")
        trans = Counter()
        for u, cam in caminho.items():
            for x, y in zip(cam, cam[1:]):
                trans[f"{x} → {y}"] += 1
        L.append(f"- Transições detectadas: {sum(trans.values())}")
        for t, c in trans.most_common():
            L.append(f"  - {t}: {c}")
        if atrasos_det:
            L.append(f"- Atraso de detecção (horário em que vimos − updateDate da API): média "
                     f"{statistics.mean(atrasos_det):.0f}s | mediana {statistics.median(atrasos_det):.0f}s | "
                     f"máx {max(atrasos_det)}s")
        L.append(f"- Divergências listagem × checkupdates: {divergencias}")
        L.append(f"- Status atuais: {dict(Counter(estado.values()))}")
        caminhos = Counter(" → ".join(c) for c in caminho.values() if len(c) > 1)
        if caminhos:
            L.append("\n**Sequências completas observadas:**\n")
            for c, n in caminhos.most_common(10):
                L.append(f"- {c} ({n})")

        L.append("\n## Rastreio do motoboy (onGoing)\n")
        L.append(f"- Respostas com posição: {tracking_ok} | vazias/erro: {tracking_vazio} | "
                 f"pausas por 429: {pausas_429} | rastreios por ciclo: {a.tracking_por_ciclo}")
        if posicoes:
            mov = sum(1 for s in posicoes.values() if len(s) > 1)
            L.append(f"- Pedidos rastreados: {len(posicoes)} | com posição mudando entre ciclos: {mov}")
        with open(f"{pasta}/resumo.md", "w", encoding="utf-8") as f:
            f.write("\n".join(L) + "\n")

    print(f"Monitorando até {fim.strftime('%H:%M')} a cada {intervalo}s. Ctrl+C para parar.\n")
    try:
        while agora() < fim:
            t0 = time.monotonic()
            ciclos += 1
            print(f"[{agora().strftime('%H:%M:%S')}] ciclo {ciclos}", flush=True)

            # 1) Listagem (pedidos novos + status atual)
            lista, st = listar(api, inicio_lista, rota_lista)
            if st == 404 and rota_lista == "/orders":
                rota_lista = "/orders/"
                lista, st = listar(api, inicio_lista, rota_lista)
            if lista is None:
                print(f"  listagem falhou: HTTP {st}")
                if st == 401:
                    print("  Token inválido. Encerrando.")
                    break
            else:
                ultima_lista = lista
                for p in lista:
                    uid = p.get("uid")
                    if not uid:
                        continue
                    info[uid] = (p.get("id", ""), (p.get("courier") or {}).get("courierName", ""))
                    registrar(uid, p.get("status"), p.get("updateDate"), "listagem")

            # 2) checkupdates nos pedidos ainda ativos
            ativos = [u for u, s in estado.items() if s not in ("closed", "cancelled", "rejected", "delivered")]
            if ativos:
                st, cu = api.req("POST", "/orders/checkupdates", ativos[:100])
                if st == 200 and isinstance(cu, list):
                    for item in cu:
                        u, s = item.get("uid"), item.get("status")
                        if u in estado and s and s != estado[u]:
                            divergencias += 1
                            registrar(u, s, item.get("updateDate"), "checkupdates")

            # 3) Rastreio dos pedidos em rota (alternando, com pausa após 429)
            em_rota = [u for u, s_ in estado.items() if s_ == "onGoing"]
            fila_tracking = [u for u in fila_tracking if u in em_rota] + [u for u in em_rota if u not in fila_tracking]
            if time.monotonic() >= tracking_pausado_ate:
                for _ in range(min(a.tracking_por_ciclo, len(fila_tracking))):
                    u = fila_tracking.pop(0)
                    fila_tracking.append(u)
                    st, tr = api.req("GET", f"/orders/tracking/{u}")
                    if st == 429:
                        tracking_pausado_ate = time.monotonic() + PAUSA_TRACKING_429_S
                        pausas_429 += 1
                        print(f"  rastreio: 429, pausando {PAUSA_TRACKING_429_S}s")
                    loc = (tr or {}).get("courierLocationCoordinates") if isinstance(tr, dict) else None
                    lat = (loc or {}).get("lat") if isinstance(loc, dict) else None
                    lng = (loc or {}).get("lng") if isinstance(loc, dict) else None
                    if st == 200 and lat is not None:
                        tracking_ok += 1
                        posicoes[u].add((lat, lng))
                    else:
                        tracking_vazio += 1
                    npts = len((tr or {}).get("pointsToDelivery") or []) if isinstance(tr, dict) else ""
                    wt.writerow([agora().strftime("%H:%M:%S"), info.get(u, ("",))[0], st,
                                 (tr or {}).get("status") if isinstance(tr, dict) else "", lat, lng, npts])
                    ft.flush()
                    if st == 429:
                        break

            escrever_resumo()
            espera = intervalo - (time.monotonic() - t0)
            if espera > 0 and agora() < fim:
                time.sleep(espera)
    except KeyboardInterrupt:
        print("\nInterrompido pelo usuário.")

    escrever_resumo(final=True)
    with open(f"{pasta}/pedidos_final.json", "w", encoding="utf-8") as f:
        json.dump(ultima_lista, f, ensure_ascii=False, indent=2)
    print(f"\nPronto. Resultados em ./{pasta}/")
    print("  resumo.md, eventos.csv, chamadas.csv, tracking.csv -> pode compartilhar")
    print("  pedidos_final.json -> contém dados pessoais, não compartilhe")


if __name__ == "__main__":
    import traceback
    try:
        main()
    except Exception:
        txt = traceback.format_exc()
        print("\nERRO INESPERADO:\n" + txt)
        with open("erro_foody_monitor.txt", "w", encoding="utf-8") as f:
            f.write(txt)
    input("\nPressione Enter para fechar…")
