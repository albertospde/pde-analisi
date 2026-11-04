-- Chiusura dei giornalieri subito dopo l'importazione del mattino (prima solo di notte, dalle 22).
-- Le chiusure dei PPSVMAGG durano 7-40 s da quando msg_movimenti è stato svuotato (22/10): pg_cron
-- "msg-import-chiudi-mattino" ogni 5 minuti dalle 5 alle 11 UTC chiude solo i giornalieri (file < 100000);
-- i mesi dello storico restano alla chiusura notturna (msg-import-chiudi, msg_import_chiudi_in_attesa).
-- Stesso lucchetto della chiusura notturna: le due non lavorano mai insieme.
-- Tempi massimi stretti (5 minuti, 30 s di attesa sui lucchetti): se una chiusura si blocca viene annullata,
-- il file resta 'da chiudere' e si riprova al giro successivo o di notte, senza fermare PDE Hub e le altre app.

create or replace function public.msg_import_chiudi_giornalieri()
returns text
language plpgsql security definer
set search_path to 'public'
as $function$
declare v_file integer; v_nome text; v_passo integer := 1; v_esito jsonb;
begin
  if not pg_try_advisory_xact_lock(hashtext('msg_import_chiudi_in_attesa')) then return 'già al lavoro'; end if;
  select file, nome_file into v_file, v_nome from public.msg_importazioni
  where stato = 'da chiudere' and file < 100000 order by file limit 1;
  if v_file is null then return 'niente da chiudere'; end if;
  begin
    while v_passo is not null loop
      v_esito := public._msg_import_chiudi(v_file, v_passo);
      v_passo := (v_esito ->> 'passo')::int;
    end loop;
    insert into public.sftp_esecuzioni (origine, ok, file_scaricati, messaggio)
    values ('importazione', true, 0, format('Chiuso %s subito dopo l''importazione: editori e riepiloghi aggiornati', v_nome));
    return 'chiuso ' || v_nome;
  exception when others then
    insert into public.sftp_esecuzioni (origine, ok, file_scaricati, messaggio)
    values ('importazione', false, 0, format('Chiusura di %s non riuscita (si riprova tra 5 minuti): %s', v_nome, sqlerrm));
    return 'errore: ' || sqlerrm;
  end;
end $function$;
revoke execute on function public.msg_import_chiudi_giornalieri() from public, anon, authenticated;

select cron.schedule('msg-import-chiudi-mattino', '*/5 5-10 * * *',
  $c$set statement_timeout = '5min'; set lock_timeout = '30s'; select public.msg_import_chiudi_giornalieri()$c$);
