"""Archiviazione dei movimenti Messaggerie in Parquet (docs/sql/2026-10-22-parquet.sql).

Per ogni file importato non ancora archiviato (giornaliero PPSVMAGG o mensile dello storico):
  1. legge i suoi movimenti dal database, un giorno per chiamata (edge function msg-import-automatico,
     azione "esporta"): sono gli stessi già controllati con i totali del file all'importazione;
  2. li scrive in un Parquet (zstd, ordinato per EAN e giorno: un mese pesa ~2 MB invece di ~110 MB nel database);
  3. lo carica nel bucket privato msg-parquet come movimenti/<file>.parquet (sostituisce quello vecchio);
  4. lo registra con i suoi totali: il database li confronta con quelli dell'importazione e, se diversi, rifiuta.
Dopo, di notte, msg_movimenti_alleggerisci toglie da msg_movimenti i file archiviati e chiusi da 20 giorni.

Lo esegue GitHub Actions dopo l'importazione del mattino (.github/workflows/importa-ppsvmagg.yml);
si può lanciare anche dal PC. Variabile d'ambiente: MSG_IMPORT_CRON_KEY. Richiede pyarrow.
Nei messaggi solo conteggi di righe (il log di GitHub è pubblico).

Uso:  py scripts/archivia_parquet.py            archivia tutto ciò che manca
      py scripts/archivia_parquet.py 202509 293  solo questi file
"""
import io
import os
import sys
import time
import urllib.request

import pyarrow as pa
import pyarrow.parquet as pq

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from importa_storico import job  # noqa: E402  (stessa chiamata alla edge function, con i tentativi)

SCHEMA = pa.schema([
    ("data", pa.date32()), ("ean", pa.string()), ("codice_cliente", pa.string()), ("movimento", pa.string()),
    ("lancio", pa.bool_()), ("copie", pa.int32()), ("lordo_cent", pa.int64()), ("netto_cent", pa.int64()),
])


def archivia(f):
    t0 = time.time()
    righe = []
    for d in f["date"]:
        for r in job("esporta", file=f["file"], data=d)["righe"]:
            righe.append((d, *r))
    righe.sort(key=lambda r: (r[1], r[0], r[2]))   # EAN, giorno, cliente: comprime meglio e filtra per titolo
    col = list(zip(*righe)) if righe else [[] for _ in SCHEMA]
    tab = pa.table([
        pa.array(col[0], pa.string()).cast(pa.date32()), pa.array(col[1], pa.string()), pa.array(col[2], pa.string()),
        pa.array(col[3], pa.string()), pa.array(col[4], pa.bool_()), pa.array(col[5], pa.int32()),
        pa.array(col[6], pa.int64()), pa.array(col[7], pa.int64()),
    ], schema=SCHEMA)
    buf = io.BytesIO()
    pq.write_table(tab, buf, compression="zstd", compression_level=9, row_group_size=200_000)
    dati = buf.getvalue()

    percorso = f"movimenti/{f['file']}.parquet"
    url = job("parquet-url", percorso=percorso)["url"]
    req = urllib.request.Request(url, data=dati, method="PUT", headers={"Content-Type": "application/octet-stream", "x-upsert": "true"})
    with urllib.request.urlopen(req, timeout=300) as res:
        res.read()

    tot = {"F": [0, 0], "R": [0, 0]}
    for r in righe:
        tot[r[3]][0] += r[5]
        tot[r[3]][1] += r[7]
    job("parquet-registra", file=f["file"], percorso=percorso, righe=len(righe),
        copie_f=tot["F"][0], copie_r=tot["R"][0], netto_f_cent=tot["F"][1], netto_r_cent=tot["R"][1],
        data_min=f["date"][0] if f["date"] else None, data_max=f["date"][-1] if f["date"] else None)
    print(f"OK {f['nome_file']}: {len(righe):,} righe → {len(dati) / 1e6:.1f} MB ({round(time.time() - t0)} s)", flush=True)


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    if not os.environ.get("MSG_IMPORT_CRON_KEY"):
        sys.exit("Manca la variabile MSG_IMPORT_CRON_KEY")
    piano = job("parquet-piano")["file"]
    solo = {int(x) for x in sys.argv[1:]}
    if solo:
        piano = [f for f in piano if f["file"] in solo]
    print(f"Da archiviare: {len(piano)} ({', '.join(f['nome_file'] for f in piano) or 'nessuno'})", flush=True)
    errori = 0
    for f in piano:
        try:
            archivia(f)
        except Exception as e:  # un file andato male non ferma gli altri: si riprova al passaggio successivo
            errori += 1
            print(f"ERRORE {f['nome_file']}: {str(e)[:300]}", flush=True)
            try:
                job("registra", ok=False, messaggio=f"Archiviazione in Parquet di {f['nome_file']} non riuscita: {e}")
            except Exception:
                pass
    print(f"Fine: {len(piano) - errori} archiviati, {errori} con problemi")
    sys.exit(1 if errori else 0)
