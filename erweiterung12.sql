-- ═══════════════════════════════════════════════════════════════════
-- Lachwerk – Erweiterung 12: anonyme Besucherzählung (ohne Cookies, ohne Geräte-Kennung)
-- Eindeutige Besucher werden über einen Hash aus IP-Adresse, Browser-Kennung und einem
-- täglich wechselnden Zufallswert erkannt. Die Hashes werden nach einem Tag gelöscht,
-- die IP-Adresse wird nie gespeichert. Mehrfach ausführen ist unschädlich.
-- ═══════════════════════════════════════════════════════════════════

-- Tageswerte und Aufschlüsselung (nur Zahlen, keine personenbezogenen Daten)
create table if not exists public.visit_daily (
  day      date primary key,
  uniques  int not null default 0,
  views    int not null default 0
);
create table if not exists public.visit_breakdown (
  day    date not null,
  kind   text not null check (kind in ('route', 'source', 'device')),
  label  text not null,
  views  int  not null default 0,
  primary key (day, kind, label)
);
-- Kurzlebig: Tages-Hashes für „schon gezählt?“ (werden nach einem Tag gelöscht)
create table if not exists public.visit_seen (
  day    date not null,
  vhash  text not null,
  views  int  not null default 0,
  primary key (day, vhash)
);
alter table public.visit_daily enable row level security;
alter table public.visit_breakdown enable row level security;
alter table public.visit_seen enable row level security;

create or replace function public.track_view(p_route text, p_source text default null, p_device text default null) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  d      date := (now() at time zone 'Europe/Berlin')::date;
  hdr    json := nullif(current_setting('request.headers', true), '')::json;
  ip     text := coalesce(trim(split_part(hdr ->> 'x-forwarded-for', ',', 1)), '');
  ua     text := coalesce(hdr ->> 'user-agent', '');
  salt   text;
  h      text;
  v_new  boolean;
  v_cnt  int;
  r      text := case when p_route in ('list', 'new', 'swipe', 'duel', 'highlights', 'authors', 'detail', 'profile', 'groups', 'group',
                                       'search', 'screen', 'tv', 'live', 'challenge') then p_route else 'andere' end;
  s      text := case when p_source in ('direkt', 'whatsapp', 'google', 'qr', 'facebook', 'instagram', 'andere') then p_source else 'direkt' end;
  dev    text := case when p_device in ('mobil', 'tablet', 'computer') then p_device else 'computer' end;
begin
  -- Suchmaschinen-Bots und automatisierte Browser nicht mitzählen
  if ua ~* '(bot|crawl|spider|slurp|headless|lighthouse|preview|facebookexternalhit|whatsapp)' then return; end if;

  -- Zufallswert des Tages (gestrige werden gelöscht)
  select x.value into salt from public.settings x where x.key = 'visit_salt_' || d::text;
  if salt is null then
    insert into public.settings (key, value) values ('visit_salt_' || d::text, encode(gen_random_bytes(24), 'hex'))
    on conflict (key) do nothing;
    select x.value into salt from public.settings x where x.key = 'visit_salt_' || d::text;
    delete from public.settings x where x.key like 'visit_salt_%' and x.key <> 'visit_salt_' || d::text;
    delete from public.visit_seen x where x.day < d;
  end if;
  h := encode(digest(ip || '|' || ua || '|' || salt, 'sha256'), 'hex');

  insert into public.visit_seen as v (day, vhash, views) values (d, h, 1)
  on conflict (day, vhash) do update set views = v.views + 1
  returning (xmax = 0), v.views into v_new, v_cnt;
  if v_cnt > 300 then return; end if;   -- Schutz vor Dauer-Neuladen

  insert into public.visit_daily as t (day, uniques, views) values (d, 1, 1)
  on conflict (day) do update set views = t.views + 1, uniques = t.uniques + case when v_new then 1 else 0 end;
  insert into public.visit_breakdown as b (day, kind, label, views)
  values (d, 'route', r, 1), (d, 'device', dev, case when v_new then 1 else 0 end), (d, 'source', s, case when v_new then 1 else 0 end)
  on conflict (day, kind, label) do update set views = b.views + excluded.views;
end $$;

-- Admin: Tageswerte und Aufschlüsselung
create or replace function public.admin_visits(p_key text, p_days int default 14)
returns table (day date, uniques int, views int)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.admin_check(p_key) then raise exception 'not_admin'; end if;
  return query
    select g.day::date, coalesce(v.uniques, 0), coalesce(v.views, 0)
    from generate_series((now() at time zone 'Europe/Berlin')::date - (least(greatest(p_days, 1), 90) - 1),
                         (now() at time zone 'Europe/Berlin')::date, interval '1 day') as g(day)
    left join public.visit_daily v on v.day = g.day::date
    order by 1;
end $$;

create or replace function public.admin_visit_breakdown(p_key text, p_days int default 7)
returns table (kind text, label text, views int)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.admin_check(p_key) then raise exception 'not_admin'; end if;
  return query
    select b.kind, b.label, sum(b.views)::int
    from public.visit_breakdown b
    where b.day > (now() at time zone 'Europe/Berlin')::date - least(greatest(p_days, 1), 90)
    group by b.kind, b.label
    order by b.kind, 3 desc;
end $$;

-- ───────────────────────── Rechte ─────────────────────────
revoke all on public.visit_daily, public.visit_breakdown, public.visit_seen from anon, authenticated;
revoke execute on function public.track_view(text, text, text), public.admin_visits(text, int), public.admin_visit_breakdown(text, int) from public;
grant execute on function public.track_view(text, text, text), public.admin_visits(text, int), public.admin_visit_breakdown(text, int) to anon, authenticated;
grant execute on all functions in schema public to service_role;
grant all on all tables in schema public to service_role;
