-- Svuotamento iniziale di msg_movimenti e pulizia notturna (22/10/2026), dopo 2026-10-22-parquet.sql.
-- Da lanciare UNA volta nell'editor SQL di Supabase (progetto PDE HUB), preferibilmente prima delle 23:00
-- italiane, così la chiusura notturna dei giornalieri 293 e 294 lavora su una tabella piccola.
--
-- Tiene in msg_movimenti solo i file non ancora archiviabili (giornalieri degli ultimi 20 giorni o non chiusi),
-- toglie gli altri (già in Parquet nel bucket msg-parquet, totali verificati) con TRUNCATE: libera subito
-- lo spazio sul disco e scrive poco WAL, al contrario di un DELETE di 5,8 milioni di righe.

set statement_timeout = '20min';

begin;
create temp table _archiviare on commit drop as
select i.file from public.msg_importazioni i
where i.movimenti_in_db and i.parquet_il is not null and i.stato = 'completata' and i.data_max < current_date - 20
  and not exists (select 1 from public.msg_importazioni j where j.file <> i.file and j.stato <> 'completata'
                  and (j.data_min is null or (j.data_min <= i.data_max and j.data_max >= i.data_min)));
create temp table _tenere on commit drop as
  select * from public.msg_movimenti where file not in (select file from _archiviare);
truncate public.msg_movimenti;
insert into public.msg_movimenti select * from _tenere;
update public.msg_importazioni set movimenti_in_db = false where file in (select file from _archiviare);
commit;

analyze public.msg_movimenti;

-- Ogni notte alle 23:55 UTC (dopo le chiusure delle 21-23): toglie i file archiviati e chiusi da 20 giorni
select cron.schedule('msg-movimenti-alleggerisci', '55 23 * * *',
  $$set statement_timeout = '20min'; select public.msg_movimenti_alleggerisci(20)$$);

-- Controllo: righe rimaste (~0,3 milioni), peso della tabella e del database
select (select count(*) from public.msg_movimenti) righe_rimaste,
  (select count(*) from public.msg_importazioni where not movimenti_in_db) file_solo_in_parquet,
  pg_size_pretty(pg_total_relation_size('public.msg_movimenti')) peso_tabella,
  pg_size_pretty(pg_database_size(current_database())) database;
