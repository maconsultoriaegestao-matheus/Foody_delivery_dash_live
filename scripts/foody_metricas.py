#!/usr/bin/env python3
"""
Foody Delivery – cálculo das métricas operacionais
---------------------------------------------------
Entrada: lista de pedidos no formato da API v1.2 (GET /orders).
Saída:   métricas por pedido, por viagem e resumo.

Uso:  python foody_metricas.py pedidos_raw.json   -> gera pedidos.csv, viagens.csv, resumo no terminal

DEFINIÇÕES (campos da API)
  abertura        = date
  despacho        = despatchDate      (loja atribui o pedido ao motoboy)
  aceite          = acceptanceDate    (motoboy aceita no app)
  coleta          = collectedDate     (motoboy pega o pedido)
  entrega         = deliveryDate      (baixa no cliente)
  readyDate       -> NÃO usado: na operação analisada é automático (~10 min após a abertura)

  VIAGEM (saída do motoboy): pedidos do mesmo entregador coletados antes de ele concluir
      a primeira entrega válida da viagem atual. Agrupar só por despatchDate idêntico perde
      viagens em que os pedidos foram despachados com segundos ou minutos de diferença.

  BAIXAS SUSPEITAS (saem das médias de trânsito/rota/retorno, mas viram indicador):
      imediata  = coleta → entrega < 2 min (baixa dada na própria loja, sem registrar a rota)
      retorno   = entrega marcada a ±2 min da próxima coleta do mesmo motoboy
                  (baixa dada ao voltar para a loja: trânsito inflado, retorno zerado)
  saída da viagem = última coleta da viagem

  1 tempo até despacho = despacho − abertura (cozinha + fila; separar exige "pronto" real)
  2 espera p/ saída    = saída da viagem − despacho do pedido
  3 trânsito do pedido = 1º entregue: entrega − saída; demais: entrega − entrega anterior da viagem
  4 retorno/ocioso     = saída da próxima viagem − última entrega da viagem (mesmo entregador)
  5 pedidos por viagem = nº de pedidos na viagem
"""
import csv
import json
import statistics as st
import sys
from collections import Counter, defaultdict
from datetime import datetime

BAIXA_SUSPEITA_MIN = 2  # coleta → entrega abaixo disso = "baixa imediata" (sem rota real)
RETORNO_MIN = 2         # entrega marcada até 2 min antes/depois da próxima coleta = "baixa no retorno"
OCIOSO_MAX_MIN = 60     # hiato maior que isso = pausa/fim de turno: não entra na média nem nas horas ativas
LOTE_MIN = 1            # 2º+ pedido da viagem entregue <1 min após o anterior = baixa em lote
VEL_MAX_KMH = 45        # 1º trecho mais rápido que isso (km rota estimado) = baixa antecipada
TRANSITO_MAX_MIN = 60   # trecho acima disso sai da média
DESPACHO_MIN_MIN = 2    # abertura → despacho abaixo disso (pedidos lançados à mão depois) sai da média
DESPACHO_MAX_MIN = 60
TOTAL_MAX_MIN = 120
import math


def km_rota(p):
    """Usa _rota se vier do relatório; senão estima pela linha reta (fórmula calibrada em 25/11)."""
    if p.get("_rota") is not None:
        return p["_rota"]
    try:
        a, b = p["collectionPoint"]["coordinates"], p["deliveryPoint"]["coordinates"]
    except (KeyError, TypeError):
        return None
    la1, lo1, la2, lo2 = map(math.radians, [a["lat"], a["lng"], b["lat"], b["lng"]])
    raio = 2 * 6371 * math.asin(math.sqrt(math.sin((la2 - la1) / 2) ** 2 +
                                          math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2))
    return round(1.18 * raio + 0.55, 2)


def _d(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00")) if s else None


def _min(a, b):
    return round((b - a).total_seconds() / 60, 2) if a and b else None


def marcar_baixas(pedidos):
    """Marca _imediata e _retorno em cada pedido (por entregador)."""
    por_ent = defaultdict(list)
    for p in pedidos:
        p["_imediata"] = p["_retorno"] = False
        if p.get("courier", {}).get("courierName") and p.get("collectedDate"):
            por_ent[p["courier"]["courierName"].strip()].append(p)
    for ps in por_ent.values():
        cols = sorted(_d(p["collectedDate"]) for p in ps)
        for p in ps:
            col, ent = _d(p["collectedDate"]), _d(p.get("deliveryDate"))
            if not ent:
                continue
            if _min(col, ent) < BAIXA_SUSPEITA_MIN:
                p["_imediata"] = True
                continue
            if any(c > col and abs(_min(ent, c)) <= RETORNO_MIN for c in cols):
                p["_retorno"] = True


def montar_viagens(pedidos):
    marcar_baixas(pedidos)
    validos = [p for p in pedidos
               if p.get("courier", {}).get("courierName") and p.get("collectedDate")
               and p.get("status") not in ("cancelled", "rejected")]
    por_ent = defaultdict(list)
    for p in validos:
        por_ent[p["courier"]["courierName"].strip()].append(p)

    viagens = []
    for ent, ps in por_ent.items():
        ps.sort(key=lambda p: _d(p["collectedDate"]))
        atual = []
        for p in ps:
            col = _d(p["collectedDate"])
            if atual:
                entregas = [_d(x["deliveryDate"]) for x in atual if x.get("deliveryDate") and not x["_imediata"]]
                if entregas:
                    nova = _min(min(entregas), col) > -RETORNO_MIN
                else:  # só baixas imediatas: agrupa se coletado até 5 min depois
                    nova = _min(max(_d(x["collectedDate"]) for x in atual), col) > 5
                if nova:
                    viagens.append((ent, atual))
                    atual = []
            atual.append(p)
        if atual:
            viagens.append((ent, atual))
    return viagens


def calcular(pedidos):
    viagens = montar_viagens(pedidos)
    linhas_p, linhas_v = [], []
    ultima_por_ent = {}  # entregador -> fim da viagem anterior
    ultima_suspeita = {}  # entregador -> viagem anterior teve baixa suspeita

    viagens.sort(key=lambda v: max(_d(p["collectedDate"]) for p in v[1]))
    for idx, (ent, ps) in enumerate(viagens, 1):
        saida = max(_d(p["collectedDate"]) for p in ps)
        ordem = sorted([p for p in ps if p.get("deliveryDate")], key=lambda p: _d(p["deliveryDate"]))
        fim = _d(ordem[-1]["deliveryDate"]) if ordem else None
        suspeita = any(p["_imediata"] or p["_retorno"] for p in ordem)
        dia = saida.strftime("%Y-%m-%d")

        hiato_antes = None
        if ultima_por_ent.get(ent) and ultima_por_ent[ent].date() == saida.date():
            hiato_antes = _min(ultima_por_ent[ent], saida)
            if hiato_antes > OCIOSO_MAX_MIN or hiato_antes < 0:
                hiato_antes = None
        ocioso_antes = None
        if ent in ultima_por_ent and ultima_por_ent[ent] and not ultima_suspeita.get(ent) \
                and ultima_por_ent[ent].date() == saida.date():
            ocioso_antes = _min(ultima_por_ent[ent], saida)
            if ocioso_antes is not None and ocioso_antes > OCIOSO_MAX_MIN:
                ocioso_antes = None
        ultima_por_ent[ent] = fim

        anterior = saida
        for pos, p in enumerate(ordem, 1):
            ent_dt = _d(p["deliveryDate"])
            t1 = _min(_d(p["date"]), _d(p.get("despatchDate")))
            t3 = _min(anterior, ent_dt)
            tot = _min(_d(p["date"]), ent_dt)
            km = km_rota(p)
            vel = round(km / (t3 / 60), 1) if (km and t3 and t3 > 0 and pos == 1) else None
            if p["_imediata"]:
                motivo = "baixa imediata"
            elif p["_retorno"]:
                motivo = "baixa no retorno"
            elif pos > 1 and t3 is not None and t3 < LOTE_MIN:
                motivo = "baixa em lote"
            elif vel is not None and vel > VEL_MAX_KMH:
                motivo = "rápido demais"
            elif t3 is not None and t3 > TRANSITO_MAX_MIN:
                motivo = "trânsito > 60 min"
            else:
                motivo = ""
            linhas_p.append({
                "pedido": p.get("id"), "entregador": ent, "viagem": idx, "posicao_na_viagem": pos,
                "pedidos_na_viagem": len(ps),
                "abertura": p["date"][11:19],
                "t1_ate_despacho_min": t1,
                "t2_espera_saida_min": _min(_d(p.get("despatchDate")), saida),
                "t3_transito_min": t3,
                "total_min": tot,
                "km_rota": km, "vel_kmh_1o_trecho": vel,
                "excluir_transito": motivo,
                "excluir_despacho": t1 is None or not (DESPACHO_MIN_MIN <= t1 <= DESPACHO_MAX_MIN),
                "excluir_total": tot is None or tot > TOTAL_MAX_MIN,
                "no_prazo": (ent_dt <= _d(p["deliveryDueDate"])) if p.get("deliveryDueDate") else None,
                "baixa_suspeita": "imediata" if p["_imediata"] else "retorno" if p["_retorno"] else "",
            })
            anterior = ent_dt

        linhas_v.append({
            "viagem": idx, "dia": dia, "entregador": ent, "pedidos": len(ps),
            "ids": ",".join(p.get("id", "") for p in ordem),
            "saida": saida.strftime("%H:%M:%S"), "fim": fim.strftime("%H:%M:%S") if fim else "",
            "tempo_rota_min": _min(saida, fim),
            "ocioso_antes_min": ocioso_antes,
            "hiato_antes_min": hiato_antes,
            "baixa_suspeita": suspeita,
        })
        ultima_suspeita[ent] = suspeita

    # ocioso/retorno fica atribuído à viagem anterior (depois dela)
    prox, prox_h = {}, {}
    for v in sorted(linhas_v, key=lambda v: v["viagem"], reverse=True):
        v["retorno_ocioso_depois_min"] = prox.get(v["entregador"])
        v["hiato_bruto_depois_min"] = prox_h.get(v["entregador"])
        prox[v["entregador"]] = v["ocioso_antes_min"]
        prox_h[v["entregador"]] = v["hiato_antes_min"]
    for v in linhas_v:
        v.pop("ocioso_antes_min")
        v.pop("hiato_antes_min")
    return linhas_p, linhas_v


def _m(vals):
    vals = [v for v in vals if v is not None]
    if not vals:
        return "–"
    return f"média {st.mean(vals):.1f} | mediana {st.median(vals):.1f} | n={len(vals)}"


def resumo(lp, lv):
    ok = [p for p in lp if not p["excluir_transito"]]
    vok = [v for v in lv if not v["baixa_suspeita"]]
    out = []
    out.append(f"Pedidos: {len(lp)} | Viagens: {len(lv)} | Baixas imediatas: "
               f"{sum(p['baixa_suspeita'] == 'imediata' for p in lp)} | Baixas no retorno: "
               f"{sum(p['baixa_suspeita'] == 'retorno' for p in lp)}")
    por_ent = defaultdict(lambda: [0, 0])
    for p in lp:
        por_ent[p["entregador"]][0] += 1
        por_ent[p["entregador"]][1] += bool(p["baixa_suspeita"])
    out.append("  Baixas suspeitas por entregador: " + ", ".join(
        f"{e}: {b}/{n}" for e, (n, b) in sorted(por_ent.items(), key=lambda x: -x[1][1])))
    exc = Counter(p["excluir_transito"] for p in lp if p["excluir_transito"])
    out.append(f"  Trânsito válido: {len(ok)}/{len(lp)} ({len(ok) / max(1, len(lp)):.0%}) | excluídos: {dict(exc)}")
    out.append(f"1 Até despacho (min):      {_m([p['t1_ate_despacho_min'] for p in lp if not p['excluir_despacho']])}")
    out.append(f"2 Espera p/ saída (min):   {_m([p['t2_espera_saida_min'] for p in lp])}")
    out.append(f"3 Trânsito/pedido (min):   {_m([p['t3_transito_min'] for p in ok])}  (sem baixas suspeitas)")
    out.append(f"4 Retorno/ocioso (min):    {_m([v['retorno_ocioso_depois_min'] for v in lv])}")
    out.append(f"  Tempo de rota/viagem:    {_m([v['tempo_rota_min'] for v in vok])}")
    out.append("5 Por nº de pedidos na viagem:")
    for n in sorted({v["pedidos"] for v in lv}):
        vs = [v for v in vok if v["pedidos"] == n]
        ps = [p for p in ok if p["pedidos_na_viagem"] == n]
        prazo = [p["no_prazo"] for p in ps if p["no_prazo"] is not None]
        out.append(f"   {n} pedido(s): {sum(1 for v in lv if v['pedidos'] == n)} viagens | "
                   f"rota/viagem {_m([v['tempo_rota_min'] for v in vs])} | "
                   f"total/pedido {_m([p['total_min'] for p in ps if not p['excluir_total']])} | "
                   f"no prazo {sum(prazo)}/{len(prazo)}")
    return "\n".join(out)


def produtividade(lp, lv):
    """Por entregador e dia: entregas, horas ativas (rota + hiatos <= OCIOSO_MAX_MIN), entregas/hora,
    % do tempo ativo em rota, trânsito médio válido e % de baixas suspeitas."""
    agg = defaultdict(lambda: {"entregas": 0, "rota_min": 0.0, "ocioso_min": 0.0, "transito": [], "suspeitas": 0, "no_prazo": []})
    for v in lv:
        a = agg[(v["dia"], v["entregador"])]
        if v["tempo_rota_min"]:
            a["rota_min"] += v["tempo_rota_min"]
        if v.get("hiato_bruto_depois_min"):  # horas ativas usam o tempo real, mesmo com baixa suspeita
            a["ocioso_min"] += v["hiato_bruto_depois_min"]
    dia_viagem = {v["viagem"]: v["dia"] for v in lv}
    for p in lp:
        a = agg[(dia_viagem[p["viagem"]], p["entregador"])]
        a["entregas"] += 1
        a["suspeitas"] += bool(p["baixa_suspeita"])
        if not p["excluir_transito"] and p["t3_transito_min"] is not None:
            a["transito"].append(p["t3_transito_min"])
        if p["no_prazo"] is not None:
            a["no_prazo"].append(p["no_prazo"])
    linhas = []
    for (dia, ent), a in sorted(agg.items()):
        ativo = a["rota_min"] + a["ocioso_min"]
        linhas.append({
            "dia": dia, "entregador": ent, "entregas": a["entregas"],
            "horas_ativas": round(ativo / 60, 2),
            "entregas_por_hora": round(a["entregas"] / (ativo / 60), 2) if ativo > 0 else None,
            "pct_tempo_em_rota": round(a["rota_min"] / ativo * 100, 1) if ativo > 0 else None,
            "transito_medio_min": round(st.mean(a["transito"]), 1) if a["transito"] else None,
            "pct_no_prazo": round(sum(a["no_prazo"]) / len(a["no_prazo"]) * 100, 1) if a["no_prazo"] else None,
            "pct_baixa_suspeita": round(a["suspeitas"] / a["entregas"] * 100, 1),
        })
    return linhas


def _csv(nome, linhas):
    if not linhas:
        return
    with open(nome, "w", newline="", encoding="utf-8-sig") as f:
        w = csv.DictWriter(f, fieldnames=list(linhas[0].keys()), delimiter=";")
        w.writeheader()
        w.writerows(linhas)


if __name__ == "__main__":
    arq = sys.argv[1] if len(sys.argv) > 1 else "pedidos_raw.json"
    pedidos = json.load(open(arq, encoding="utf-8"))
    lp, lv = calcular(pedidos)
    _csv("pedidos.csv", lp)
    _csv("viagens.csv", lv)
    _csv("produtividade.csv", produtividade(lp, lv))
    print(resumo(lp, lv))
