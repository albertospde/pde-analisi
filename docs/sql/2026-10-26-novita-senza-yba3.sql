-- Rifornimento novità di titoli mai passati da una bolla di lancio (causale YBA3).
-- "Senza YBA3" = nessuna bolla di lancio nei dati caricati (msg_titoli.primo_lancio) né nello storico 2025
-- (msg_uscite_storico): la data di uscita che li rende novità viene da Giro Manager (titoli_novita).
-- Una riga per titolo, stesse colonne di msg_analisi_titoli: la pagina somma per la riga "di cui senza YBA3"
-- di Lanci e rifornimenti e mostra l'elenco nella classifica Titoli. Con il filtro clienti la pagina
-- calcola dai Parquet (DuckDB) con l'elenco degli EAN di msg_parquet_senza_yba3().

create or replace function public.msg_analisi_novita_senza_yba3(p_date date[], p_editori text[] default null,
  p_ean text default null, p_clienti text[] default null)
returns table(ean text, titolo text, editore text, collana text, prezzo numeric, copie_f bigint, copie_r bigint,
  netto_f numeric, netto_r numeric, lordo_f numeric, lordo_r numeric)
language plpgsql stable security definer
set search_path to 'public' set plan_cache_mode to 'force_custom_plan'
as $function$
#variable_conflict use_column
declare v_mesi date[]; v_giorni date[];
begin
  if not public._is_admin_pde() or p_clienti is not null then return; end if;
  select d.mesi, d.giorni into v_mesi, v_giorni from public._msg_dividi_date(p_date) d;
  return query
  with s as (
    select t.ean e, t.titolo ti, t.editore ed, t.collana co, t.prezzo_copertina pr, t.data_uscita du
    from public.msg_titoli t
    where t.primo_lancio is null and t.data_uscita is not null
      and not exists (select 1 from public.msg_uscite_storico u where u.ean = t.ean)
      and (p_editori is null or t.editore = any(p_editori)) and (p_ean is null or t.ean = p_ean)
  ), y as (
    select g.ean e, g.copie_f cf, g.copie_r cr, g.netto_f nf, g.netto_r nr, g.lordo_f lf, g.lordo_r lr
    from public.msg_titolo_mese g join s on s.e = g.ean
    where g.mese = any(v_mesi) and g.tipo = 'novita'
    union all
    select g.ean, g.copie_f, g.copie_r, g.netto_f, g.netto_r, g.lordo_f, g.lordo_r
    from public.msg_titolo_giorno g join s on s.e = g.ean
    where g.data = any(v_giorni) and not g.lancio and g.data < s.du + interval '6 months'
  )
  select s.e, s.ti, s.ed, s.co, s.pr, sum(y.cf)::bigint, sum(y.cr)::bigint, sum(y.nf), sum(y.nr), sum(y.lf), sum(y.lr)
  from y join s on s.e = y.e
  group by s.e, s.ti, s.ed, s.co, s.pr;
end $function$;

-- EAN senza YBA3 con data di uscita, per i calcoli sui Parquet nella pagina
create or replace function public.msg_parquet_senza_yba3()
returns text[]
language sql stable security definer
set search_path to 'public'
as $function$
  select case when public._is_admin_pde() then array(
    select t.ean from public.msg_titoli t
    where t.primo_lancio is null and t.data_uscita is not null
      and not exists (select 1 from public.msg_uscite_storico u where u.ean = t.ean)) end
$function$;
