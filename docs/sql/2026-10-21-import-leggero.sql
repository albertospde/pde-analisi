-- PDE Analisi · chiusura dell'import più leggera e import avviato da Supabase (21/10/2026)
--
-- Prima: a ogni import _msg_riassegna_editori svuotava e riscriveva l'editore di tutti i titoli
-- (~46.000 righe) e _msg_aggiorna_clienti riscriveva tutti i gruppi clienti, anche senza cambiamenti:
-- molta scrittura su disco e chiusure oltre il tempo massimo.
-- Ora:
--  · _msg_calcola_editori(p_ean) calcola gli editori (di tutti i titoli o solo di quelli indicati) e
--    scrive solo le righe che cambiano; restituisce gli EAN cambiati
--  · _msg_aggiorna_clienti aggiorna solo i gruppi clienti cambiati
--  · msg_import_chiudi(p_file, p_passo) chiude un import in 3 passi, ognuno una chiamata a sé:
--      1 totali del file, gruppi clienti, date di uscita
--      2 editori dei soli titoli del file + riepiloghi giornalieri (giorni del file e giorni dei titoli cambiati)
--      3 riepiloghi mensili e stato 'completata'
--    msg_import_completa resta e fa i 3 passi di fila (compatibilità)
--  · msg_editori_settimanale: ricalcolo completo degli editori la domenica notte (pg_cron)
--  · msg_import_avvia: pg_cron avvia il workflow GitHub di import appena ci sono file da importare
--    (il programmatore di GitHub ritarda gli orari anche di ore). Token in app_secrets:
--    github_pde_analisi_token se c'è, altrimenti github_giro_manager_token.

-- ─── Editori: calcolo con scrittura solo delle righe cambiate ───
create or replace function public._msg_calcola_editori(p_ean text[] default null)
returns text[]
language plpgsql security definer set search_path to 'public'
as $function$
declare v_cambiati text[];
begin
  drop table if exists _rk, _fonti, _canon, _principale, _tit, _coll, _cod, _nuovo;
  create temp table _rk on commit drop as
    select ltrim(codice_editore, '0') as codice, upper(regexp_replace(trim(editore_nome), '\s+', ' ', 'g')) as nome
    from public.ranking_editori where coalesce(editore_nome, '') <> '' group by 1, 2;

  create temp table _fonti on commit drop as
    select ean, ltrim(codice_editore, '0') as codice, upper(regexp_replace(trim(editore_nome), '\s+', ' ', 'g')) as grezzo, 1 as ord
      from public.titoli where coalesce(editore_nome, '') <> ''
    union all select ean, ltrim(editore_codice, '0'), upper(regexp_replace(trim(editore_nome), '\s+', ' ', 'g')), 2
      from public.titoli_manuali where coalesce(editore_nome, '') <> ''
    union all select ean, ltrim(codice_editore, '0'), upper(regexp_replace(trim(editore), '\s+', ' ', 'g')), 3
      from public.lanci_settimanali where coalesce(editore, '') <> '';

  create temp table _canon on commit drop as
    select n.grezzo,
      coalesce(
        (select min(r.nome) from (select distinct nome from _rk) r
          where public._msg_chiave_editore(r.nome) = public._msg_chiave_editore(n.alias)
          having count(*) = 1),
        n.alias) as nome
    from (
      select g.grezzo, coalesce(
        (select upper(regexp_replace(trim(a.editore_nome), '\s+', ' ', 'g')) from public.alias_editori a
          where upper(trim(a.alias)) = g.grezzo limit 1), g.grezzo) as alias
      from (select distinct grezzo from _fonti) g
    ) n;

  create temp table _principale on commit drop as
    select distinct on (r.codice) r.codice, r.nome from _rk r
    left join (select c.nome, count(*) as n from _fonti f join _canon c using (grezzo) where f.ord = 1 group by 1) g on g.nome = r.nome
    order by r.codice, coalesce(g.n, 0) desc, length(r.nome);

  -- 1. editore dal titolo (Giro Manager, titoli manuali, lanci): serve per tutti i titoli, perché
  --    la collana prevalente (passo 3) si calcola su questi
  create temp table _tit on commit drop as
    select distinct on (f.ean) f.ean, c.nome
    from _fonti f join _canon c using (grezzo)
    join public.msg_titoli m on m.ean = f.ean
    where exists (select 1 from _rk r where r.codice = m.codice_editore and r.nome = c.nome)
       or not exists (select 1 from _rk r where r.codice = m.codice_editore)
    order by f.ean, f.ord;

  create temp table _coll on commit drop as
    select distinct on (m.codice_editore, m.collana) m.codice_editore, m.collana, t.nome
    from public.msg_titoli m join _tit t on t.ean = m.ean
    group by m.codice_editore, m.collana, t.nome
    order by m.codice_editore, m.collana, count(*) desc;

  create temp table _cod on commit drop as
    select distinct on (f.codice) f.codice, k.nome
    from _fonti f join _canon k using (grezzo)
    group by f.codice, k.nome order by f.codice, count(*) desc;

  -- Stesso ordine di prima: titolo → collana scelta a mano → collana prevalente → principale del codice
  -- → codice più frequente nelle fonti → sconosciuto
  create temp table _nuovo on commit drop as
    select m.ean,
      case when t.nome is not null then t.nome
           when ce.editore is not null then upper(trim(ce.editore))
           when co.nome is not null then co.nome
           when p.nome is not null then p.nome
           when cd.nome is not null then cd.nome
           else 'EDITORE COD. ' || m.codice_editore end as editore,
      case when t.nome is not null then 'titolo'
           when ce.editore is not null then 'collana (manuale)'
           when co.nome is not null then 'collana'
           when p.nome is not null or cd.nome is not null then 'codice'
           else 'sconosciuto' end as fonte
    from public.msg_titoli m
    left join _tit t on t.ean = m.ean
    left join public.msg_collane_editore ce on ce.codice_editore = m.codice_editore and ce.collana = m.collana
    left join _coll co on co.codice_editore = m.codice_editore and co.collana = m.collana
    left join _principale p on p.codice = m.codice_editore
    left join _cod cd on cd.codice = m.codice_editore
    where p_ean is null or m.ean = any(p_ean);

  with cambiati as (
    update public.msg_titoli m set editore = n.editore, editore_fonte = n.fonte
    from _nuovo n
    where n.ean = m.ean and (m.editore is distinct from n.editore or m.editore_fonte is distinct from n.fonte)
    returning m.ean
  )
  select coalesce(array_agg(ean), '{}') into v_cambiati from cambiati;
  return v_cambiati;
end $function$;

-- Le vecchie funzioni ora usano il calcolo nuovo (niente più svuotamento di tutti i titoli)
create or replace function public._msg_assegna_editori()
returns void language plpgsql security definer set search_path to 'public'
as $function$ begin perform public._msg_calcola_editori(null); end $function$;

create or replace function public._msg_riassegna_editori()
returns void language plpgsql security definer set search_path to 'public'
as $function$ begin perform public._msg_calcola_editori(null); end $function$;

-- ─── Gruppi clienti: scrive solo le righe cambiate ───
create or replace function public._msg_aggiorna_clienti()
returns void language plpgsql security definer set search_path to 'public'
as $function$
begin
  delete from public.msg_clienti_gruppo where codice_cliente not in (select codice_cliente from public.msg_clienti);
  insert into public.msg_clienti_gruppo as x (codice_cliente, ragione_sociale, citta, provincia, gruppo, categoria, canale, canale_gruppo)
  select c.codice_cliente, coalesce(nullif(trim(a.ragione_sociale), ''), c.ragione_sociale), c.citta, c.provincia,
    coalesce(g.gruppo_cliente, nullif(trim(a.gruppo_desc), ''), 'Non classificato'),
    coalesce(g.categoria, 'Non classificato'),
    coalesce(k.nome, g.canale_codice, 'Non classificato'),
    coalesce(k.gruppo, 'ALTRO')
  from public.msg_clienti c
  left join lateral (select * from public.anagrafiche_clienti a
    where ltrim(a.codice_cliente, '0') = ltrim(c.codice_cliente, '0') limit 1) a on true
  left join public.gruppi_clienti g on a.gruppo_codice ~ '^\d+$' and g.codice_gruppo = a.gruppo_codice::int
  left join public.canali k on k.codice = g.canale_codice
  on conflict (codice_cliente) do update set ragione_sociale = excluded.ragione_sociale, citta = excluded.citta,
    provincia = excluded.provincia, gruppo = excluded.gruppo, categoria = excluded.categoria,
    canale = excluded.canale, canale_gruppo = excluded.canale_gruppo
  where (x.ragione_sociale, x.citta, x.provincia, x.gruppo, x.categoria, x.canale, x.canale_gruppo)
    is distinct from (excluded.ragione_sociale, excluded.citta, excluded.provincia, excluded.gruppo, excluded.categoria, excluded.canale, excluded.canale_gruppo);
end $function$;

-- ─── Chiusura dell'import in 3 passi ───
create or replace function public.msg_import_chiudi(p_file integer, p_passo integer)
returns jsonb
language plpgsql security definer set search_path to 'public' set plan_cache_mode to 'force_custom_plan'
as $function$
declare v_date date[]; v_ean text[]; v_cambiati text[]; r public.msg_importazioni;
begin
  if not public._msg_import_autorizzato() then raise exception 'Operazione riservata agli amministratori PDE'; end if;
  v_date := array(select distinct data from public.msg_movimenti where file = p_file);

  if p_passo = 1 then
    update public.msg_importazioni i set
      righe_caricate = s.righe, copie_fornite = s.cf, copie_rese = s.cr, netto_fornito = s.nf, netto_reso = s.nr
    from (
      select count(*) as righe,
        coalesce(sum(copie) filter (where movimento = 'F'), 0) as cf, coalesce(sum(copie) filter (where movimento = 'R'), 0) as cr,
        coalesce(sum(netto) filter (where movimento = 'F'), 0) as nf, coalesce(sum(netto) filter (where movimento = 'R'), 0) as nr
      from public.msg_movimenti where file = p_file
    ) s
    where i.file = p_file;
    perform public._msg_aggiorna_clienti();
    perform public._msg_aggiorna_uscite(p_file);
    return jsonb_build_object('passo', 2);

  elsif p_passo = 2 then
    -- Editori dei soli titoli del file; i giorni passati dei titoli che cambiano editore si rifanno anche loro
    v_ean := array(select distinct ean from public.msg_movimenti where file = p_file);
    v_cambiati := public._msg_calcola_editori(v_ean);
    perform public._msg_ricalcola_riepiloghi(array(
      select unnest(v_date)
      union
      select distinct g.data from public.msg_titolo_giorno g where g.ean = any(v_cambiati)), false);
    return jsonb_build_object('passo', 3, 'titoli_cambiati', coalesce(array_length(v_cambiati, 1), 0));

  elsif p_passo = 3 then
    perform public._msg_ricalcola_mesi(v_date);
    update public.msg_importazioni set stato = 'completata', completata_il = now() where file = p_file returning * into r;
    return jsonb_build_object('passo', null, 'importazione', to_jsonb(r));
  end if;
  raise exception 'Passo non valido: %', p_passo;
end $function$;

create or replace function public.msg_import_completa(p_file integer)
returns public.msg_importazioni
language plpgsql security definer set search_path to 'public'
as $function$
declare r public.msg_importazioni;
begin
  perform public.msg_import_chiudi(p_file, 1);
  perform public.msg_import_chiudi(p_file, 2);
  perform public.msg_import_chiudi(p_file, 3);
  select * into r from public.msg_importazioni where file = p_file;
  return r;
end $function$;

grant execute on function public.msg_import_chiudi(integer, integer) to authenticated, service_role;

-- ─── Ricalcolo completo degli editori, la domenica notte ───
create or replace function public.msg_editori_settimanale()
returns text
language plpgsql security definer set search_path to 'public' set plan_cache_mode to 'force_custom_plan'
as $function$
declare v_cambiati text[]; v_date date[];
begin
  v_cambiati := public._msg_calcola_editori(null);
  v_date := array(select distinct g.data from public.msg_titolo_giorno g where g.ean = any(v_cambiati));
  if cardinality(v_date) > 0 then
    perform public._msg_ricalcola_riepiloghi(v_date, false);
    perform public._msg_ricalcola_mesi(v_date);
  end if;
  return format('%s titoli con editore cambiato, %s giorni ricalcolati', cardinality(v_cambiati), cardinality(v_date));
end $function$;

-- ─── Avvio del workflow GitHub di import appena ci sono file da importare ───
create or replace function public.msg_import_avvia()
returns text
language plpgsql security definer set search_path to 'public'
as $function$
declare v_token text; v_req bigint;
begin
  if not exists (select 1 from public.msg_import_da_fare()) then return 'niente da importare'; end if;
  -- Un import partito da meno di 25 minuti è ancora al lavoro: non se ne avvia un altro
  if exists (select 1 from public.msg_importazioni where stato = 'in corso' and iniziata_il > now() - interval '25 minutes') then
    return 'import già in corso';
  end if;
  select value into v_token from public.app_secrets where name = 'github_pde_analisi_token';
  if coalesce(v_token, '') = '' then select value into v_token from public.app_secrets where name = 'github_giro_manager_token'; end if;
  if coalesce(v_token, '') = '' then return 'token GitHub mancante (app_secrets.github_pde_analisi_token)'; end if;
  select net.http_post(
    url := 'https://api.github.com/repos/albertospde/pde-analisi/actions/workflows/importa-ppsvmagg.yml/dispatches',
    body := '{"ref":"main"}'::jsonb,
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || v_token,
      'Accept', 'application/vnd.github+json',
      'X-GitHub-Api-Version', '2022-11-28',
      'User-Agent', 'pde-supabase-cron',
      'Content-Type', 'application/json'),
    timeout_milliseconds := 30000) into v_req;
  return 'avvio richiesto (richiesta net ' || v_req || ')';
end $function$;

revoke execute on function public.msg_import_avvia() from public, anon, authenticated;
revoke execute on function public.msg_editori_settimanale() from public, anon, authenticated;
revoke execute on function public._msg_calcola_editori(text[]) from public, anon, authenticated;

-- pg_cron lavora in UTC. Download SFTP: ogni 10 minuti dalle 3 alle 6 UTC.
-- Import: ogni 20 minuti dalle 4 alle 9 UTC (6-11 italiane d'estate, 5-10 d'inverno); se non c'è niente esce subito.
select cron.schedule('msg-import-avvia', '7,27,47 4-9 * * *', $$select public.msg_import_avvia()$$);
select cron.schedule('msg-editori-settimanale', '0 2 * * 0', $$select public.msg_editori_settimanale()$$);
