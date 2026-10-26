-- Compattazione di msg_titolo_giorno prima di caricare lo storico gen-ago 2025.
-- Al 26/10/2026: tabella 171 MB, indici 727 MB (pkey 139 + (ean,data) 135 + data INCLUDE 453).
-- L'indice coperto su data duplica la chiave primaria (data, ean, lancio): diventa la chiave primaria
-- stessa con INCLUDE dei totali, così le letture per periodo restano index-only con un indice in meno.
-- ON CONFLICT (data, ean, lancio) dei ricalcoli continua a funzionare (le colonne chiave sono le stesse).
-- Atteso: indici da ~727 MB a ~300 MB. Blocca la tabella durante la ricostruzione (alcuni minuti):
-- lanciarlo DI SERA, prima delle 22, quando nessuno usa Analisi e prima della chiusura notturna.

-- 1) Eseguire da solo nell'editor SQL
set statement_timeout = '30min';
create unique index msg_titolo_giorno_chiave on public.msg_titolo_giorno (data, ean, lancio)
  include (copie_f, copie_r, netto_f, netto_r, lordo_f, lordo_r);
alter table public.msg_titolo_giorno
  drop constraint msg_titolo_giorno_pkey,
  add constraint msg_titolo_giorno_pkey primary key using index msg_titolo_giorno_chiave;
drop index public.msg_titolo_giorno_data_coperto_idx;
reindex index public.msg_titolo_giorno_ean_idx;

-- 2) Poi, in una seconda esecuzione separata (VACUUM non può stare in una transazione)
-- vacuum analyze public.msg_titolo_giorno;

-- 3) Controllo
-- select indexrelid::regclass, pg_size_pretty(pg_relation_size(indexrelid))
--   from pg_index where indrelid = 'public.msg_titolo_giorno'::regclass;
