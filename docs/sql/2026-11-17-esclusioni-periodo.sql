-- 2026-11-17 · Esclusioni cliente per editore con un periodo
--
-- Richiesta dell'utente del 17/11: per ALPHA TEST (e ALPHA TEST TU, stesso codice Messaggerie 305) sono esclusi i
-- clienti dei canali Giunti al Punto e Mondadori (gruppi Mondadori Retail, Mondadori Franch. e Bol Mondolibri),
-- SOLO nel 2025. Le regole Amazon dei 5 editori restano senza limiti di data.
--
-- msg_esclusioni_cliente ha ora dal / al (null = senza limite). Le cambiano:
--  * _msg_esclusi_calcola (file con i movimenti nel database): filtra la data del movimento;
--  * msg_esclusioni_regole (pagina, DuckDB sui Parquet): ogni riga ha dal / al;
--  * msg_esclusioni_piano (scripts/esclusioni.py, file solo in Parquet): un gruppo per canale e periodo, con dal / al.
--    Va pubblicato insieme a scripts/esclusioni.py aggiornato: lo script vecchio ignorerebbe il periodo.
-- Il riallineamento dello storico è quello di sempre: script del mattino per i Parquet, pg_cron msg-esclusioni di notte.
-- Si lancia anche di giorno: cambia solo regole e funzioni, il lavoro vero parte di notte.

alter table public.msg_esclusioni_cliente add column if not exists dal date, add column if not exists al date;

insert into public.msg_esclusioni_cliente (editore, canale, dal, al) values
  ('ALPHA TEST', 'Giunti al Punto', '2025-01-01', '2025-12-31'), ('ALPHA TEST', 'Mondadori', '2025-01-01', '2025-12-31'),
  ('ALPHA TEST TU', 'Giunti al Punto', '2025-01-01', '2025-12-31'), ('ALPHA TEST TU', 'Mondadori', '2025-01-01', '2025-12-31')
on conflict (editore, canale) do update set dal = excluded.dal, al = excluded.al;

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
                 where x.editore = t.editore and c.codice_cliente = m.codice_cliente
                   and (x.dal is null or m.data >= x.dal) and (x.al is null or m.data <= x.al)));
$function$;

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
    'clienti', coalesce((select jsonb_agg(jsonb_build_object('editore', x.editore, 'codice_cliente', c.codice_cliente, 'dal', x.dal, 'al', x.al)
        order by x.editore, c.codice_cliente)
      from public.msg_esclusioni_cliente x join public.msg_clienti_gruppo c on c.canale = x.canale), '[]'));
end $function$;

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
    'clienti', coalesce((select jsonb_agg(jsonb_build_object('canale', x.canale, 'dal', x.dal, 'al', x.al,
        'ean', (select jsonb_agg(t.ean) from public.msg_titoli t join public.msg_esclusioni_cliente y on y.editore = t.editore
                where y.canale = x.canale and y.dal is not distinct from x.dal and y.al is not distinct from x.al),
        'clienti', (select jsonb_agg(c.codice_cliente) from public.msg_clienti_gruppo c where c.canale = x.canale)))
      from (select distinct canale, dal, al from public.msg_esclusioni_cliente) x), '[]'),
    'file', coalesce((select jsonb_agg(jsonb_build_object('file', i.file, 'nome_file', i.nome_file, 'percorso', i.parquet_percorso,
        'righe', coalesce(s.righe, 0), 'copie', coalesce(s.copie, 0), 'lordo_cent', coalesce(s.lordo_cent, 0)) order by i.file)
      from public.msg_importazioni i
      left join (select e.file, count(*) righe, sum(e.copie) copie, sum(round(e.lordo * 100))::bigint lordo_cent
                 from public.msg_esclusi e group by e.file) s on s.file = i.file
      where i.stato = 'completata' and not i.movimenti_in_db and i.parquet_il is not null), '[]'));
end $function$;
