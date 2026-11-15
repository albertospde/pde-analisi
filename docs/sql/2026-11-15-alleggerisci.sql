-- 2026-11-15 · msg_movimenti_alleggerisci: funziona anche da pg_cron
--
-- Il job notturno 'msg-movimenti-alleggerisci' falliva con "Operazione riservata agli amministratori PDE":
-- pg_cron gira come postgres, senza auth.role(), e _msg_import_autorizzato() lo rifiutava.
-- Ora è ammesso anche session_user = 'postgres' (pg_cron, editor SQL). Nuovo parametro p_max: quanti file
-- al massimo per chiamata (null = tutti), per togliere i movimenti a piccoli passi.

drop function if exists public.msg_movimenti_alleggerisci(integer);

create or replace function public.msg_movimenti_alleggerisci(p_giorni integer default 20, p_max integer default null)
 returns text
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare r record; n int := 0; v_righe bigint := 0; c bigint;
begin
  if not (public._msg_import_autorizzato() or session_user = 'postgres') then
    raise exception 'Operazione riservata agli amministratori PDE';
  end if;
  for r in
    select i.file from public.msg_importazioni i
    where i.movimenti_in_db and i.parquet_il is not null and i.stato = 'completata'
      and i.data_max < current_date - p_giorni
      and not exists (select 1 from public.msg_importazioni j where j.file <> i.file and j.stato <> 'completata'
                      and (j.data_min is null or (j.data_min <= i.data_max and j.data_max >= i.data_min)))
    order by i.file
    limit p_max
  loop
    delete from public.msg_movimenti where file = r.file;
    get diagnostics c = row_count;
    update public.msg_importazioni set movimenti_in_db = false where file = r.file;
    n := n + 1; v_righe := v_righe + c;
  end loop;
  return format('%s file archiviati, %s righe tolte da msg_movimenti', n, v_righe);
end $function$;

revoke execute on function public.msg_movimenti_alleggerisci(integer, integer) from public, anon;
