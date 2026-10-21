-- PDE Analisi · Lanci e rifornimenti più veloce (21/10/2026)
-- Senza filtro editore o titolo il calcolo usa i riepiloghi per cliente (tipo già calcolato,
-- ~1.500 righe al giorno, nessun join) invece di quelli per titolo (~5.000 righe al giorno, join
-- con msg_titoli e _msg_tipo riga per riga). Ottobre 2025 a memoria fredda: da oltre 8 s a 2,4 s.
create or replace function public.msg_analisi_tipi(p_date date[], p_editori text[] default null, p_ean text default null, p_clienti text[] default null)
returns table(tipo text, copie_f bigint, copie_r bigint, netto_f numeric, netto_r numeric, lordo_f numeric, lordo_r numeric)
language plpgsql stable security definer set search_path to 'public' set plan_cache_mode to 'force_custom_plan'
as $function$
declare v_mesi date[]; v_giorni date[];
begin
  if not public._is_admin_pde() then return; end if;
  select d.mesi, d.giorni into v_mesi, v_giorni from public._msg_dividi_date(p_date) d;
  if p_editori is null and p_ean is null then
    -- Tutti i clienti o quelli scelti: riepiloghi per cliente (mesi interi dal mensile, giorni sparsi dal giornaliero)
    return query select y.tp, sum(y.cf)::bigint, sum(y.cr)::bigint, sum(y.nf), sum(y.nr), sum(y.lf), sum(y.lr) from (
      select c.tipo tp, sum(c.copie_f) cf, sum(c.copie_r) cr, sum(c.netto_f) nf, sum(c.netto_r) nr, sum(c.lordo_f) lf, sum(c.lordo_r) lr
      from public.msg_cliente_mese c where c.mese = any(v_mesi) and (p_clienti is null or c.codice_cliente = any(p_clienti)) group by 1
      union all
      select c.tipo, sum(c.copie_f), sum(c.copie_r), sum(c.netto_f), sum(c.netto_r), sum(c.lordo_f), sum(c.lordo_r)
      from public.msg_cliente_giorno c where c.data = any(v_giorni) and (p_clienti is null or c.codice_cliente = any(p_clienti)) group by 1
    ) y group by 1;
  elsif p_clienti is null then
    -- Filtro editore o titolo: riepiloghi per titolo
    return query select y.tp, sum(y.cf)::bigint, sum(y.cr)::bigint, sum(y.nf), sum(y.nr), sum(y.lf), sum(y.lr) from (
      select g.tipo tp, sum(g.copie_f) cf, sum(g.copie_r) cr, sum(g.netto_f) nf, sum(g.netto_r) nr, sum(g.lordo_f) lf, sum(g.lordo_r) lr
      from public.msg_titolo_mese g join public.msg_titoli t on t.ean = g.ean
      where g.mese = any(v_mesi) and (p_editori is null or t.editore = any(p_editori)) and (p_ean is null or g.ean = p_ean)
      group by 1
      union all
      select public._msg_tipo(g.lancio, g.data, t.data_uscita), sum(g.copie_f), sum(g.copie_r), sum(g.netto_f), sum(g.netto_r), sum(g.lordo_f), sum(g.lordo_r)
      from public.msg_titolo_giorno g join public.msg_titoli t on t.ean = g.ean
      where g.data = any(v_giorni) and (p_editori is null or t.editore = any(p_editori)) and (p_ean is null or g.ean = p_ean)
      group by 1
    ) y group by 1;
  else
    -- Clienti e editore/titolo insieme: movimenti
    return query select public._msg_tipo(m.lancio, m.data, t.data_uscita),
      coalesce(sum(m.copie) filter (where m.movimento = 'F'), 0)::bigint, coalesce(sum(m.copie) filter (where m.movimento = 'R'), 0)::bigint,
      coalesce(sum(m.netto) filter (where m.movimento = 'F'), 0), coalesce(sum(m.netto) filter (where m.movimento = 'R'), 0),
      coalesce(sum(m.lordo) filter (where m.movimento = 'F'), 0), coalesce(sum(m.lordo) filter (where m.movimento = 'R'), 0)
      from public.msg_movimenti m join public.msg_titoli t on t.ean = m.ean
      where m.data = any(p_date) and m.codice_cliente = any(p_clienti)
        and (p_editori is null or t.editore = any(p_editori)) and (p_ean is null or m.ean = p_ean)
      group by 1;
  end if;
end $function$;
