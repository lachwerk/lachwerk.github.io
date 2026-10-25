-- ═══════════════════════════════════════════════════════════════════
-- Lachwerk – Erweiterung 7: Kurzlinks für Bildschirme (lachwerk.github.io/tv/CODE)
-- Setzt erweiterung.sql bis erweiterung6.sql voraus. Mehrfach ausführen ist unschädlich.
-- ═══════════════════════════════════════════════════════════════════

-- Gespeichert werden nur die Einstellungen des Bildschirm-Links (Format, Farben, Kategorien …)
create table if not exists public.tv_screens (
  code        text primary key check (code ~ '^[2-9A-HJKMNP-Z]{5}$'),
  config      jsonb not null check (jsonb_typeof(config) = 'object' and length(config::text) <= 600),
  ip_hash     text,
  created_at  timestamptz not null default now(),
  last_seen   timestamptz
);
alter table public.tv_screens enable row level security;

-- Neuen Kurzlink anlegen. Gleiche Einstellungen ergeben denselben Code; höchstens 30 neue pro Anschluss und Tag.
create or replace function public.save_tv_screen(p_config jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare
  h      text := public.client_ip_hash();
  v_cfg  jsonb;
  v_code text;
  abc    constant text := '23456789ABCDEFGHJKMNPQRSTUVWXYZ';
begin
  if p_config is null or jsonb_typeof(p_config) <> 'object' then raise exception 'invalid_config'; end if;
  -- nur bekannte Felder, jeweils als kurzer Text
  select coalesce(jsonb_object_agg(k, left(v, 120)), '{}'::jsonb) into v_cfg
  from (select key k, p_config ->> key v from jsonb_object_keys(p_config) key) x
  where k in ('f', 'dreh', 'bg', 'ac', 'card', 'k', 'n', 's', 't') and v is not null and v <> '';
  if length(v_cfg::text) > 600 then raise exception 'invalid_config'; end if;

  select s.code into v_code from public.tv_screens s where s.config = v_cfg limit 1;
  if v_code is not null then return v_code; end if;

  if (select count(*) from public.tv_screens s where s.ip_hash = h and s.created_at > now() - interval '1 day') >= 30 then
    raise exception 'rate_limited';
  end if;
  loop
    v_code := (select string_agg(substr(abc, 1 + floor(random() * length(abc))::int, 1), '') from generate_series(1, 5));
    begin
      insert into public.tv_screens (code, config, ip_hash) values (v_code, v_cfg, h);
      return v_code;
    exception when unique_violation then null; -- Code schon vergeben, neu würfeln
    end;
  end loop;
end $$;

-- Einstellungen zu einem Kurzlink lesen (Groß-/Kleinschreibung egal)
create or replace function public.get_tv_screen(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_cfg jsonb;
begin
  update public.tv_screens s set last_seen = now()
  where s.code = upper(trim(p_code)) and (s.last_seen is null or s.last_seen < now() - interval '1 hour');
  select s.config into v_cfg from public.tv_screens s where s.code = upper(trim(p_code));
  return v_cfg;
end $$;

-- ───────────────────────── Rechte ─────────────────────────
revoke all on public.tv_screens from anon, authenticated;
revoke execute on function public.save_tv_screen(jsonb), public.get_tv_screen(text) from public;
grant execute on function public.save_tv_screen(jsonb), public.get_tv_screen(text) to anon, authenticated;
-- Konto löschen nur für angemeldete Nutzer aufrufbar (Supabase gibt neuen Funktionen sonst auch „anon“)
revoke execute on function public.delete_my_account(boolean) from anon;
grant execute on all functions in schema public to service_role;
grant all on all tables in schema public to service_role;
