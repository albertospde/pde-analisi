-- 2026-11-13 · Dati GfK in PDE Analisi
--
-- QDM salva ogni giovedì in qdm_top20 l'ultima settimana GfK per EAN (i primi 10.000 titoli del mercato):
-- tipo 'WEEK' = la settimana (es. CW45), tipo 'TOTALE' = il progressivo dell'anno (CW01-CW45).
-- La pagina li mostra per titolo e, sommati, per editore (editore di msg_titoli). Funzione leggera (~40 ms,
-- circa 1.000 righe): si può lanciare anche di giorno.

create or replace function public.msg_gfk()
 returns table(ean text, editore text, anno integer, cw_da integer, cw_a integer,
               valore_week numeric, copie_week numeric, valore_prog numeric, copie_prog numeric)
 language plpgsql
 stable
 security definer
 set search_path to 'public'
as $function$
begin
  if not public._is_admin_pde() then return; end if;
  return query
  select t.ean, m.editore, s.anno, s.cw_from, s.cw_to,
    coalesce(sum(t.value) filter (where t.tipo = 'WEEK'), 0), coalesce(sum(t.units) filter (where t.tipo = 'WEEK'), 0)::numeric,
    coalesce(sum(t.value) filter (where t.tipo = 'TOTALE'), 0), coalesce(sum(t.units) filter (where t.tipo = 'TOTALE'), 0)::numeric
  from public.qdm_top20 t
  join public.msg_titoli m on m.ean = t.ean
  join public.qdm_settimane s on s.week_key = t.week_key
  group by t.ean, m.editore, s.anno, s.cw_from, s.cw_to;
end
$function$;

revoke all on function public.msg_gfk() from public, anon;
grant execute on function public.msg_gfk() to authenticated;
