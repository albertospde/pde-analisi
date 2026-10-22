-- Movimenti Messaggerie in Parquet (22/10/2026)
--
-- msg_movimenti pesava 1,5 GB su 3,4 del database e cresce di ~1,4 GB l'anno. Da qui:
--   * ogni file importato (giornaliero o mensile) si salva anche come Parquet nel bucket privato
--     msg-parquet (movimenti/<file>.parquet), scritto da scripts/archivia_parquet.py (GitHub Actions
--     ogni mattina dopo l'importazione) con le RPC qui sotto tramite la edge function msg-import-automatico;
--   * msg_movimenti resta solo d'appoggio: serve alla chiusura notturna per calcolare i riepiloghi;
--     di notte msg_movimenti_alleggerisci toglie i movimenti dei file già in Parquet e chiusi da 20 giorni
--     (movimenti_in_db = false);
--   * i riepiloghi (titolo/editore/cliente per giorno e per mese) restano nel database;
--   * PDE Analisi legge i Parquet con DuckDB nel browser solo per i filtri che prima andavano sui movimenti
--     (clienti insieme a editore o titolo).
-- Un riepilogo per giorno non si può più ricalcolare da msg_movimenti per un giorno di un file archiviato:
-- _msg_ricalcola_riepiloghi lo rifiuta, e i cambi di editore ricalcolano solo msg_editore_giorno
-- (che dipende da msg_titolo_giorno, non dai movimenti).

insert into storage.buckets (id, name, public) values ('msg-parquet', 'msg-parquet', false) on conflict (id) do nothing;
drop policy if exists "msg-parquet select admin" on storage.objects;
create policy "msg-parquet select admin" on storage.objects for select to authenticated
  using (bucket_id = 'msg-parquet' and public._is_admin_pde());

alter table public.msg_importazioni
  add column if not exists data_min date,
  add column if not exists data_max date,
  add column if not exists parquet_percorso text,
  add column if not exists parquet_il timestamptz,
  add column if not exists movimenti_in_db boolean not null default true;

update public.msg_importazioni i set data_min = s.a, data_max = s.b
from (select file, min(data) a, max(data) b from public.msg_movimenti group by file) s
where s.file = i.file;

-- ── Importazione: periodo del file, e una reimportazione rimette il file "da archiviare" ──
create or replace function public.msg_import_inizia(p_file integer, p_nome_file text, p_data_file date, p_righe_file integer)
 returns void language plpgsql security definer set search_path to 'public'
as $function$
begin
  if not public._msg_import_autorizzato() then raise exception 'Operazione riservata agli amministratori PDE'; end if;
  delete from public.msg_movimenti where file = p_file;
  insert into public.msg_importazioni (file, nome_file, data_file, righe_file, importata_da)
  values (p_file, p_nome_file, p_data_file, p_righe_file, auth.uid())
  on conflict (file) do update set nome_file = excluded.nome_file, data_file = excluded.data_file,
    righe_file = excluded.righe_file, righe_caricate = null, stato = 'in corso',
    iniziata_il = now(), completata_il = null, importata_da = excluded.importata_da,
    data_min = null, data_max = null, parquet_il = null, movimenti_in_db = true;
end $function$;

create or replace function public.msg_import_da_chiudere(p_file integer)
 returns msg_importazioni language plpgsql security definer set search_path to 'public'
as $function$
declare r public.msg_importazioni;
begin
  if not public._msg_import_autorizzato() then raise exception 'Operazione riservata agli amministratori PDE'; end if;
  update public.msg_importazioni i set
    righe_caricate = s.righe, copie_fornite = s.cf, copie_rese = s.cr, netto_fornito = s.nf, netto_reso = s.nr,
    data_min = s.dmin, data_max = s.dmax, stato = 'da chiudere'
  from (
    select count(*) as righe,
      coalesce(sum(copie) filter (where movimento = 'F'), 0) as cf, coalesce(sum(copie) filter (where movimento = 'R'), 0) as cr,
      coalesce(sum(netto) filter (where movimento = 'F'), 0) as nf, coalesce(sum(netto) filter (where movimento = 'R'), 0) as nr,
      min(data) as dmin, max(data) as dmax
    from public.msg_movimenti where file = p_file
  ) s
  where i.file = p_file
  returning i.* into r;
  return r;
end $function$;

-- ── Riepiloghi: mai da movimenti che non ci sono più ──
create or replace function public._msg_ricalcola_editori_giorno(p_date date[])
 returns void language plpgsql security definer set search_path to 'public' set plan_cache_mode to 'force_custom_plan'
as $function$
begin
  if coalesce(cardinality(p_date), 0) = 0 then return; end if;
  delete from public.msg_editore_giorno where data = any(p_date);
  insert into public.msg_editore_giorno (data, editore, titoli, copie_f, copie_r, netto_f, netto_r, lordo_f, lordo_r)
  select g.data, t.editore, count(distinct g.ean), sum(g.copie_f), sum(g.copie_r), sum(g.netto_f), sum(g.netto_r), sum(g.lordo_f), sum(g.lordo_r)
  from public.msg_titolo_giorno g join public.msg_titoli t on t.ean = g.ean
  where g.data = any(p_date)
  group by g.data, t.editore;
end $function$;

create or replace function public._msg_ricalcola_riepiloghi(p_date date[], p_mesi boolean default true)
 returns void language plpgsql security definer set search_path to 'public' set plan_cache_mode to 'force_custom_plan'
as $function$
declare v_file text;
begin
  -- I movimenti dei file archiviati in Parquet non sono più qui: ricalcolare quei giorni li azzererebbe
  select string_agg(i.nome_file, ', ') into v_file from public.msg_importazioni i
  where not i.movimenti_in_db and exists (select 1 from unnest(p_date) d where d between i.data_min and i.data_max);
  if v_file is not null then
    raise exception 'Giorni già archiviati in Parquet (%): i riepiloghi di quei giorni non si ricalcolano dai movimenti', v_file;
  end if;

  delete from public.msg_titolo_giorno where data = any(p_date);
  insert into public.msg_titolo_giorno (data, ean, lancio, copie_f, copie_r, netto_f, netto_r, lordo_f, lordo_r)
  select data, ean, lancio,
    coalesce(sum(copie) filter (where movimento = 'F'), 0), coalesce(sum(copie) filter (where movimento = 'R'), 0),
    coalesce(sum(netto) filter (where movimento = 'F'), 0), coalesce(sum(netto) filter (where movimento = 'R'), 0),
    coalesce(sum(lordo) filter (where movimento = 'F'), 0), coalesce(sum(lordo) filter (where movimento = 'R'), 0)
  from public.msg_movimenti where data = any(p_date)
  group by data, ean, lancio;

  perform public._msg_ricalcola_editori_giorno(p_date);

  delete from public.msg_cliente_giorno where data = any(p_date);
  insert into public.msg_cliente_giorno (data, codice_cliente, tipo, copie_f, copie_r, netto_f, netto_r, lordo_f, lordo_r)
  select m.data, m.codice_cliente, public._msg_tipo(m.lancio, m.data, t.data_uscita),
    coalesce(sum(m.copie) filter (where m.movimento = 'F'), 0), coalesce(sum(m.copie) filter (where m.movimento = 'R'), 0),
    coalesce(sum(m.netto) filter (where m.movimento = 'F'), 0), coalesce(sum(m.netto) filter (where m.movimento = 'R'), 0),
    coalesce(sum(m.lordo) filter (where m.movimento = 'F'), 0), coalesce(sum(m.lordo) filter (where m.movimento = 'R'), 0)
  from public.msg_movimenti m join public.msg_titoli t on t.ean = m.ean
  where m.data = any(p_date)
  group by 1, 2, 3;

  if p_mesi then perform public._msg_ricalcola_mesi(p_date); end if;
end $function$;

create or replace function public._msg_import_chiudi(p_file integer, p_passo integer)
 returns jsonb language plpgsql security definer set search_path to 'public' set plan_cache_mode to 'force_custom_plan'
as $function$
declare v_date date[]; v_ean text[]; v_cambiati text[]; r public.msg_importazioni;
begin
  v_date := array(select distinct data from public.msg_movimenti where file = p_file);

  if p_passo = 1 then
    update public.msg_importazioni i set
      righe_caricate = s.righe, copie_fornite = s.cf, copie_rese = s.cr, netto_fornito = s.nf, netto_reso = s.nr,
      data_min = s.dmin, data_max = s.dmax
    from (
      select count(*) as righe,
        coalesce(sum(copie) filter (where movimento = 'F'), 0) as cf, coalesce(sum(copie) filter (where movimento = 'R'), 0) as cr,
        coalesce(sum(netto) filter (where movimento = 'F'), 0) as nf, coalesce(sum(netto) filter (where movimento = 'R'), 0) as nr,
        min(data) as dmin, max(data) as dmax
      from public.msg_movimenti where file = p_file
    ) s
    where i.file = p_file;
    perform public._msg_aggiorna_clienti();
    perform public._msg_aggiorna_uscite(p_file);
    return jsonb_build_object('passo', 2);

  elsif p_passo = 2 then
    v_ean := array(select distinct ean from public.msg_movimenti where file = p_file);
    v_cambiati := public._msg_calcola_editori(v_ean);
    perform public._msg_ricalcola_riepiloghi(v_date, false);
    -- Titoli che hanno cambiato editore: negli altri giorni cambia solo il riepilogo per editore
    perform public._msg_ricalcola_editori_giorno(array(
      select distinct g.data from public.msg_titolo_giorno g where g.ean = any(v_cambiati) and g.data <> all(v_date)));
    return jsonb_build_object('passo', 3, 'titoli_cambiati', coalesce(array_length(v_cambiati, 1), 0));

  elsif p_passo = 3 then
    perform public._msg_ricalcola_mesi(v_date);
    update public.msg_importazioni set stato = 'completata', completata_il = now() where file = p_file returning * into r;
    return jsonb_build_object('passo', null, 'importazione', to_jsonb(r));
  end if;
  raise exception 'Passo non valido: %', p_passo;
end $function$;

create or replace function public.msg_editori_settimanale()
 returns text language plpgsql security definer set search_path to 'public' set plan_cache_mode to 'force_custom_plan'
as $function$
declare v_cambiati text[]; v_date date[];
begin
  v_cambiati := public._msg_calcola_editori(null);
  v_date := array(select distinct g.data from public.msg_titolo_giorno g where g.ean = any(v_cambiati));
  -- Un cambio di editore tocca solo il riepilogo per editore (titoli, clienti e mesi non hanno l'editore)
  perform public._msg_ricalcola_editori_giorno(v_date);
  return format('%s titoli con editore cambiato, %s giorni ricalcolati', cardinality(v_cambiati), cardinality(v_date));
end $function$;

create or replace function public.msg_import_elimina(p_file integer)
 returns void language plpgsql security definer set search_path to 'public'
as $function$
declare v_date date[];
begin
  if not public._is_admin_pde() then raise exception 'Operazione riservata agli amministratori PDE'; end if;
  if exists (select 1 from public.msg_importazioni where file = p_file and not movimenti_in_db) then
    raise exception 'Il file è già archiviato in Parquet: per correggerlo reimportalo, i suoi giorni verranno sostituiti';
  end if;
  v_date := array(select distinct data from public.msg_movimenti where file = p_file);
  delete from public.msg_movimenti where file = p_file;
  delete from public.msg_importazioni where file = p_file;
  perform public._msg_ricalcola_riepiloghi(v_date);
end $function$;

-- ── Archiviazione (solo service role, tramite la edge function msg-import-automatico) ──
create or replace function public.msg_parquet_da_fare()
 returns table(file integer, nome_file text, date date[])
 language plpgsql stable security definer set search_path to 'public'
as $function$
begin
  if not public._msg_import_autorizzato() then raise exception 'Operazione riservata agli amministratori PDE'; end if;
  return query
  select i.file, i.nome_file, array(select distinct m.data from public.msg_movimenti m where m.file = i.file order by 1)
  from public.msg_importazioni i
  where i.stato in ('completata', 'da chiudere') and i.parquet_il is null and i.movimenti_in_db and i.righe_caricate is not null
  order by i.file;
end $function$;

-- Un giorno di un file in forma compatta: [ean, cliente, movimento, lancio, copie, lordo_cent, netto_cent]
create or replace function public.msg_movimenti_esporta(p_file integer, p_data date)
 returns json language plpgsql stable security definer set search_path to 'public'
as $function$
declare v json;
begin
  if not public._msg_import_autorizzato() then raise exception 'Operazione riservata agli amministratori PDE'; end if;
  select coalesce(json_agg(json_build_array(ean, codice_cliente, movimento, lancio, copie,
      round(lordo * 100)::bigint, round(netto * 100)::bigint)), '[]'::json) into v
  from public.msg_movimenti where file = p_file and data = p_data;
  return v;
end $function$;

-- Il Parquet vale solo se i suoi totali sono quelli dell'importazione
create or replace function public.msg_parquet_registra(p_file integer, p_percorso text, p_righe integer,
  p_copie_f bigint, p_copie_r bigint, p_netto_f_cent bigint, p_netto_r_cent bigint, p_data_min date, p_data_max date)
 returns text language plpgsql security definer set search_path to 'public'
as $function$
declare i public.msg_importazioni;
begin
  if not public._msg_import_autorizzato() then raise exception 'Operazione riservata agli amministratori PDE'; end if;
  select * into i from public.msg_importazioni where file = p_file for update;
  if i.file is null then raise exception 'Importazione % inesistente', p_file; end if;
  if i.righe_caricate is distinct from p_righe or i.copie_fornite is distinct from p_copie_f::int or i.copie_rese is distinct from p_copie_r::int
     or round(i.netto_fornito * 100)::bigint is distinct from p_netto_f_cent or round(i.netto_reso * 100)::bigint is distinct from p_netto_r_cent then
    raise exception 'Totali del Parquet di % diversi dall''importazione: righe % / %, copie F % / %, R % / %',
      i.nome_file, p_righe, i.righe_caricate, p_copie_f, i.copie_fornite, p_copie_r, i.copie_rese;
  end if;
  update public.msg_importazioni set parquet_percorso = p_percorso, parquet_il = now(),
    data_min = p_data_min, data_max = p_data_max where file = p_file;
  return 'ok';
end $function$;

-- Di notte: via da msg_movimenti i file già in Parquet, chiusi e più vecchi di p_giorni
-- (i giornalieri si sovrappongono di qualche giorno: finché un vicino non è chiuso si aspetta)
create or replace function public.msg_movimenti_alleggerisci(p_giorni integer default 20)
 returns text language plpgsql security definer set search_path to 'public'
as $function$
declare r record; n int := 0; v_righe bigint := 0; c bigint;
begin
  if not public._msg_import_autorizzato() then raise exception 'Operazione riservata agli amministratori PDE'; end if;
  for r in
    select i.file from public.msg_importazioni i
    where i.movimenti_in_db and i.parquet_il is not null and i.stato = 'completata'
      and i.data_max < current_date - p_giorni
      and not exists (select 1 from public.msg_importazioni j where j.file <> i.file and j.stato <> 'completata'
                      and (j.data_min is null or (j.data_min <= i.data_max and j.data_max >= i.data_min)))
    order by i.file
  loop
    delete from public.msg_movimenti where file = r.file;
    get diagnostics c = row_count;
    update public.msg_importazioni set movimenti_in_db = false where file = r.file;
    n := n + 1; v_righe := v_righe + c;
  end loop;
  return format('%s file archiviati, %s righe tolte da msg_movimenti', n, v_righe);
end $function$;

-- ── Per PDE Analisi (amministratori) ──
-- File in Parquet che coprono il periodo; percorso null = completato ma non ancora archiviato (dati incompleti)
create or replace function public.msg_parquet_file(p_dal date, p_al date)
 returns table(file integer, nome_file text, percorso text, parquet_il timestamptz, data_min date, data_max date)
 language plpgsql stable security definer set search_path to 'public'
as $function$
begin
  if not public._is_admin_pde() then return; end if;
  return query select i.file, i.nome_file, case when i.parquet_il is not null then i.parquet_percorso end, i.parquet_il, i.data_min, i.data_max
    from public.msg_importazioni i
    where i.stato = 'completata' and i.data_min <= p_al and i.data_max >= p_dal
    order by i.file;
end $function$;

-- Titoli per DuckDB: ean, editore, codice editore, data d'uscita (testo separato da tabulazioni)
create or replace function public.msg_parquet_titoli()
 returns text language plpgsql stable security definer set search_path to 'public'
as $function$
declare v text;
begin
  if not public._is_admin_pde() then return null; end if;
  select E'ean\teditore\tcodice_editore\tdata_uscita\n' || string_agg(
      t.ean || E'\t' || coalesce(translate(t.editore, E'\t\n\r', '   '), '') || E'\t' || coalesce(t.codice_editore, '')
      || E'\t' || coalesce(t.data_uscita::text, ''), E'\n')
    into v from public.msg_titoli t;
  return v;
end $function$;

revoke execute on function public.msg_parquet_da_fare(), public.msg_movimenti_esporta(integer, date),
  public.msg_parquet_registra(integer, text, integer, bigint, bigint, bigint, bigint, date, date),
  public.msg_movimenti_alleggerisci(integer), public._msg_ricalcola_editori_giorno(date[]) from public, anon;
