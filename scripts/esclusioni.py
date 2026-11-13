"""Esclusioni dello storico in Parquet (docs/sql/2026-11-13-esclusioni.sql).

Per i file che hanno i movimenti solo in Parquet il database non può applicare da solo le regole di esclusione
(editori New Entry prima dell'ingresso, clienti Amazon per alcuni editori). Questo script:
  1. chiede al database le regole, già tradotte in EAN e codici cliente, e i file solo in Parquet con i totali
     delle esclusioni oggi applicate (edge function msg-import-automatico, azione "esclusioni-piano");
  2. per ogni file scarica il Parquet e trova le righe escluse dalle regole;
  3. se sono diverse da quelle applicate, le manda al database (azione "esclusioni-proponi", a blocchi).
Il database le applica di notte (pg_cron msg-esclusioni): di giorno qui si legge e si scrive poco.

Lo esegue GitHub Actions dopo l'importazione e l'archiviazione del mattino (.github/workflows/importa-ppsvmagg.yml);
si può lanciare anche dal PC. Variabile d'ambiente: MSG_IMPORT_CRON_KEY. Richiede pyarrow.
Nei messaggi solo conteggi (il log di GitHub è pubblico).

Uso:  py scripts/esclusioni.py             tutti i file solo in Parquet
      py scripts/esclusioni.py 202509 274  solo questi file
"""
import io
import os
import sys
import urllib.request

import pyarrow as pa
import pyarrow.compute as pc
import pyarrow.parquet as pq

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from importa_storico import job  # noqa: E402  (stessa chiamata alla edge function, con i tentativi)

BLOCCO = 5000


def righe_escluse(tab, ingressi, canali):
    """Righe del Parquet escluse dalle regole, come liste [data, ean, cliente, movimento, lancio, copie, netto_cent, lordo_cent]."""
    ean = tab.column("ean").to_pylist()
    data = tab.column("data").to_pylist()
    cliente = tab.column("codice_cliente").to_pylist()
    fuori = []
    for i in range(tab.num_rows):
        dal = ingressi.get(ean[i])
        if dal is not None and data[i].isoformat() < dal:
            fuori.append(i)
            continue
        for ean_c, clienti_c in canali:
            if ean[i] in ean_c and cliente[i] in clienti_c:
                fuori.append(i)
                break
    if not fuori:
        return []
    sel = tab.take(fuori).to_pylist()
    return [[r["data"].isoformat(), r["ean"], r["codice_cliente"], r["movimento"], bool(r["lancio"]),
             int(r["copie"]), int(r["netto_cent"]), int(r["lordo_cent"])] for r in sel]


def principale(solo):
    piano = job("esclusioni-piano")
    ingressi = {e: str(d) for e, d in piano["ingressi"]}
    canali = [(set(c["ean"] or []), set(c["clienti"] or [])) for c in piano["clienti"]]
    # Un Parquet si legge solo se contiene un EAN interessato dalle regole
    ean_regole = set(ingressi).union(*(e for e, _ in canali))
    file = [f for f in piano["file"] if not solo or f["file"] in solo]
    print(f"Regole: {len(ingressi)} titoli di editori nuovi, {sum(len(e) for e, _ in canali)} titoli con clienti esclusi · "
          f"{len(file)} file solo in Parquet", flush=True)
    cambiati = errori = 0
    for f in file:
        try:
            with urllib.request.urlopen(f["url"], timeout=300) as res:
                tab = pq.read_table(io.BytesIO(res.read()))
            tab = tab.filter(pc.is_in(tab.column("ean"), value_set=pa.array(sorted(ean_regole), pa.string())))
            righe = righe_escluse(tab, ingressi, canali)
            uguali = (len(righe) == f["righe"] and sum(r[5] for r in righe) == f["copie"]
                      and sum(r[7] for r in righe) == f["lordo_cent"])
            if uguali:
                print(f"{f['nome_file']}: {len(righe):,} righe escluse, già applicate", flush=True)
                continue
            for k in range(0, max(len(righe), 1), BLOCCO):
                job("esclusioni-proponi", file=f["file"], righe=righe[k:k + BLOCCO],
                    inizio=k == 0, fine=k + BLOCCO >= len(righe))
            cambiati += 1
            print(f"{f['nome_file']}: {len(righe):,} righe escluse (prima {f['righe']:,}): proposte, si applicano stanotte", flush=True)
        except Exception as e:  # un file andato male non ferma gli altri: si riprova al passaggio successivo
            errori += 1
            print(f"ERRORE {f['nome_file']}: {str(e)[:300]}", flush=True)
    if cambiati:
        job("registra", ok=True, messaggio=f"Esclusioni: {cambiati} file in Parquet da aggiornare stanotte")
    if errori:
        job("registra", ok=False, messaggio=f"Esclusioni: {errori} file in Parquet non controllati")
    print(f"Fine: {cambiati} file da aggiornare, {errori} con problemi")
    return 1 if errori else 0


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    if not os.environ.get("MSG_IMPORT_CRON_KEY"):
        sys.exit("Manca la variabile MSG_IMPORT_CRON_KEY")
    sys.exit(principale({int(x) for x in sys.argv[1:]}))
