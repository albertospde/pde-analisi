"""Importazione dello storico Messaggerie (file mensili PPSVMAFR) nel database di PDE Analisi.

I mensili hanno lo stesso tracciato dei giornalieri PPSVMAGG (docs/tracciato-ppsvmagg.md) ma pesano
300-450 MB: si scaricano a mano con FileZilla e si importano da qui, dal PC. Stessa lettura e stessa
somma per giorno × EAN × cliente × fornito/reso × lancio di leggiPpsvmagg (index.html, scripts/importa-ppsvmagg.mjs),
con in più:
  * più blocchi MA00..MA99 nello stesso file (i mensili 2025 hanno un blocco "PP" e uno "SV":
    editori diversi, nei giornalieri sono mescolati) e file senza testata (si contano solo le righe);
  * righe con un carattere scritto in UTF-8 invece che in Windows-1252 (814 byte invece di 813).
Ogni mese è un'importazione a sé con numero AAAAMM (es. 202501): reimportarlo sostituisce i dati.
Le anagrafiche (titoli, clienti) dello storico non sovrascrivono quelle già presenti, più recenti.

Uso:
  py scripts/importa_storico.py --leggi <file...>     solo lettura e totali, niente database
  py scripts/importa_storico.py <file...>             importa (variabile MSG_IMPORT_CRON_KEY)
  py scripts/importa_storico.py --solo-movimenti <file...>   carica e lascia il mese 'da chiudere': la chiusura
      di un mese intero (editori, riepiloghi) supera il timeout delle API, la fa di notte pg_cron msg-import-chiudi.
      Un mese per sera, e mai di giorno (il disco di Supabase ha un budget di I/O limitato)
  py scripts/importa_storico.py --uscite <uscita.csv> <file...>   solo la prima bolla di lancio (YBA3) di ogni
      EAN, per la data di uscita dei titoli lanciati prima dello storico caricato (tabella msg_uscite_storico)
  py scripts/importa_storico.py --giornalieri          reimporta i PPSVMAGG scaricati e non ancora importati
      (gli stessi del workflow GitHub), leggendoli con questo script
Nei messaggi solo conteggi e totali: i dati restano sul PC e nel database.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

FN_URL = "https://tdflwenlylhctxssatax.supabase.co/functions/v1/msg-import-automatico"
ANON_KEY = ("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRkZmx3ZW5seWxoY3R4c3NhdGF4Iiwi"
            "cm9sZSI6ImFub24iLCJpYXQiOjE3NzYzMzgyNzYsImV4cCI6MjA5MTkxNDI3Nn0.l35qEL7LOvyYuI1McQlVqj4vbyTqmlevcmqWbTGYi2Q")
LUNGHEZZA = 813
BLOCCO = 2000


def campo(r, a, b):
    return r[a - 1:b].strip()


def intero(r, a, b):
    s = campo(r, a, b)
    if not s.isdigit():
        raise ValueError(f"atteso un numero in posizione {a}-{b}, trovato {s!r}")
    return int(s)


def data8(s):
    return f"{s[:4]}-{s[4:6]}-{s[6:8]}"


def decodifica(grezza, n):
    r = grezza.decode("cp1252", errors="replace")
    if len(r) == LUNGHEZZA:
        return r
    try:
        r8 = grezza.decode("utf-8")
        if len(r8) == LUNGHEZZA:
            return r8
    except UnicodeDecodeError:
        pass
    raise ValueError(f"riga {n}: lunga {len(r)} caratteri invece di {LUNGHEZZA}")


def leggi(percorso):
    """Stessa logica di leggiPpsvmagg; restituisce movimenti aggregati, anagrafiche e totali (netto in centesimi)."""
    dichiarate, code, lette, utf8 = [], [], 0, 0
    mov, titoli, clienti, uscite, rifornimenti = {}, {}, {}, {}, {}
    tot = {"F": [0, 0], "R": [0, 0]}
    with open(percorso, "rb") as f:
        for n, grezza in enumerate(f, 1):
            grezza = grezza.rstrip(b"\r\n")
            if not grezza:
                continue
            r = decodifica(grezza, n)
            if len(grezza) != LUNGHEZZA:
                utf8 += 1
            tipo = r[:4]
            try:
                if tipo == "MA00":
                    dichiarate.append(intero(r, 28, 35))
                    continue
                if tipo == "MA99":
                    code.append(intero(r, 28, 35))
                    continue
                if tipo != "MAMA":
                    raise ValueError(f"tipo record sconosciuto {tipo!r}")
                lette += 1
                data = data8(campo(r, 19, 26))
                ean = campo(r, 276, 288)
                cliente = campo(r, 39, 46)
                m = "R" if campo(r, 266, 267)[:1] == "R" else "F"
                copie = intero(r, 47, 51)
                prezzo = intero(r, 56, 62)       # centesimi (la pos. 55 a volte vale 1 o 2 sui resi)
                netto = intero(r, 501, 515)      # centesimi
                # Bolla di lancio: causale di magazzino YBA3 (il resto è rifornimento)
                lancio = campo(r, 375, 378) == "YBA3"
                prime = uscite if lancio else rifornimenti
                if m == "F" and (ean not in prime or data < prime[ean]):
                    prime[ean] = data
                k = (data, ean, cliente, m, lancio)
                x = mov.get(k)
                if x is None:
                    x = mov[k] = [0, 0, 0]
                x[0] += copie
                x[1] += copie * prezzo
                x[2] += netto
                tot[m][0] += copie
                tot[m][1] += netto
                titoli[ean] = {"ean": ean, "titolo": campo(r, 311, 370), "codice_editore": campo(r, 259, 261).lstrip("0"),
                               "collana": campo(r, 289, 294), "prezzo_copertina": prezzo / 100}
                clienti[cliente] = {"codice_cliente": cliente, "ragione_sociale": campo(r, 113, 142), "indirizzo": campo(r, 143, 172),
                                    "cap": campo(r, 173, 177), "citta": campo(r, 178, 198), "provincia": campo(r, 199, 200),
                                    "partita_iva": campo(r, 201, 211)}
            except ValueError as e:
                raise ValueError(f"riga {n}: {e}") from None
    if dichiarate and (sum(dichiarate) != lette or code != dichiarate):
        raise ValueError(f"le testate dichiarano {sum(dichiarate)} righe (code {sum(code)}), lette {lette}")
    movimenti = [{"data": k[0], "ean": k[1], "codice_cliente": k[2], "movimento": k[3], "lancio": k[4],
                  "copie": v[0], "lordo": v[1] / 100, "netto": v[2] / 100} for k, v in mov.items()]
    date = sorted({k[0] for k in mov})
    return {"righe": lette, "testate": len(dichiarate), "utf8": utf8, "movimenti": movimenti,
            "titoli": list(titoli.values()), "clienti": list(clienti.values()), "tot": tot, "date": date, "uscite": uscite, "rifornimenti": rifornimenti}


def euro(c):
    return f"{c / 100:,.2f}".replace(",", "X").replace(".", ",").replace("X", ".")


def num(n):
    return f"{n:,}".replace(",", ".")


def riepilogo(nome, p):
    controllo = f"{p['testate']} blocchi con testata" if p["testate"] else "senza testata, righe non verificabili"
    return (f"{nome}: {num(p['righe'])} righe ({controllo}{'; ' + str(p['utf8']) + ' in UTF-8' if p['utf8'] else ''}) "
            f"→ {num(len(p['movimenti']))} movimenti, dal {p['date'][0]} al {p['date'][-1]} · "
            f"fornite {num(p['tot']['F'][0])} copie ({euro(p['tot']['F'][1])} €) · rese {num(p['tot']['R'][0])} copie ({euro(p['tot']['R'][1])} €) · "
            f"{num(len(p['titoli']))} titoli, {num(len(p['clienti']))} clienti")


def job(azione, **dati):
    corpo = json.dumps({"azione": azione, **dati}).encode()
    for tentativo in range(1, 4):
        req = urllib.request.Request(FN_URL, data=corpo, method="POST", headers={
            "Content-Type": "application/json", "Authorization": f"Bearer {ANON_KEY}",
            "x-cron-key": os.environ["MSG_IMPORT_CRON_KEY"]})
        try:
            with urllib.request.urlopen(req, timeout=180) as res:
                return json.loads(res.read() or b"{}")
        except urllib.error.HTTPError as e:
            msg = f"{azione}: {e.code} {e.read()[:300].decode(errors='replace')}"
            if tentativo == 3 or e.code not in (502, 503, 504, 546) and "timeout" not in msg.lower():
                raise RuntimeError(msg) from None
        except (urllib.error.URLError, TimeoutError) as e:
            if tentativo == 3:
                raise RuntimeError(f"{azione}: {e}") from None
        time.sleep(5 * tentativo)


def importa_giornalieri():
    """Come il workflow GitHub: file scaricati non ancora importati, dal più vecchio, uno per importazione."""
    import tempfile
    piano = job("piano")["file"]
    print(f"Da importare: {len(piano)} ({', '.join(f['nome_remoto'] for f in piano) or 'nessuno'})", flush=True)
    errori = 0
    for f in piano:
        t0 = time.time()
        try:
            with urllib.request.urlopen(f["url"], timeout=300) as res, tempfile.NamedTemporaryFile(delete=False) as tmp:
                tmp.write(res.read())
            p = leggi(tmp.name)
            os.unlink(tmp.name)
            data_file = p["date"][-1] if p["date"] else time.strftime("%Y-%m-%d")
            job("inizia", file=f["file"], nome_file=f["nome_remoto"], data_file=data_file, righe_file=p["righe"])
            for k in range(0, max(len(p["titoli"]), len(p["clienti"])), BLOCCO):
                job("anagrafiche", titoli=p["titoli"][k:k + BLOCCO], clienti=p["clienti"][k:k + BLOCCO])
            for k in range(0, len(p["movimenti"]), BLOCCO):
                job("movimenti", file=f["file"], righe=p["movimenti"][k:k + BLOCCO])
            db = job("completa", file=f["file"])
            uguali = (db["righe_caricate"] == len(p["movimenti"]) and db["copie_fornite"] == p["tot"]["F"][0]
                      and db["copie_rese"] == p["tot"]["R"][0] and round(db["netto_fornito"] * 100) == p["tot"]["F"][1]
                      and round(db["netto_reso"] * 100) == p["tot"]["R"][1])
            job("registra", ok=uguali, messaggio=f"Reimportato {f['nome_remoto']} con lanci e rifornimenti: {p['righe']} righe → {db['righe_caricate']} nel database"
                + ("" if uguali else " · ATTENZIONE: totali diversi dal file"))
            print(f"{'OK' if uguali else 'KO'} {f['nome_remoto']}: {p['righe']} righe → {db['righe_caricate']} ({round(time.time() - t0)} s)", flush=True)
            errori += not uguali
        except Exception as e:
            errori += 1
            print(f"ERRORE {f['nome_remoto']}: {str(e)[:300]}", flush=True)
    return errori


def mese_file(percorso):
    """AAAAMM della prima riga di dettaglio (per l'ordine di importazione)."""
    with open(percorso, "rb") as f:
        for r in f:
            if r.startswith(b"MAMA"):
                return r[18:24].decode()
    return ""


def importa(percorso):
    t0 = time.time()
    nome = os.path.basename(percorso)
    p = leggi(percorso)
    mesi = {d[:7] for d in p["date"]}
    if len(mesi) != 1:
        raise ValueError(f"il file copre più mesi: {sorted(mesi)}")
    numero = int(p["date"][0][:7].replace("-", ""))   # AAAAMM
    print(riepilogo(nome, p), flush=True)
    job("inizia", file=numero, nome_file=nome, data_file=p["date"][-1], righe_file=p["righe"])
    for k in range(0, max(len(p["titoli"]), len(p["clienti"])), BLOCCO):
        job("anagrafiche-storico", titoli=p["titoli"][k:k + BLOCCO], clienti=p["clienti"][k:k + BLOCCO])
    for k in range(0, len(p["movimenti"]), BLOCCO):
        job("movimenti", file=numero, righe=p["movimenti"][k:k + BLOCCO])
        print(f"  movimenti {num(min(k + BLOCCO, len(p['movimenti'])))} di {num(len(p['movimenti']))}", end="\r", flush=True)
    if SOLO_MOVIMENTI:
        # La chiusura (editori e riepiloghi) di un mese intero supera il timeout delle API: qui solo i totali
        # e lo stato 'da chiudere', poi la chiude di notte pg_cron msg-import-chiudi (un file per passaggio)
        # e il mattino dopo il workflow lo archivia in Parquet
        db = job("da-chiudere", file=numero)
        uguali = (db["righe_caricate"] == len(p["movimenti"]) and db["copie_fornite"] == p["tot"]["F"][0]
                  and db["copie_rese"] == p["tot"]["R"][0] and round(db["netto_fornito"] * 100) == p["tot"]["F"][1]
                  and round(db["netto_reso"] * 100) == p["tot"]["R"][1])
        job("registra", ok=uguali, messaggio=f"Caricato {nome} (storico {numero}): {p['righe']} righe del file → {db['righe_caricate']} nel database, "
            + ("totali uguali al file, si chiude stanotte" if uguali else "ATTENZIONE: totali diversi dal file"))
        print(f"\n  {'OK' if uguali else 'KO'} {nome}: totali {'uguali al file' if uguali else 'DIVERSI dal file'}, "
              f"'da chiudere' ({round(time.time() - t0)} s)", flush=True)
        return uguali
    db = job("completa", file=numero)
    uguali = (db["righe_caricate"] == len(p["movimenti"]) and db["copie_fornite"] == p["tot"]["F"][0]
              and db["copie_rese"] == p["tot"]["R"][0] and round(db["netto_fornito"] * 100) == p["tot"]["F"][1]
              and round(db["netto_reso"] * 100) == p["tot"]["R"][1])
    testo = (f"{nome} (storico {numero}): {p['righe']} righe del file → {db['righe_caricate']} nel database · fornite {db['copie_fornite']} copie "
             f"({db['netto_fornito']:.2f} €) · rese {db['copie_rese']} copie ({db['netto_reso']:.2f} €)"
             + ("" if uguali else " · ATTENZIONE: totali diversi dal file"))
    job("registra", ok=uguali, messaggio=f"Importato {testo}")
    print(f"\n  {'OK' if uguali else 'KO'} totali {'uguali al file' if uguali else 'DIVERSI dal file'} ({round(time.time() - t0)} s)", flush=True)
    return uguali


SOLO_MOVIMENTI = "--solo-movimenti" in sys.argv
if SOLO_MOVIMENTI:
    sys.argv.remove("--solo-movimenti")

if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")   # la console di Windows non stampa "→"
    if len(sys.argv) > 2 and sys.argv[1] == "--leggi":
        for f in sys.argv[2:]:
            print(riepilogo(os.path.basename(f), leggi(f)), flush=True)
        sys.exit(0)
    if len(sys.argv) > 3 and sys.argv[1] == "--uscite":
        # Vale come uscita solo una bolla di lancio che precede ogni rifornimento del titolo: le bolle
        # "di lancio" di titoli già in commercio (es. campagne sul catalogo) non lo rendono una novità
        uscite, rifornimenti = {}, {}
        for f in sys.argv[3:]:
            p = leggi(f)
            for prime, nuove in ((uscite, p["uscite"]), (rifornimenti, p["rifornimenti"])):
                for ean, d in nuove.items():
                    if ean not in prime or d < prime[ean]:
                        prime[ean] = d
            print(f"{os.path.basename(f)}: {num(len(uscite))} EAN con bolla di lancio finora", flush=True)
        uscite = {e: d for e, d in uscite.items() if e not in rifornimenti or d <= rifornimenti[e]}
        print(f"Uscite valide (lancio prima di ogni rifornimento): {num(len(uscite))}", flush=True)
        with open(sys.argv[2], "w", encoding="utf-8") as out:
            out.write("\n".join(f"{e},{d}" for e, d in sorted(uscite.items())))
        sys.exit(0)
    if not os.environ.get("MSG_IMPORT_CRON_KEY"):
        sys.exit("Manca la variabile MSG_IMPORT_CRON_KEY")
    if len(sys.argv) == 2 and sys.argv[1] == "--giornalieri":
        sys.exit(1 if importa_giornalieri() else 0)
    # Windows: niente sospensione finché lo script lavora; alla fine del processo torna tutto normale
    if os.name == "nt":
        import ctypes
        ctypes.windll.kernel32.SetThreadExecutionState(0x80000000 | 0x00000001)   # ES_CONTINUOUS | ES_SYSTEM_REQUIRED
    errori = 0
    # Dal mese più recente al più vecchio: le anagrafiche dello storico non sovrascrivono, vince il dato più nuovo
    for f in sorted(sys.argv[1:], key=mese_file, reverse=True):
        try:
            if not importa(f):
                errori += 1
        except Exception as e:  # un mese andato male non ferma gli altri
            errori += 1
            print(f"\n  ERRORE {os.path.basename(f)}: {str(e)[:300]}", flush=True)
            try:
                job("registra", ok=False, messaggio=f"Importazione storico di {os.path.basename(f)} non riuscita: {e}")
            except Exception:
                pass
    print(f"Fine: {len(sys.argv) - 1 - errori} importati, {errori} con problemi")
    sys.exit(1 if errori else 0)
