-- ═══════════════════════════════════════════════════════════════════
-- Lachwerk – Erweiterung 14: Wortfilter speichern repariert, Liste ergänzt
-- Supabase lehnt über die App ein „delete“ ohne „where“ ab (Schutz safeupdate).
-- Darum schlug „Speichern“ im Wortfilter fehl. Mehrfach ausführen ist unschädlich.
-- ═══════════════════════════════════════════════════════════════════

create or replace function public.admin_set_words(p_key text, p_words text[])
returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not public.admin_check(p_key) then raise exception 'not_admin'; end if;
  delete from public.banned_words where true;
  insert into public.banned_words (word)
  select distinct lower(trim(w)) from unnest(coalesce(p_words, '{}')) w
  where lower(trim(w)) ~ '^[[:alnum:]äöüß]{2,40}\*?$'
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

-- Ergänzungen (vorhandene Wörter bleiben, Doppelte werden übersprungen)
insert into public.banned_words (word)
select unnest(array[
  -- vom Admin gewünscht
  'nazi*', 'hitler', 'adolf',
  -- Beleidigungen
  'hure*', 'wichser*', 'wixer', 'wixxer', 'fotze*', 'missgeburt*', 'spacko*', 'spacken', 'schwanzlutscher',
  -- abwertend gegen Gruppen
  'schwuchtel*', 'tunte*', 'transe', 'kanacke*', 'nigger*', 'nigga*', 'bimbo*', 'schlitzauge*', 'kümmeltürk*',
  'kameltreiber*', 'polacke*', 'judenschwein*', 'mongoloid*', 'krüppel*',
  -- NS-Bezug und Gewalt
  'untermensch*', 'endlösung', 'hakenkreuz*', 'auschwitz*', 'vergewaltig*', 'kinderficker*', 'kinderschänder*', 'pädo*'
]) on conflict do nothing;

grant execute on function public.admin_set_words(text, text[]) to anon, authenticated;
