-- Revisione della pagina Analisi (6/11/2026).
-- 1) Rifornimento novità = nell'anno di uscita del titolo (non più 6 mesi dall'uscita), compresi i movimenti
--    precedenti all'uscita; oltre = catalogo (il valore in tabella resta 'classico').
--    msg_titolo_mese ha il tipo salvato con la regola vecchia: si ricava in lettura da mese e data_uscita, senza
--    riscrivere la tabella. msg_cliente_giorno/mese restano col tipo vecchio e non si usano più per i tipi:
--    con il filtro clienti la pagina calcola i tipi dai Parquet.
-- 2) Clienti: il livello "canale" è canale_gruppo (ONLINE, CATENE, INDIE, GROSSISTI, ALTRO).
-- 3) Codici editore per raggruppare nella pagina gli editori con lo stesso codice.

create or replace function public._msg_tipo(p_lancio boolean, p_data date, p_uscita date)
returns text language sql immutable set search_path to 'public'
as $function$ select case when p_lancio then 'lancio'
  when p_uscita is not null and p_data < make_date(extract(year from p_uscita)::int + 1, 1, 1) then 'novita'
  else 'classico' end $function$;

create or replace function public.msg_analisi_tipi(p_date date[], p_editori text[] default null, p_ean text default null, p_clienti text[] default null)
returns table(tipo text, copie_f bigint, copie_r bigint, netto_f numeric, netto_r numeric, lordo_f numeric, lordo_r numeric)
language plpgsql stable security definer set search_path to 'public' set plan_cache_mode to 'force_custom_plan'
as $function$
declare v_mesi date[]; v_giorni date[];
begin
  -- Con il filtro clienti la pagina calcola dai Parquet
  if not public._is_admin_pde() or p_clienti is not null then return; end if;
  select d.mesi, d.giorni into v_mesi, v_giorni from public._msg_dividi_date(p_date) d;
  return query select y.tp, sum(y.cf)::bigint, sum(y.cr)::bigint, sum(y.nf), sum(y.nr), sum(y.lf), sum(y.lr) from (
    select case when g.tipo = 'lancio' then 'lancio'
        when t.data_uscita is not null and g.mese < make_date(extract(year from t.data_uscita)::int + 1, 1, 1) then 'novita' else 'classico' end tp,
      sum(g.copie_f) cf, sum(g.copie_r) cr, sum(g.netto_f) nf, sum(g.netto_r) nr, sum(g.lordo_f) lf, sum(g.lordo_r) lr
    from public.msg_titolo_mese g join public.msg_titoli t on t.ean = g.ean
    where g.mese = any(v_mesi) and (p_editori is null or t.editore = any(p_editori)) and (p_ean is null or g.ean = p_ean)
    group by 1
    union all
    select public._msg_tipo(g.lancio, g.data, t.data_uscita), sum(g.copie_f), sum(g.copie_r), sum(g.netto_f), sum(g.netto_r), sum(g.lordo_f), sum(g.lordo_r)
    from public.msg_titolo_giorno g join public.msg_titoli t on t.ean = g.ean
    where g.data = any(v_giorni) and (p_editori is null or t.editore = any(p_editori)) and (p_ean is null or g.ean = p_ean)
    group by 1
  ) y group by 1;
end $function$;

create or replace function public.msg_analisi_tipi_titoli(p_date date[], p_editori text[] default null, p_ean text default null, p_clienti text[] default null)
returns table(tipo text, titoli_f bigint, titoli_r bigint)
language plpgsql stable security definer set search_path to 'public' set plan_cache_mode to 'force_custom_plan'
as $function$
#variable_conflict use_column
declare v_mesi date[]; v_giorni date[];
begin
  if not public._is_admin_pde() or p_clienti is not null then return; end if;
  select d.mesi, d.giorni into v_mesi, v_giorni from public._msg_dividi_date(p_date) d;
  return query
  with s as (select t.ean e, t.data_uscita du from public.msg_titoli t
             where (p_editori is null or t.editore = any(p_editori)) and (p_ean is null or t.ean = p_ean)),
  y as (
    select case when g.tipo = 'lancio' then 'lancio'
        when s.du is not null and g.mese < make_date(extract(year from s.du)::int + 1, 1, 1) then 'novita' else 'classico' end tp,
      g.ean e, g.copie_f cf, g.copie_r cr
    from public.msg_titolo_mese g join s on s.e = g.ean where g.mese = any(v_mesi)
    union all
    select public._msg_tipo(g.lancio, g.data, s.du), g.ean, g.copie_f, g.copie_r
    from public.msg_titolo_giorno g join s on s.e = g.ean where g.data = any(v_giorni)
  ), z as (select y.tp, y.e, sum(y.cf) cf, sum(y.cr) cr from y group by 1, 2)
  select z.tp, count(*) filter (where z.cf > 0), count(*) filter (where z.cr > 0) from z group by 1;
end $function$;

create or replace function public.msg_analisi_novita_senza_yba3(p_date date[], p_editori text[] default null,
  p_ean text default null, p_clienti text[] default null)
returns table(ean text, titolo text, editore text, collana text, prezzo numeric, copie_f bigint, copie_r bigint,
  netto_f numeric, netto_r numeric, lordo_f numeric, lordo_r numeric)
language plpgsql stable security definer set search_path to 'public' set plan_cache_mode to 'force_custom_plan'
as $function$
#variable_conflict use_column
declare v_mesi date[]; v_giorni date[];
begin
  if not public._is_admin_pde() or p_clienti is not null then return; end if;
  select d.mesi, d.giorni into v_mesi, v_giorni from public._msg_dividi_date(p_date) d;
  return query
  with s as (
    select t.ean e, t.titolo ti, t.editore ed, t.collana co, t.prezzo_copertina pr, make_date(extract(year from t.data_uscita)::int + 1, 1, 1) fine
    from public.msg_titoli t
    where t.primo_lancio is null and t.data_uscita is not null
      and not exists (select 1 from public.msg_uscite_storico u where u.ean = t.ean)
      and (p_editori is null or t.editore = any(p_editori)) and (p_ean is null or t.ean = p_ean)
  ), y as (
    select g.ean e, g.copie_f cf, g.copie_r cr, g.netto_f nf, g.netto_r nr, g.lordo_f lf, g.lordo_r lr
    from public.msg_titolo_mese g join s on s.e = g.ean
    where g.mese = any(v_mesi) and g.tipo <> 'lancio' and g.mese < s.fine
    union all
    select g.ean, g.copie_f, g.copie_r, g.netto_f, g.netto_r, g.lordo_f, g.lordo_r
    from public.msg_titolo_giorno g join s on s.e = g.ean
    where g.data = any(v_giorni) and not g.lancio and g.data < s.fine
  )
  select s.e, s.ti, s.ed, s.co, s.pr, sum(y.cf)::bigint, sum(y.cr)::bigint, sum(y.nf), sum(y.nr), sum(y.lf), sum(y.lr)
  from y join s on s.e = y.e
  group by s.e, s.ti, s.ed, s.co, s.pr;
end $function$;

create or replace function public.msg_analisi_clienti(p_date date[], p_livello text default 'canale', p_editori text[] default null, p_ean text default null, p_clienti text[] default null)
returns table(chiave text, nome text, dettaglio text, clienti bigint, copie_f bigint, copie_r bigint, netto_f numeric, netto_r numeric, lordo_f numeric, lordo_r numeric)
language plpgsql stable security definer set search_path to 'public' set plan_cache_mode to 'force_custom_plan'
as $function$
declare solo_clienti boolean := p_editori is null and p_ean is null; v_mesi date[] := '{}'; v_giorni date[] := '{}';
begin
  if not public._is_admin_pde() then return; end if;
  if solo_clienti then select d.mesi, d.giorni into v_mesi, v_giorni from public._msg_dividi_date(p_date) d; end if;
  -- Prima i totali per cliente (riepiloghi per mese e per giorno, o movimenti se c'è un filtro su editori o titolo), poi il livello scelto
  return query
  with q as (
    select c.codice_cliente cc, sum(c.copie_f) cf, sum(c.copie_r) cr, sum(c.netto_f) nf, sum(c.netto_r) nr, sum(c.lordo_f) lf, sum(c.lordo_r) lr
    from public.msg_cliente_mese c
    where solo_clienti and c.mese = any(v_mesi) and (p_clienti is null or c.codice_cliente = any(p_clienti)) group by 1
    union all
    select c.codice_cliente, sum(c.copie_f), sum(c.copie_r), sum(c.netto_f), sum(c.netto_r), sum(c.lordo_f), sum(c.lordo_r)
    from public.msg_cliente_giorno c
    where solo_clienti and c.data = any(v_giorni) and (p_clienti is null or c.codice_cliente = any(p_clienti)) group by 1
    union all
    select m.codice_cliente,
      coalesce(sum(m.copie) filter (where m.movimento = 'F'), 0), coalesce(sum(m.copie) filter (where m.movimento = 'R'), 0),
      coalesce(sum(m.netto) filter (where m.movimento = 'F'), 0), coalesce(sum(m.netto) filter (where m.movimento = 'R'), 0),
      coalesce(sum(m.lordo) filter (where m.movimento = 'F'), 0), coalesce(sum(m.lordo) filter (where m.movimento = 'R'), 0)
    from public.msg_movimenti m join public.msg_titoli t on t.ean = m.ean
    where not solo_clienti and m.data = any(p_date) and (p_clienti is null or m.codice_cliente = any(p_clienti))
      and (p_editori is null or t.editore = any(p_editori)) and (p_ean is null or m.ean = p_ean)
    group by 1
  ), p as (
    select q.cc, sum(q.cf) cf, sum(q.cr) cr, sum(q.nf) nf, sum(q.nr) nr, sum(q.lf) lf, sum(q.lr) lr from q group by q.cc
  )
  select k.ch, min(k.nm), min(k.dt), count(*)::bigint, sum(k.cf)::bigint, sum(k.cr)::bigint, sum(k.nf), sum(k.nr), sum(k.lf), sum(k.lr)
  from (
    select case p_livello when 'cliente' then g.codice_cliente when 'gruppo' then g.gruppo when 'categoria' then g.categoria else g.canale_gruppo end ch,
      case p_livello when 'cliente' then coalesce(g.ragione_sociale, g.codice_cliente) when 'gruppo' then g.gruppo when 'categoria' then g.categoria else g.canale_gruppo end nm,
      case p_livello when 'cliente' then concat_ws(' · ', nullif(trim(concat(g.citta, ' ', g.provincia)), ''), g.gruppo)
        when 'gruppo' then g.categoria when 'categoria' then g.canale_gruppo end dt,
      p.cf, p.cr, p.nf, p.nr, p.lf, p.lr
    from p join public.msg_clienti_gruppo g on g.codice_cliente = p.cc
  ) k
  group by k.ch
  order by sum(k.lf) desc
  limit 3000;
end $function$;

create or replace function public.msg_analisi_codici_editori()
returns table(editore text, codice text, titoli bigint)
language plpgsql stable security definer set search_path to 'public'
as $function$
#variable_conflict use_column
begin
  if not public._is_admin_pde() then return; end if;
  return query select t.editore, t.codice_editore, count(*)::bigint from public.msg_titoli t
    where t.editore is not null and t.codice_editore is not null group by 1, 2;
end $function$;
