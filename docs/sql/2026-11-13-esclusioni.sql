-- 2026-11-13 · Esclusioni dai dati di PDE Analisi (richiesta dell'utente del 13/11)
--
-- Regole:
--  1. Editori nuovi: un editore nella lista New Entry di Giro Manager (editori_new_entry) entra dal 1° gennaio
--     dell'anno dopo l'inserimento (o dalla data di ingresso, se compilata). Tutti i suoi dati PRIMA di quella
--     data sono esclusi, anche dopo che l'editore è entrato e anche se lo si toglie dalla lista: la regola resta
--     in msg_editori_ingresso, che si alimenta da sola e non perde nulla. Vale per ogni anno.
--  2. Cliente per editore: per EDIZIONI AMRITA, ARKEIOS, HERMES, MEDITERRANEE, STUDIO TESI sono esclusi i clienti
--     del canale Amazon (msg_clienti_gruppo.canale = 'Amazon', 8 codici oggi; i nuovi codici Amazon entrano da soli).
--
-- Come funziona:
--  * I movimenti e i Parquet restano grezzi (sono il controllo con i file Messaggerie). Le righe escluse stanno
--    in msg_esclusi (stessa chiave di msg_movimenti) e i riepiloghi valgono sempre "movimenti − esclusi".
--  * Alla chiusura di un file (passo 2) le esclusioni del file si calcolano dalle regole e i riepiloghi le tolgono.
--  * Di notte (pg_cron msg-esclusioni, 1-5 italiane, UN file per giro) msg_esclusioni_notte riallinea i file già
--    chiusi quando qualcosa cambia (nuovo editore in New Entry, titolo che cambia editore, nuovo codice Amazon):
--      - file con i movimenti nel database: controllo dalle regole, una volta per notte;
--      - file solo in Parquet: le righe escluse le calcola scripts/esclusioni.py (workflow del mattino o PC)
--        e le lascia in msg_esclusi_proposti; la notte le applica.
--    L'applicazione corregge msg_titolo_giorno e msg_cliente_giorno con la differenza e ricalcola editori del
--    giorno e mesi dei soli giorni toccati.
--  * La pagina, quando legge i Parquet con DuckDB, applica le stesse regole (msg_esclusioni_regole).
--
-- Si lancia di giorno: crea solo tabelle e funzioni. Il lavoro vero parte di notte.

-- ── Regole ────────────────────────────────────────────────────────────────────────────────────────────────
create table if not exists public.msg_editori_ingresso (
  editore text primary key,
  dal date not null,
  codice_editore text,
  fonte text not null default 'Giro Manager › New Entry',
  creato_il timestamptz not null default now()
);
create table if not exists public.msg_esclusioni_cliente (
  editore text not null,
  canale text not null,
  creato_il timestamptz not null default now(),
  primary key (editore, canale)
);
insert into public.msg_esclusioni_cliente (editore, canale) values
  ('EDIZIONI AMRITA', 'Amazon'), ('EDIZIONI ARKEIOS', 'Amazon'), ('EDIZIONI HERMES', 'Amazon'),
  ('EDIZIONI MEDITERRANEE', 'Amazon'), ('EDIZIONI STUDIO TESI', 'Amazon')
on conflict do nothing;

-- Righe escluse applicate ai riepiloghi, proposte in arrivo dallo script, lavoro della notte
create table if not exists public.msg_esclusi (
  file integer not null, data date not null, ean text not null, codice_cliente text not null,
  movimento character(1) not null, lancio boolean not null,
  copie integer not null, netto numeric not null, lordo numeric not null,
  primary key (file, data, ean, codice_cliente, movimento, lancio)
);
create table if not exists public.msg_esclusi_proposti (like public.msg_esclusi including all);
create table if not exists public.msg_esclusi_delta (like public.msg_esclusi including all);
create table if not exists public.msg_esclusi_proposte (
  file integer primary key, pronta boolean not null default false, righe integer, ricevuta_il timestamptz not null default now()
);
create table if not exists public.msg_esclusi_verifiche (file integer primary key, verificato_il timestamptz not null);

alter table public.msg_editori_ingresso enable row level security;
alter table public.msg_esclusioni_cliente enable row level security;
alter table public.msg_esclusi enable row level security;
alter table public.msg_esclusi_proposti enable row level security;
alter table public.msg_esclusi_delta enable row level security;
alter table public.msg_esclusi_proposte enable row level security;
alter table public.msg_esclusi_verifiche enable row level security;
drop policy if exists admin_legge on public.msg_editori_ingresso;
create policy admin_legge on public.msg_editori_ingresso for select to authenticated using (public._is_admin_pde());
drop policy if exists admin_legge on public.msg_esclusioni_cliente;
create policy admin_legge on public.msg_esclusioni_cliente for select to authenticated using (public._is_admin_pde());

-- Editori della lista New Entry → msg_editori_ingresso (solo aggiunte: chi c'è resta)
create or replace function public._msg_sincronizza_ingressi()
 returns integer
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare n integer;
begin
  insert into public.msg_editori_ingresso (editore, dal, codice_editore)
  select distinct on (x.nome) x.nome,
    coalesce(e.data_ingresso_rpn, make_date(extract(year from e.created_at)::int + 1, 1, 1)), e.codice_editore
  from public.editori_new_entry e
  cross join lateral (
    select e.nome_editore as nome
    union
    select r.editore_nome from public.ranking_editori r
    where coalesce(e.codice_editore, '') <> '' and ltrim(r.codice_editore, '0') = ltrim(e.codice_editore, '0')
  ) x
  where e.attivo and coalesce(trim(x.nome), '') <> ''
  order by x.nome, e.created_at
  on conflict (editore) do nothing;
  get diagnostics n = row_count;
  return n;
end $function$;

-- Righe di un file escluse dalle regole (dai movimenti nel database)
create or replace function public._msg_esclusi_calcola(p_file integer)
 returns table(data date, ean text, codice_cliente text, movimento character, lancio boolean, copie integer, netto numeric, lordo numeric)
 language sql
 stable
 security definer
 set search_path to 'public'
as $function$
  select m.data, m.ean, m.codice_cliente, m.movimento, m.lancio, m.copie, m.netto, m.lordo
  from public.msg_movimenti m
  join public.msg_titoli t on t.ean = m.ean
  where m.file = p_file
    and (exists (select 1 from public.msg_editori_ingresso i where i.editore = t.editore and m.data < i.dal)
      or exists (select 1 from public.msg_esclusioni_cliente x join public.msg_clienti_gruppo c on c.canale = x.canale
                 where x.editore = t.editore and c.codice_cliente = m.codice_cliente));
$function$;

-- Regole in forma semplice, per la pagina (DuckDB sui Parquet)
create or replace function public.msg_esclusioni_regole()
 returns jsonb
 language plpgsql
 stable
 security definer
 set search_path to 'public'
as $function$
begin
  if not public._is_admin_pde() then return null; end if;
  return jsonb_build_object(
    'ingressi', coalesce((select jsonb_agg(jsonb_build_object('editore', editore, 'dal', dal) order by editore) from public.msg_editori_ingresso), '[]'),
    'clienti', coalesce((select jsonb_agg(jsonb_build_object('editore', x.editore, 'codice_cliente', c.codice_cliente) order by x.editore, c.codice_cliente)
      from public.msg_esclusioni_cliente x join public.msg_clienti_gruppo c on c.canale = x.canale), '[]'));
end $function$;

-- ── Per lo script (edge function msg-import-automatico, service role) ────────────────────────────────────
-- Regole per EAN e file solo in Parquet con i totali delle esclusioni già applicate
create or replace function public.msg_esclusioni_piano()
 returns jsonb
 language plpgsql
 stable
 security definer
 set search_path to 'public'
as $function$
begin
  if not public._msg_import_autorizzato() then raise exception 'Operazione riservata agli amministratori PDE'; end if;
  return jsonb_build_object(
    'ingressi', coalesce((select jsonb_agg(jsonb_build_array(t.ean, i.dal)) from public.msg_titoli t
      join public.msg_editori_ingresso i on i.editore = t.editore), '[]'),
    'clienti', coalesce((select jsonb_agg(jsonb_build_object('canale', x.canale,
        'ean', (select jsonb_agg(t.ean) from public.msg_titoli t join public.msg_esclusioni_cliente y on y.editore = t.editore where y.canale = x.canale),
        'clienti', (select jsonb_agg(c.codice_cliente) from public.msg_clienti_gruppo c where c.canale = x.canale)))
      from (select distinct canale from public.msg_esclusioni_cliente) x), '[]'),
    'file', coalesce((select jsonb_agg(jsonb_build_object('file', i.file, 'nome_file', i.nome_file, 'percorso', i.parquet_percorso,
        'righe', coalesce(s.righe, 0), 'copie', coalesce(s.copie, 0), 'lordo_cent', coalesce(s.lordo_cent, 0)) order by i.file)
      from public.msg_importazioni i
      left join (select e.file, count(*) righe, sum(e.copie) copie, sum(round(e.lordo * 100))::bigint lordo_cent
                 from public.msg_esclusi e group by e.file) s on s.file = i.file
      where i.stato = 'completata' and not i.movimenti_in_db and i.parquet_il is not null), '[]'));
end $function$;

-- Righe escluse di un file in Parquet, a blocchi: [[data, ean, cliente, movimento, lancio, copie, netto_cent, lordo_cent], …]
create or replace function public.msg_esclusi_proponi(p_file integer, p_righe jsonb, p_inizio boolean, p_fine boolean)
 returns integer
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare n integer;
begin
  if not public._msg_import_autorizzato() then raise exception 'Operazione riservata agli amministratori PDE'; end if;
  if not exists (select 1 from public.msg_importazioni where file = p_file and stato = 'completata') then
    raise exception 'File % non trovato o non chiuso', p_file;
  end if;
  if p_inizio then
    delete from public.msg_esclusi_proposti where file = p_file;
    delete from public.msg_esclusi_proposte where file = p_file;
  end if;
  insert into public.msg_esclusi_proposti (file, data, ean, codice_cliente, movimento, lancio, copie, netto, lordo)
  select p_file, (r->>0)::date, r->>1, r->>2, r->>3, (r->>4)::boolean, (r->>5)::int, (r->>6)::bigint / 100.0, (r->>7)::bigint / 100.0
  from jsonb_array_elements(coalesce(p_righe, '[]')) r
  on conflict do nothing;
  get diagnostics n = row_count;
  if p_fine then
    insert into public.msg_esclusi_proposte (file, pronta, righe, ricevuta_il)
    values (p_file, true, (select count(*) from public.msg_esclusi_proposti where file = p_file), now())
    on conflict (file) do update set pronta = true, righe = excluded.righe, ricevuta_il = now();
  end if;
  return n;
end $function$;

-- ── Applicazione (di notte) ───────────────────────────────────────────────────────────────────────────────
create or replace function public._msg_esclusi_proponi_da_db(p_file integer)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  delete from public.msg_esclusi_proposti where file = p_file;
  insert into public.msg_esclusi_proposti (file, data, ean, codice_cliente, movimento, lancio, copie, netto, lordo)
  select p_file, x.* from public._msg_esclusi_calcola(p_file) x;
  insert into public.msg_esclusi_proposte (file, pronta, righe, ricevuta_il)
  values (p_file, true, (select count(*) from public.msg_esclusi_proposti where file = p_file), now())
  on conflict (file) do update set pronta = true, righe = excluded.righe, ricevuta_il = now();
end $function$;

-- Porta le esclusioni del file alla proposta: corregge i riepiloghi con la differenza.
-- Nota: in msg_cliente_giorno la differenza va nel tipo calcolato con l'uscita di oggi; se l'uscita del titolo
-- è cambiata dopo il calcolo del riepilogo, il totale del cliente torna ma la ripartizione per tipo può spostarsi.
create or replace function public._msg_esclusi_applica(p_file integer)
 returns integer
 language plpgsql
 security definer
 set search_path to 'public'
 set plan_cache_mode to 'force_custom_plan'
as $function$
declare n integer; v_date date[];
begin
  delete from public.msg_esclusi_delta where file = p_file;
  insert into public.msg_esclusi_delta (file, data, ean, codice_cliente, movimento, lancio, copie, netto, lordo)
  select p_file, coalesce(p.data, v.data), coalesce(p.ean, v.ean), coalesce(p.codice_cliente, v.codice_cliente),
    coalesce(p.movimento, v.movimento), coalesce(p.lancio, v.lancio),
    coalesce(p.copie, 0) - coalesce(v.copie, 0), coalesce(p.netto, 0) - coalesce(v.netto, 0), coalesce(p.lordo, 0) - coalesce(v.lordo, 0)
  from (select * from public.msg_esclusi_proposti where file = p_file) p
  full join (select * from public.msg_esclusi where file = p_file) v
    on v.data = p.data and v.ean = p.ean and v.codice_cliente = p.codice_cliente and v.movimento = p.movimento and v.lancio = p.lancio
  where coalesce(p.copie, 0) <> coalesce(v.copie, 0) or coalesce(p.netto, 0) <> coalesce(v.netto, 0)
     or coalesce(p.lordo, 0) <> coalesce(v.lordo, 0) or (p.file is null) <> (v.file is null);
  get diagnostics n = row_count;

  if n > 0 then
    -- Titolo × giorno: si toglie la differenza (negativa = righe che tornano nei dati)
    insert into public.msg_titolo_giorno as g (data, ean, lancio, copie_f, copie_r, netto_f, netto_r, lordo_f, lordo_r)
    select d.data, d.ean, d.lancio,
      -coalesce(sum(d.copie) filter (where d.movimento = 'F'), 0), -coalesce(sum(d.copie) filter (where d.movimento = 'R'), 0),
      -coalesce(sum(d.netto) filter (where d.movimento = 'F'), 0), -coalesce(sum(d.netto) filter (where d.movimento = 'R'), 0),
      -coalesce(sum(d.lordo) filter (where d.movimento = 'F'), 0), -coalesce(sum(d.lordo) filter (where d.movimento = 'R'), 0)
    from public.msg_esclusi_delta d where d.file = p_file
    group by d.data, d.ean, d.lancio
    on conflict (data, ean, lancio) do update set
      copie_f = g.copie_f + excluded.copie_f, copie_r = g.copie_r + excluded.copie_r,
      netto_f = g.netto_f + excluded.netto_f, netto_r = g.netto_r + excluded.netto_r,
      lordo_f = g.lordo_f + excluded.lordo_f, lordo_r = g.lordo_r + excluded.lordo_r;
    delete from public.msg_titolo_giorno g
    using (select distinct data, ean, lancio from public.msg_esclusi_delta where file = p_file) d
    where g.data = d.data and g.ean = d.ean and g.lancio = d.lancio
      and g.copie_f = 0 and g.copie_r = 0 and g.netto_f = 0 and g.netto_r = 0 and g.lordo_f = 0 and g.lordo_r = 0;

    -- Cliente × giorno × tipo
    insert into public.msg_cliente_giorno as c (data, codice_cliente, tipo, copie_f, copie_r, netto_f, netto_r, lordo_f, lordo_r)
    select d.data, d.codice_cliente, public._msg_tipo(d.lancio, d.data, t.data_uscita),
      -coalesce(sum(d.copie) filter (where d.movimento = 'F'), 0), -coalesce(sum(d.copie) filter (where d.movimento = 'R'), 0),
      -coalesce(sum(d.netto) filter (where d.movimento = 'F'), 0), -coalesce(sum(d.netto) filter (where d.movimento = 'R'), 0),
      -coalesce(sum(d.lordo) filter (where d.movimento = 'F'), 0), -coalesce(sum(d.lordo) filter (where d.movimento = 'R'), 0)
    from public.msg_esclusi_delta d left join public.msg_titoli t on t.ean = d.ean
    where d.file = p_file
    group by 1, 2, 3
    on conflict (data, codice_cliente, tipo) do update set
      copie_f = c.copie_f + excluded.copie_f, copie_r = c.copie_r + excluded.copie_r,
      netto_f = c.netto_f + excluded.netto_f, netto_r = c.netto_r + excluded.netto_r,
      lordo_f = c.lordo_f + excluded.lordo_f, lordo_r = c.lordo_r + excluded.lordo_r;
    delete from public.msg_cliente_giorno c
    using (select distinct data, codice_cliente from public.msg_esclusi_delta where file = p_file) d
    where c.data = d.data and c.codice_cliente = d.codice_cliente
      and c.copie_f = 0 and c.copie_r = 0 and c.netto_f = 0 and c.netto_r = 0 and c.lordo_f = 0 and c.lordo_r = 0;

    v_date := array(select distinct data from public.msg_esclusi_delta where file = p_file);
  end if;

  delete from public.msg_esclusi where file = p_file;
  insert into public.msg_esclusi (file, data, ean, codice_cliente, movimento, lancio, copie, netto, lordo)
  select file, data, ean, codice_cliente, movimento, lancio, copie, netto, lordo from public.msg_esclusi_proposti where file = p_file;
  delete from public.msg_esclusi_delta where file = p_file;
  delete from public.msg_esclusi_proposti where file = p_file;
  delete from public.msg_esclusi_proposte where file = p_file;

  if n > 0 then
    perform public._msg_ricalcola_editori_giorno(v_date);
    perform public._msg_ricalcola_mesi(v_date);
  end if;
  return n;
end $function$;

-- Un file per giro: prima le proposte dello script, poi i file nel database (una verifica per notte)
create or replace function public.msg_esclusioni_notte()
 returns text
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_file integer; v_nome text; n integer;
begin
  if not pg_try_advisory_xact_lock(hashtext('msg_import_chiudi_in_attesa')) then return 'già al lavoro'; end if;
  if exists (select 1 from public.msg_importazioni where stato = 'da chiudere') then return 'aspetto la chiusura dei file'; end if;
  perform public._msg_sincronizza_ingressi();

  select p.file into v_file from public.msg_esclusi_proposte p join public.msg_importazioni i on i.file = p.file
  where p.pronta and i.stato = 'completata' order by p.file limit 1;
  if v_file is null then
    select i.file into v_file from public.msg_importazioni i left join public.msg_esclusi_verifiche v on v.file = i.file
    where i.movimenti_in_db and i.stato = 'completata' and (v.verificato_il is null or v.verificato_il < current_date)
    order by i.file limit 1;
    if v_file is null then return 'niente da fare'; end if;
    perform public._msg_esclusi_proponi_da_db(v_file);
  end if;

  n := public._msg_esclusi_applica(v_file);
  insert into public.msg_esclusi_verifiche (file, verificato_il) values (v_file, now())
  on conflict (file) do update set verificato_il = now();
  select nome_file into v_nome from public.msg_importazioni where file = v_file;
  if n > 0 then
    insert into public.sftp_esecuzioni (origine, ok, file_scaricati, messaggio)
    values ('importazione', true, 0, format('Esclusioni aggiornate su %s: %s righe cambiate', v_nome, n));
  end if;
  return format('%s: %s righe cambiate', v_nome, n);
end $function$;

-- ── Chiusura e riepiloghi: tolgono le righe escluse ──────────────────────────────────────────────────────
create or replace function public._msg_ricalcola_riepiloghi(p_date date[], p_mesi boolean default true)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
 set plan_cache_mode to 'force_custom_plan'
as $function$
declare v_file text;
begin
  select string_agg(i.nome_file, ', ') into v_file from public.msg_importazioni i
  where not i.movimenti_in_db and exists (select 1 from unnest(p_date) d where d between i.data_min and i.data_max);
  if v_file is not null then
    raise exception 'Giorni già archiviati in Parquet (%): i riepiloghi di quei giorni non si ricalcolano dai movimenti', v_file;
  end if;

  delete from public.msg_titolo_giorno where data = any(p_date);
  insert into public.msg_titolo_giorno (data, ean, lancio, copie_f, copie_r, netto_f, netto_r, lordo_f, lordo_r)
  select m.data, m.ean, m.lancio,
    coalesce(sum(m.copie) filter (where m.movimento = 'F'), 0), coalesce(sum(m.copie) filter (where m.movimento = 'R'), 0),
    coalesce(sum(m.netto) filter (where m.movimento = 'F'), 0), coalesce(sum(m.netto) filter (where m.movimento = 'R'), 0),
    coalesce(sum(m.lordo) filter (where m.movimento = 'F'), 0), coalesce(sum(m.lordo) filter (where m.movimento = 'R'), 0)
  from public.msg_movimenti m
  where m.data = any(p_date)
    and not exists (select 1 from public.msg_esclusi e where e.file = m.file and e.data = m.data and e.ean = m.ean
                    and e.codice_cliente = m.codice_cliente and e.movimento = m.movimento and e.lancio = m.lancio)
  group by m.data, m.ean, m.lancio;

  perform public._msg_ricalcola_editori_giorno(p_date);

  delete from public.msg_cliente_giorno where data = any(p_date);
  insert into public.msg_cliente_giorno (data, codice_cliente, tipo, copie_f, copie_r, netto_f, netto_r, lordo_f, lordo_r)
  select m.data, m.codice_cliente, public._msg_tipo(m.lancio, m.data, t.data_uscita),
    coalesce(sum(m.copie) filter (where m.movimento = 'F'), 0), coalesce(sum(m.copie) filter (where m.movimento = 'R'), 0),
    coalesce(sum(m.netto) filter (where m.movimento = 'F'), 0), coalesce(sum(m.netto) filter (where m.movimento = 'R'), 0),
    coalesce(sum(m.lordo) filter (where m.movimento = 'F'), 0), coalesce(sum(m.lordo) filter (where m.movimento = 'R'), 0)
  from public.msg_movimenti m join public.msg_titoli t on t.ean = m.ean
  where m.data = any(p_date)
    and not exists (select 1 from public.msg_esclusi e where e.file = m.file and e.data = m.data and e.ean = m.ean
                    and e.codice_cliente = m.codice_cliente and e.movimento = m.movimento and e.lancio = m.lancio)
  group by 1, 2, 3;

  if p_mesi then perform public._msg_ricalcola_mesi(p_date); end if;
end $function$;

-- Passo 2 della chiusura: dopo gli editori dei titoli, le esclusioni del file; poi i riepiloghi (che le tolgono)
create or replace function public._msg_import_chiudi(p_file integer, p_passo integer)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
 set plan_cache_mode to 'force_custom_plan'
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
    perform public._msg_sincronizza_ingressi();
    delete from public.msg_esclusi where file = p_file;
    insert into public.msg_esclusi (file, data, ean, codice_cliente, movimento, lancio, copie, netto, lordo)
    select p_file, x.* from public._msg_esclusi_calcola(p_file) x;
    insert into public.msg_esclusi_verifiche (file, verificato_il) values (p_file, now())
    on conflict (file) do update set verificato_il = now();
    perform public._msg_ricalcola_riepiloghi(v_date, false);
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

-- Eliminare un'importazione toglie anche le sue esclusioni
create or replace function public.msg_import_elimina(p_file integer)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_date date[];
begin
  if not public._is_admin_pde() then raise exception 'Operazione riservata agli amministratori PDE'; end if;
  if exists (select 1 from public.msg_importazioni where file = p_file and not movimenti_in_db) then
    raise exception 'Il file è già archiviato in Parquet: per correggerlo reimportalo, i suoi giorni verranno sostituiti';
  end if;
  v_date := array(select distinct data from public.msg_movimenti where file = p_file);
  delete from public.msg_movimenti where file = p_file;
  delete from public.msg_esclusi where file = p_file;
  delete from public.msg_esclusi_proposti where file = p_file;
  delete from public.msg_esclusi_proposte where file = p_file;
  delete from public.msg_esclusi_verifiche where file = p_file;
  delete from public.msg_importazioni where file = p_file;
  perform public._msg_ricalcola_riepiloghi(v_date);
end $function$;

-- Le funzioni interne non si chiamano dalle API
revoke execute on function public._msg_sincronizza_ingressi() from public, anon, authenticated;
revoke execute on function public._msg_esclusi_calcola(integer) from public, anon, authenticated;
revoke execute on function public._msg_esclusi_proponi_da_db(integer) from public, anon, authenticated;
revoke execute on function public._msg_esclusi_applica(integer) from public, anon, authenticated;
revoke execute on function public.msg_esclusioni_notte() from public, anon, authenticated;

select public._msg_sincronizza_ingressi();

-- ── pg_cron: di notte, dalle 0 alle 4 UTC (1-5 italiane d'inverno), un file ogni 3 minuti ────────────────
select cron.unschedule('msg-esclusioni') where exists (select 1 from cron.job where jobname = 'msg-esclusioni');
select cron.schedule('msg-esclusioni', '*/3 0-3 * * *',
  $$set statement_timeout = '10min'; set lock_timeout = '1min'; select public.msg_esclusioni_notte()$$);
