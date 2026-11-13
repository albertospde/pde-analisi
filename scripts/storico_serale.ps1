# Carico serale dello storico 2025: un mese per sera, dal piu recente al piu vecchio.
# Lo lancia l'Utilità di pianificazione (attività "PDE Analisi - storico serale") alle 20:30.
# Carica solo i movimenti: la chiusura del mese la fa di notte pg_cron (msg-import-chiudi, 22-01 ora italiana).
# I mesi caricati finiscono in storico_fatti.txt; quando sono finiti tutti, l'attività non fa piu niente.
$ErrorActionPreference = 'Continue'
$cartella = 'C:\Users\simolaa\storico mama filezilla'
$qui = Split-Path -Parent $MyInvocation.MyCommand.Path
$fatti = Join-Path $qui 'storico_fatti.txt'
$log = Join-Path $qui 'storico_log.txt'
$mesi = '202508', '202507', '202506', '202505', '202504', '202503', '202502', '202501'

function Scrivi($testo) { Add-Content -Path $log -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm') $testo" -Encoding utf8 }

# La chiave salvata con setx: letta dal registro, cosi non serve riavviare niente
$env:MSG_IMPORT_CRON_KEY = [Environment]::GetEnvironmentVariable('MSG_IMPORT_CRON_KEY', 'User')
if (-not $env:MSG_IMPORT_CRON_KEY) { Scrivi 'Manca la chiave MSG_IMPORT_CRON_KEY (setx), nessun carico'; exit 1 }

$giaFatti = if (Test-Path $fatti) { Get-Content $fatti } else { @() }
$mese = $mesi | Where-Object { $_ -notin $giaFatti } | Select-Object -First 1
if (-not $mese) { Scrivi 'Storico 2025 completo, niente da fare'; exit 0 }

$file = Join-Path $cartella "PPSVMAFR_$mese.txt"
Scrivi "Inizio $mese"
$uscita = & py (Join-Path $qui 'importa_storico.py') --solo-movimenti $file 2>&1
$codice = $LASTEXITCODE
$uscita | ForEach-Object { Scrivi "  $_" }
if ($codice -eq 0) { Add-Content -Path $fatti -Value $mese -Encoding utf8; Scrivi "Fine ${mese}: caricato, la chiusura stanotte" }
else { Scrivi "Fine ${mese}: ERRORE (codice $codice), si riprova domani sera" }
exit $codice
