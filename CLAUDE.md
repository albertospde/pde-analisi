# PDE Analisi

App interna di PDE per analizzare i dati Messaggerie (file PPSVMAGG giornalieri e PPSVMAFR mensili):
fornito, reso e venduto per giorno, editore, titolo, cliente e canale. Rispondere sempre in italiano.

## Struttura

- `index.html`: tutta l'app (HTML, CSS, JS in un file), pubblicata su GitHub Pages (repo albertospde/pde-analisi).
  Accesso limitato da `UTENTI_AMMESSI`; la card in PDE Hub ha `data-solo-per` con gli stessi indirizzi.
- `scripts/importa-ppsvmagg.mjs`: import automatico dei giornalieri, lanciato dal workflow `.github/workflows/importa-ppsvmagg.yml`.
- `scripts/archivia_parquet.py`: archivia i movimenti in Parquet (bucket `msg-parquet`), passo del workflow del mattino.
- `scripts/importa_storico.py`: import dei mensili dal PC (`--leggi`, `--solo-movimenti`, `--uscite`, `--giornalieri`).
- `scripts/storico_serale.ps1`: un mese di storico per sera, lanciato dall'attività Windows "PDE Analisi - storico serale".
- `docs/tracciato-ppsvmagg.md`: tracciato a lunghezza fissa (813 caratteri) ricostruito a mano.
- `docs/sql/`: registro delle modifiche al database, una per file con data. Le lancia l'utente nell'editor SQL di Supabase.
- Edge function `msg-import-automatico` e `sftp-messaggerie`: sorgente in `GIRO MANAGER/supabase/functions`.

## Database (Supabase tdflwenlylhctxssatax)

- Database condiviso con PDE Hub, Giro Manager e BookUp: un lavoro pesante qui li rallenta tutti.
- Istanza MICRO (1 GB), Disk IO budget limitato: **mai lavori pesanti di giorno** (ricalcoli, chiusure di mesi, scansioni
  intere di `msg_movimenti`). Di giorno una chiusura ha bloccato tutto il DB per 40 minuti.
- Timeout: `authenticated` 8 s, `service_role` 120 s, job pg_cron 2 min di default (mettere `set statement_timeout` nel comando).
- Import: i movimenti si caricano, `msg_import_da_chiudere` mette il file 'da chiudere', la chiusura
  (`_msg_import_chiudi` passi 1-3) la fa pg_cron: `msg-import-chiudi` di notte, `msg-import-chiudi-mattino` per i giornalieri.
- Le RPC di import usano `_msg_import_autorizzato()`: chi le ricrea deve mantenerlo.
- Riepiloghi: `msg_titolo_giorno`, `msg_editore_giorno`, `msg_cliente_giorno`, `msg_titolo_mese`. I tipi in `msg_cliente_*`
  seguono la regola vecchia: per i tipi con filtro clienti si legge il Parquet (DuckDB-wasm nella pagina).

## Regole sui dati

- Prezzo di copertina alle posizioni 56-62. La 55 NON fa parte del prezzo.
- `leggiPpsvmagg` è duplicato in `index.html`, `importa-ppsvmagg.mjs` e `importa_storico.py`: tenerli uguali.
- Importi a prezzo di copertina (come Tableau). Venduto = Fornito − Reso. Contrasto (cod. 698) resta incluso.
- Novità = rifornimento nell'anno di uscita del titolo. Canale = `msg_clienti_gruppo.canale_gruppo`.
- Confronto con l'anno prima: stesse date di calendario (`datePrima`); con un anno intero o un intervallo dal/al,
  tutto il periodo dell'anno prima. Il confronto segue tutti i filtri.
- Sul reso le variazioni hanno i colori invertiti (un reso che cala è verde).

## Lavoro

- Il repo è pubblico: niente dati dei file Messaggerie, chiavi o nomi di clienti nei file versionati.
  I mensili stanno in `C:\Users\simolaa\storico mama filezilla`, fuori dal repo.
- La chiave dell'import (`MSG_IMPORT_CRON_KEY` = `app_secrets.msg_import_cron`) non va mai letta, stampata o messa nei comandi.
- Modificare `index.html` con Edit, non con `sed -i` (cambia i fine riga di tutto il file).
- Provare le modifiche alla pagina nel browser integrato prima di pubblicare. Commit e push solo dopo il "vai" dell'utente.
