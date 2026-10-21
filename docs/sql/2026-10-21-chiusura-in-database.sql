-- PDE Analisi · la chiusura degli import la fa il database (21/10/2026)
--
-- Dal browser ogni richiesta ha al massimo 8 secondi (statement_timeout del ruolo authenticated, uguale
-- per tutte le app del database): la chiusura (editori e riepiloghi) non ci sta. Ora:
--  · la pagina carica i movimenti e chiama msg_import_da_chiudere(file): totali del file per il
--    controllo (veloce) e stato 'da chiudere'
--  · pg_cron "msg-import-chiudi" ogni 2 minuti chiude i file 'da chiudere' (3 passi, senza limite di 8 s)
--    e scrive l'esito nel registro SFTP
--  · lo script GitHub (service role, 120 s) continua a chiudere da sé con msg_import_chiudi

-- Passi della chiusura senza controllo dell'utente (li usano msg_import_chiudi e pg_cron)
create or replace function public._msg_import_chiudi(p_file integer, p_passo integer)
returns jsonb
language plpgsql security definer set search_path to 'public' set plan_cache_mode to 'force_custom_plan'
as $function$
declare v_date date[]; v_ean text[]; v_cambiati text[]; r public.msg_importazioni;
begin
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

create or replace function public.msg_import_chiudi(p_file integer, p_passo integer)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
begin
  if not public._msg_import_autorizzato() then raise exception 'Operazione riservata agli amministratori PDE'; end if;
  return public._msg_import_chiudi(p_file, p_passo);
end $function$;

-- Dalla pagina: totali del file (per il controllo con il file) e chiusura affidata al database
create or replace function public.msg_import_da_chiudere(p_file integer)
returns public.msg_importazioni
language plpgsql security definer set search_path to 'public'
as $function$
declare r public.msg_importazioni;
begin
  if not public._msg_import_autorizzato() then raise exception 'Operazione riservata agli amministratori PDE'; end if;
  update public.msg_importazioni i set
    righe_caricate = s.righe, copie_fornite = s.cf, copie_rese = s.cr, netto_fornito = s.nf, netto_reso = s.nr,
    stato = 'da chiudere'
  from (
    select count(*) as righe,
      coalesce(sum(copie) filter (where movimento = 'F'), 0) as cf, coalesce(sum(copie) filter (where movimento = 'R'), 0) as cr,
      coalesce(sum(netto) filter (where movimento = 'F'), 0) as nf, coalesce(sum(netto) filter (where movimento = 'R'), 0) as nr
    from public.msg_movimenti where file = p_file
  ) s
  where i.file = p_file
  returning i.* into r;
  return r;
end $function$;
grant execute on function public.msg_import_da_chiudere(integer) to authenticated;

-- pg_cron: chiude un file 'da chiudere' alla volta; un errore va nel registro e si riprova al giro dopo
create or replace function public.msg_import_chiudi_in_attesa()
returns text
language plpgsql security definer set search_path to 'public'
as $function$
declare v_file integer; v_nome text; v_passo integer := 1; v_esito jsonb;
begin
  if not pg_try_advisory_xact_lock(hashtext('msg_import_chiudi_in_attesa')) then return 'già al lavoro'; end if;
  select file, nome_file into v_file, v_nome from public.msg_importazioni where stato = 'da chiudere' order by file limit 1;
  if v_file is null then return 'niente da chiudere'; end if;
  begin
    while v_passo is not null loop
      v_esito := public._msg_import_chiudi(v_file, v_passo);
      v_passo := (v_esito ->> 'passo')::int;
    end loop;
    insert into public.sftp_esecuzioni (origine, ok, file_scaricati, messaggio)
    values ('importazione', true, 0, format('Chiuso %s: editori e riepiloghi aggiornati', v_nome));
    return 'chiuso ' || v_nome;
  exception when others then
    insert into public.sftp_esecuzioni (origine, ok, file_scaricati, messaggio)
    values ('importazione', false, 0, format('Chiusura di %s non riuscita (si riprova tra 2 minuti): %s', v_nome, sqlerrm));
    return 'errore: ' || sqlerrm;
  end;
end $function$;
revoke execute on function public.msg_import_chiudi_in_attesa() from public, anon, authenticated;
revoke execute on function public._msg_import_chiudi(integer, integer) from public, anon, authenticated;

-- Un file 'da chiudere' è già caricato: non va reimportato
create or replace function public.msg_import_da_fare()
returns table(id bigint, nome_remoto text, percorso_storage text, file integer)
language sql stable security definer set search_path to 'public'
as $function$
  select distinct on (substring(f.nome_remoto from '(?i)^PPSVMAGG\.?(\d+)$')::int)
    f.id, f.nome_remoto, f.percorso_storage, substring(f.nome_remoto from '(?i)^PPSVMAGG\.?(\d+)$')::int
  from public.sftp_file f
  where f.cancellato_il is null
    and f.nome_remoto ~* '^PPSVMAGG\.?\d+$'
    and not exists (select 1 from public.msg_importazioni i
                    where i.file = substring(f.nome_remoto from '(?i)^PPSVMAGG\.?(\d+)$')::int and i.stato in ('completata', 'da chiudere'))
  order by substring(f.nome_remoto from '(?i)^PPSVMAGG\.?(\d+)$')::int, f.scaricato_il desc;
$function$;

select cron.schedule('msg-import-chiudi', '*/2 * * * *', $$select public.msg_import_chiudi_in_attesa()$$);

-- Il 293 è caricato (passo 1 fatto dalla pagina): lo chiude il database
update public.msg_importazioni set stato = 'da chiudere' where file = 293 and stato = 'in corso'
  and exists (select 1 from public.msg_movimenti where file = 293);
