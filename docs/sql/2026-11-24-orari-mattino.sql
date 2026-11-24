-- 2026-11-24 · Giornaliero disponibile prima al mattino (già applicato da Claude il 24/11, orari UTC)
--
-- Messaggerie pubblica PPSVMAGG verso le 6:00 italiane (5:40-6:10). Prima: scaricamento ogni 10 minuti e avvio
-- dell'importazione solo ai minuti 7/27/47 → dati in pagina verso le 6:35-6:45. Ora nella fascia 6:00-7:00 italiana
-- scaricamento e avvio ogni 5 minuti (l'avvio è leggero: senza file da importare risponde "niente da importare"
-- e non riparte se un import è in corso da meno di 25 minuti) → dati verso le 6:15-6:20.
-- La chiusura (msg-import-chiudi-mattino, ogni 5 minuti 6:00-11:55) resta com'era.

select cron.alter_job((select jobid from cron.job where jobname = 'sftp-messaggerie-download'), schedule := '*/5 4-6 * * *');
select cron.alter_job((select jobid from cron.job where jobname = 'msg-import-avvia'), schedule := '7,27,47 6-9 * * *');
select cron.schedule('msg-import-avvia-presto', '2-57/5 4-5 * * *', 'select public.msg_import_avvia()');
