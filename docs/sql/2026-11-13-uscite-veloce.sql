-- 2026-11-13 · Chiusura dei mensili bloccata su _msg_aggiorna_uscite
--
-- La notte del 12/11 la chiusura di 202507 e 202508 è andata in timeout (30 min) 12 volte di fila, sempre
-- sull'update di msg_titoli.data_uscita. Il filtro "p_file is null or t2.ean in (select ...)" impedisce al
-- planner di trasformare la sottoquery in un semi-join: con work_mem a 3,5 MB la sottoquery non sta in hash
-- e viene riletta per ognuno dei ~100.000 titoli (costo stimato 495 milioni; con un giornaliero si notava poco).
-- Con due rami separati (con e senza file) il piano torna un hash join: 0,3 s su un mese intero.
-- Il comportamento non cambia.

create or replace function public._msg_aggiorna_uscite(p_file integer default null)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
 set plan_cache_mode to 'force_custom_plan'
as $function$
begin
  if p_file is not null then
    update public.msg_titoli t set primo_lancio = least(t.primo_lancio, x.l), primo_rifornimento = least(t.primo_rifornimento, x.r)
    from (select ean, min(data) filter (where lancio) l, min(data) filter (where not lancio) r
          from public.msg_movimenti where file = p_file and movimento = 'F' group by ean) x
    where x.ean = t.ean and (t.primo_lancio is distinct from least(t.primo_lancio, x.l) or t.primo_rifornimento is distinct from least(t.primo_rifornimento, x.r));

    -- Uscita = prima bolla di lancio se precede ogni rifornimento, oppure storico 2025, oppure novità di Giro Manager
    update public.msg_titoli t set data_uscita = n.d
    from (
      select t2.ean, least(case when t2.primo_lancio is not null and (t2.primo_rifornimento is null or t2.primo_lancio <= t2.primo_rifornimento)
          then t2.primo_lancio end, s.data, nv.data) d
      from public.msg_titoli t2
      left join public.msg_uscite_storico s on s.ean = t2.ean
      left join (select ean, min(data_messa_in_vendita) data from public.titoli_novita where data_messa_in_vendita < '2099-01-01' group by ean) nv on nv.ean = t2.ean
      where t2.ean in (select ean from public.msg_movimenti where file = p_file)
    ) n
    where n.ean = t.ean and t.data_uscita is distinct from n.d;
  else
    update public.msg_titoli t set data_uscita = n.d
    from (
      select t2.ean, least(case when t2.primo_lancio is not null and (t2.primo_rifornimento is null or t2.primo_lancio <= t2.primo_rifornimento)
          then t2.primo_lancio end, s.data, nv.data) d
      from public.msg_titoli t2
      left join public.msg_uscite_storico s on s.ean = t2.ean
      left join (select ean, min(data_messa_in_vendita) data from public.titoli_novita where data_messa_in_vendita < '2099-01-01' group by ean) nv on nv.ean = t2.ean
    ) n
    where n.ean = t.ean and t.data_uscita is distinct from n.d;
  end if;
end $function$;
