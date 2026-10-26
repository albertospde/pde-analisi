-- Numero di titoli per tipo (lancio / novita / classico) in Lanci e rifornimenti: la pagina lo chiede solo
-- quando si apre il "+" di una riga. titoli_f = titoli con copie fornite, titoli_r = con copie rese.
-- Con il filtro clienti la pagina calcola dai Parquet (DuckDB).

create or replace function public.msg_analisi_tipi_titoli(p_date date[], p_editori text[] default null,
  p_ean text default null, p_clienti text[] default null)
returns table(tipo text, titoli_f bigint, titoli_r bigint)
language plpgsql stable security definer
set search_path to 'public' set plan_cache_mode to 'force_custom_plan'
as $function$
#variable_conflict use_column
declare v_mesi date[]; v_giorni date[];
begin
  if not public._is_admin_pde() or p_clienti is not null then return; end if;
  select d.mesi, d.giorni into v_mesi, v_giorni from public._msg_dividi_date(p_date) d;
  if p_editori is null and p_ean is null then
    return query
    with y as (
      select g.tipo tp, g.ean e, g.copie_f cf, g.copie_r cr from public.msg_titolo_mese g where g.mese = any(v_mesi)
      union all
      select public._msg_tipo(g.lancio, g.data, t.data_uscita), g.ean, g.copie_f, g.copie_r
      from public.msg_titolo_giorno g join public.msg_titoli t on t.ean = g.ean where g.data = any(v_giorni)
    ), z as (select y.tp, y.e, sum(y.cf) cf, sum(y.cr) cr from y group by 1, 2)
    select z.tp, count(*) filter (where z.cf > 0), count(*) filter (where z.cr > 0) from z group by 1;
  else
    return query
    with s as (select t.ean e, t.data_uscita du from public.msg_titoli t
               where (p_editori is null or t.editore = any(p_editori)) and (p_ean is null or t.ean = p_ean)),
    y as (
      select g.tipo tp, g.ean e, g.copie_f cf, g.copie_r cr from public.msg_titolo_mese g join s on s.e = g.ean where g.mese = any(v_mesi)
      union all
      select public._msg_tipo(g.lancio, g.data, s.du), g.ean, g.copie_f, g.copie_r
      from public.msg_titolo_giorno g join s on s.e = g.ean where g.data = any(v_giorni)
    ), z as (select y.tp, y.e, sum(y.cf) cf, sum(y.cr) cr from y group by 1, 2)
    select z.tp, count(*) filter (where z.cf > 0), count(*) filter (where z.cr > 0) from z group by 1;
  end if;
end $function$;
