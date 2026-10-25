-- ═══════════════════════════════════════════════════════════════════
-- Lachwerk – Erweiterung 4: Sponsoren und Kontakt für die Partnerseite
-- Setzt erweiterung.sql bis erweiterung3.sql voraus.
--
-- Für eine SCHON eingerichtete Datenbank: einmal komplett im Supabase SQL Editor
-- ausführen (Run). Mehrfach ausführen ist unschädlich.
-- Bei einer Neueinrichtung nicht nötig: supabase.sql enthält diesen Teil bereits.
-- ═══════════════════════════════════════════════════════════════════

-- ───────────────────────── Sponsoren ─────────────────────────
-- Platzierungen: daily (Witz des Tages inkl. Story-Bild), battle, challenge, list (Bestenliste), tv (Bildschirm-Modus)
-- Das Logo wird als kleines Bild direkt gespeichert (keine fremden Server, kein Tracking).
create table if not exists public.sponsors (
  id          serial primary key,
  name        text not null check (char_length(name) between 2 and 60),
  claim       text not null default '' check (char_length(claim) <= 120),
  url         text not null default '' check (url = '' or url ~ '^https?://'),
  logo        text not null default '' check (logo = '' or (logo ~ '^data:image/(png|jpeg|webp);base64,' and char_length(logo) <= 150000)),
  placement   text not null check (placement in ('daily', 'battle', 'challenge', 'list', 'tv')),
  starts_at   timestamptz not null default now(),
  ends_at     timestamptz not null,
  clicks      int not null default 0,
  created_at  timestamptz not null default now(),
  check (ends_at > starts_at)
);
create index if not exists sponsors_active on public.sponsors (placement, starts_at, ends_at);

-- Aktuell laufende Sponsoren (pro Platzierung der zuletzt gestartete)
create or replace function public.get_sponsors()
returns table (id int, name text, claim text, url text, logo text, placement text)
language sql stable security definer set search_path = public as $$
  select distinct on (s.placement) s.id, s.name, s.claim, s.url, s.logo, s.placement
  from public.sponsors s
  where now() >= s.starts_at and now() < s.ends_at
  order by s.placement, s.starts_at desc
$$;

-- Ein bestimmter laufender Sponsor (für Firmen-Bildschirme mit eigenem Branding)
create or replace function public.get_sponsor(p_id int)
returns table (id int, name text, claim text, url text, logo text, placement text)
language sql stable security definer set search_path = public as $$
  select s.id, s.name, s.claim, s.url, s.logo, s.placement from public.sponsors s
  where s.id = p_id and now() >= s.starts_at and now() < s.ends_at
$$;

-- Klick zählen (nur eine Zahl, keine Daten über die Person)
create or replace function public.sponsor_click(p_id int) returns void
language sql security definer set search_path = public as $$
  update public.sponsors s set clicks = s.clicks + 1 where s.id = p_id and now() >= s.starts_at and now() < s.ends_at
$$;

create or replace function public.admin_sponsors(p_key text)
returns table (id int, name text, claim text, url text, logo text, placement text, starts_at timestamptz, ends_at timestamptz,
               clicks int, active boolean)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not public.admin_check(p_key) then raise exception 'not_admin'; end if;
  return query
    select s.id, s.name, s.claim, s.url, s.logo, s.placement, s.starts_at, s.ends_at, s.clicks,
           now() >= s.starts_at and now() < s.ends_at
    from public.sponsors s order by (now() < s.ends_at) desc, s.starts_at desc limit 200;
end $$;

-- Anlegen (p_id null) oder ändern
create or replace function public.admin_save_sponsor(p_key text, p_id int, p_name text, p_claim text, p_url text, p_logo text,
                                                     p_placement text, p_starts timestamptz, p_ends timestamptz)
returns int
language plpgsql security definer set search_path = public as $$
declare v_id int;
begin
  if not public.admin_check(p_key) then raise exception 'not_admin'; end if;
  if p_starts is null or p_ends is null or p_ends <= p_starts then raise exception 'invalid_value'; end if;
  if p_id is null then
    insert into public.sponsors (name, claim, url, logo, placement, starts_at, ends_at)
    values (trim(p_name), trim(coalesce(p_claim, '')), trim(coalesce(p_url, '')), coalesce(p_logo, ''), p_placement, p_starts, p_ends)
    returning sponsors.id into v_id;
  else
    update public.sponsors s set name = trim(p_name), claim = trim(coalesce(p_claim, '')), url = trim(coalesce(p_url, '')),
           logo = coalesce(p_logo, ''), placement = p_placement, starts_at = p_starts, ends_at = p_ends
    where s.id = p_id returning s.id into v_id;
    if v_id is null then raise exception 'invalid_value'; end if;
  end if;
  return v_id;
exception when check_violation then
  raise exception 'invalid_sponsor';
end $$;

create or replace function public.admin_delete_sponsor(p_key text, p_id int) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.admin_check(p_key) then raise exception 'not_admin'; end if;
  delete from public.sponsors s where s.id = p_id;
end $$;

-- ───────────────────────── Kontakt für die Partnerseite ─────────────────────────
create or replace function public.get_contact() returns text
language sql stable security definer set search_path = public as $$
  select nullif(trim(s.value), '') from public.settings s where s.key = 'contact_email'
$$;

create or replace function public.admin_set_contact(p_key text, p_email text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.admin_check(p_key) then raise exception 'not_admin'; end if;
  if coalesce(trim(p_email), '') <> '' and trim(p_email) !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then raise exception 'invalid_email'; end if;
  insert into public.settings (key, value) values ('contact_email', trim(coalesce(p_email, '')))
  on conflict (key) do update set value = excluded.value;
end $$;

-- ───────────────────────── Weitere Admins ─────────────────────────
-- Konten mit der Rolle 'admin' haben vollen Zugriff auf den Admin-Bereich, ohne den Admin-Schlüssel.
-- Rollen vergeben und entziehen kann nur, wer den Admin-Schlüssel hat (Inhaber).
alter table public.profiles add column if not exists role text check (role in ('admin'));

-- Prüft nur den Admin-Schlüssel (Inhaber)
create or replace function public.owner_check(p_key text) returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select char_length(coalesce(p_key, '')) >= 12
     and coalesce((select s.value = crypt(p_key, s.value) from public.settings s where s.key = 'admin_key'), false)
$$;

-- Admin-Schlüssel ODER angemeldetes Konto mit Admin-Rolle (nicht gesperrt)
create or replace function public.admin_check(p_key text) returns boolean
language sql stable security definer set search_path = public as $$
  select public.owner_check(p_key)
      or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin' and p.banned_at is null)
$$;

create or replace function public.admin_set_role(p_key text, p_username text, p_admin boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.owner_check(p_key) then raise exception 'owner_only'; end if;
  update public.profiles p set role = case when p_admin then 'admin' else null end
  where lower(p.username) = lower(trim(p_username));
  if not found then raise exception 'user_not_found'; end if;
end $$;

-- Eigenes Profil: zusätzlich Rolle
drop function if exists public.my_profile();
create function public.my_profile() returns table (username text, banned boolean, role text)
language sql stable security definer set search_path = public as $$
  select p.username, p.banned_at is not null, p.role from public.profiles p where p.id = auth.uid()
$$;

-- Nutzerliste: zusätzlich Rolle
drop function if exists public.admin_users(text, text, int);
create function public.admin_users(p_key text, p_query text default null, p_limit int default 100)
returns table (username text, created_at timestamptz, jokes int, up_count int, down_count int, punchlines int,
               reports int, last_activity timestamptz, banned_at timestamptz, ban_reason text, role text)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not public.admin_check(p_key) then raise exception 'not_admin'; end if;
  return query
    select p.username, p.created_at,
           (select count(*) from public.jokes j where j.author_user = p.id and j.status <> 'removed')::int,
           (select coalesce(sum(j.up_count), 0) from public.jokes j where j.author_user = p.id and j.status <> 'removed')::int,
           (select coalesce(sum(j.down_count), 0) from public.jokes j where j.author_user = p.id and j.status <> 'removed')::int,
           (select count(*) from public.battle_entries e where e.author_user = p.id and e.status = 'visible')::int,
           (select coalesce(sum(j.report_count), 0) from public.jokes j where j.author_user = p.id)::int,
           greatest((select max(j.created_at) from public.jokes j where j.author_user = p.id),
                    (select max(e.created_at) from public.battle_entries e where e.author_user = p.id)),
           p.banned_at, p.ban_reason, p.role
    from public.profiles p
    where coalesce(trim(p_query), '') = '' or p.username ilike '%' || trim(p_query) || '%'
    order by (p.role is not null) desc, p.created_at desc
    limit least(greatest(p_limit, 1), 500);
end $$;

-- Admins können sich nicht gegenseitig sperren, das darf nur der Inhaber
create or replace function public.admin_ban_user(p_key text, p_username text, p_ban boolean, p_reason text default null)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.admin_check(p_key) then raise exception 'not_admin'; end if;
  if not public.owner_check(p_key) and exists (select 1 from public.profiles p where lower(p.username) = lower(trim(p_username)) and p.role = 'admin') then
    raise exception 'owner_only';
  end if;
  update public.profiles p set banned_at = case when p_ban then now() else null end,
                               ban_reason = case when p_ban then nullif(trim(coalesce(p_reason, '')), '') else null end
  where lower(p.username) = lower(trim(p_username));
  if not found then raise exception 'user_not_found'; end if;
end $$;

-- ───────────────────────── Rechte ─────────────────────────
alter table public.sponsors enable row level security;
revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke execute on all functions in schema public from public, anon, authenticated;
grant select on public.categories to anon, authenticated;

grant execute on function
  public.get_ranking(uuid, text, text, int, int),
  public.get_joke(uuid, bigint),
  public.get_unrated(uuid, bigint[], int),
  public.get_unrated2(uuid, bigint[], int, text[]),
  public.find_similar(text),
  public.cast_vote(uuid, bigint, int),
  public.post_joke(uuid, text, text),
  public.post_joke(uuid, text, text, int),
  public.username_available(text),
  public.my_profile(),
  public.report_joke(uuid, bigint),
  public.admin_check(text),
  public.admin_list(text, text),
  public.admin_set_status(text, bigint, text),
  public.get_daily(uuid, int),
  public.set_reaction(uuid, bigint, text),
  public.get_reactions(uuid, bigint[]),
  public.get_reaction_top(uuid, text, int),
  public.get_duel(uuid),
  public.get_duel2(uuid, text[]),
  public.cast_duel(uuid, bigint, bigint),
  public.get_duel_ranking(uuid, int),
  public.get_author_ranking(text, int),
  public.get_profile(text),
  public.get_profile_jokes(uuid, text, int, int),
  public.my_highlights(),
  public.get_challenges(),
  public.get_challenge_ranking(uuid, int, int),
  public.get_battle_today(),
  public.get_battle_entries(uuid, int),
  public.get_battle_archive(int),
  public.post_punchline(uuid, int, text),
  public.vote_punchline(uuid, bigint, int),
  public.get_season_winners(int),
  public.get_announcement(),
  public.get_sponsors(),
  public.get_sponsor(int),
  public.sponsor_click(int),
  public.get_contact(),
  public.admin_save_challenge(text, int, text, text, timestamptz, timestamptz),
  public.admin_stats(text, int),
  public.admin_totals(text),
  public.admin_category_stats(text),
  public.admin_bulk_add(text, text, text[], int),
  public.admin_get_words(text),
  public.admin_set_words(text, text[]),
  public.admin_add_prompts(text, text[]),
  public.admin_battle(text),
  public.admin_remove_punchline(text, bigint),
  public.admin_set_announcement(text, text),
  public.admin_overview(text),
  public.admin_activity(text, int),
  public.admin_search_jokes(text, text, text, text, text, int, int),
  public.admin_update_joke(text, bigint, text, text),
  public.admin_users(text, text, int),
  public.admin_ban_user(text, text, boolean, text),
  public.admin_remove_user_content(text, text),
  public.admin_top(text),
  public.admin_export(text),
  public.admin_sponsors(text),
  public.admin_save_sponsor(text, int, text, text, text, text, text, timestamptz, timestamptz),
  public.admin_delete_sponsor(text, int),
  public.admin_set_contact(text, text),
  public.admin_set_role(text, text, boolean)
to anon, authenticated;
