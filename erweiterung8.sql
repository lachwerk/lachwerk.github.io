-- ═══════════════════════════════════════════════════════════════════
-- Lachwerk – Erweiterung 8: Errate die Pointe, Live-Duell am Bildschirm, Gruppen
-- Setzt erweiterung.sql bis erweiterung7.sql voraus. Mehrfach ausführen ist unschädlich.
-- ═══════════════════════════════════════════════════════════════════

-- ───────────────────────── Errate die Pointe ─────────────────────────
-- Geeignet sind Witze mit Zeilenumbruch: alles davor ist der Anfang, die letzte Zeile die Pointe.
create or replace function public.quiz_pool()
returns table (id bigint, setup text, punch text, kind text, cat text, author text)
language sql stable security definer set search_path = public as $$
  select j.id, s.setup, s.punch,
         case when s.setup ~ '\?["“”«»]?\s*$' then 'q' else 'd' end,
         c.slug, j.author_name
  from public.jokes j
  join public.categories c on c.id = j.category_id
  cross join lateral (select trim(substring(j.body from '^(.*)\n[^\n]*$')) as setup,
                             trim(substring(j.body from '\n([^\n]*)$'))     as punch) s
  where j.status = 'visible' and s.punch is not null
    and char_length(s.punch) between 2 and 140 and char_length(s.setup) between 8 and 300
$$;

-- p_daily = true: für alle gleiches Tagesquiz (Datum in deutscher Zeit), sonst zufällig
create or replace function public.get_quiz(p_daily boolean default false, p_n int default 5, p_cats text[] default null)
returns table (id bigint, setup text, options text[], correct int, cat text, author text)
language sql volatile security definer set search_path = public as $$
  with pool as materialized (select * from public.quiz_pool()),
  seed as (select case when p_daily then 'tag-' || ((now() at time zone 'Europe/Berlin')::date)::text else random()::text end as k),
  picked as (
    select p.* from pool p, seed
    where p_daily or p_cats is null or p.cat = any(p_cats)
    order by md5(seed.k || p.id::text)
    limit least(greatest(coalesce(p_n, 5), 1), 20))
  select pk.id, pk.setup, o.opts, o.ok, pk.cat, pk.author
  from picked pk cross join seed
  cross join lateral (
    with d as (select q.punch from pool q
               where q.kind = pk.kind and q.id <> pk.id and lower(q.punch) <> lower(pk.punch)
               order by md5(seed.k || pk.id::text || '-' || q.id::text) limit 2),
    al as (select pk.punch as t, true as good union all select d.punch, false from d),
    ord as (select al.t, al.good, row_number() over (order by md5(seed.k || al.t)) as rn from al)
    select array_agg(ord.t order by ord.rn) as opts, (select o2.rn::int from ord o2 where o2.good) as ok from ord
  ) o
$$;

create table if not exists public.quiz_results (
  day        date not null,
  device_id  uuid not null,
  score      int  not null check (score between 0 and 20),
  created_at timestamptz not null default now(),
  primary key (day, device_id)
);
alter table public.quiz_results enable row level security;

-- Ergebnis des Tagesquiz melden (zählt nur das erste) und Vergleich zurückgeben
create or replace function public.submit_quiz(p_device uuid, p_score int)
returns table (players int, worse int, same int)
language plpgsql security definer set search_path = public as $$
declare d date := (now() at time zone 'Europe/Berlin')::date;
begin
  if p_device is null or p_score is null or p_score not between 0 and 5 then raise exception 'invalid_score'; end if;
  insert into public.quiz_results (day, device_id, score) values (d, p_device, p_score) on conflict do nothing;
  return query
    select count(*)::int,
           count(*) filter (where r.score < (select r2.score from public.quiz_results r2 where r2.day = d and r2.device_id = p_device))::int,
           count(*) filter (where r.score = (select r2.score from public.quiz_results r2 where r2.day = d and r2.device_id = p_device))::int
    from public.quiz_results r where r.day = d;
end $$;

-- ───────────────────────── Live-Duell am Bildschirm ─────────────────────────
create table if not exists public.live_rounds (
  id          bigint generated always as identity primary key,
  screen      text not null,
  joke_a      bigint not null references public.jokes on delete cascade,
  joke_b      bigint not null references public.jokes on delete cascade,
  started_at  timestamptz not null default now(),
  ends_at     timestamptz not null
);
create index if not exists live_rounds_screen on public.live_rounds (screen, id desc);
create table if not exists public.live_votes (
  round_id    bigint not null references public.live_rounds on delete cascade,
  device_id   uuid not null,
  choice      smallint not null check (choice in (1, 2)),
  created_at  timestamptz not null default now(),
  primary key (round_id, device_id)
);
alter table public.live_rounds enable row level security;
alter table public.live_votes enable row level security;

-- Aktuelle Runde eines Bildschirms. Mit p_start = true (nur der Bildschirm selbst) beginnt eine neue,
-- sobald die letzte seit 6 Sekunden vorbei ist.
create or replace function public.live_round(p_screen text, p_device uuid, p_start boolean default false, p_cats text[] default null)
returns table (id bigint, a_id bigint, a_text text, b_id bigint, b_text text, a_votes int, b_votes int,
               ends_at timestamptz, server_now timestamptz, my_choice smallint, finished boolean)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare
  v_screen text := upper(trim(coalesce(p_screen, '')));
  r public.live_rounds;
  a bigint; b bigint;
begin
  if v_screen !~ '^[2-9A-HJKMNP-Z]{5}$' then raise exception 'invalid_screen'; end if;
  if p_start then
    if not exists (select 1 from public.tv_screens s where s.code = v_screen) then raise exception 'invalid_screen'; end if;
    perform pg_advisory_xact_lock(hashtext('live-' || v_screen));
  end if;
  select * into r from public.live_rounds lr where lr.screen = v_screen order by lr.id desc limit 1;
  if p_start and (r.id is null or now() > r.ends_at + interval '6 seconds') then
    select x.id into a from (
      select f.id from public.joke_feed f
      where f.status = 'visible' and char_length(f.body) <= 220 and (p_cats is null or f.category_slug = any(p_cats))
      order by random() limit 2) x order by x.id limit 1;
    select x.id into b from (
      select f.id from public.joke_feed f
      where f.status = 'visible' and char_length(f.body) <= 220 and (p_cats is null or f.category_slug = any(p_cats)) and f.id <> a
      order by random() limit 1) x;
    if a is null or b is null then raise exception 'joke_not_found'; end if;
    insert into public.live_rounds (screen, joke_a, joke_b, ends_at) values (v_screen, a, b, now() + interval '45 seconds')
    returning * into r;
    delete from public.live_rounds lr where lr.started_at < now() - interval '2 days';
  end if;
  if r.id is null then return; end if;
  return query
    select r.id, r.joke_a, ja.body, r.joke_b, jb.body,
           (select count(*)::int from public.live_votes v where v.round_id = r.id and v.choice = 1),
           (select count(*)::int from public.live_votes v where v.round_id = r.id and v.choice = 2),
           r.ends_at, now(),
           (select v.choice from public.live_votes v where v.round_id = r.id and v.device_id = p_device),
           now() > r.ends_at
    from public.jokes ja, public.jokes jb where ja.id = r.joke_a and jb.id = r.joke_b;
end $$;

create or replace function public.live_vote(p_device uuid, p_round bigint, p_choice int) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_device is null or p_choice not in (1, 2) then raise exception 'invalid_vote'; end if;
  if not exists (select 1 from public.live_rounds r where r.id = p_round and now() <= r.ends_at + interval '2 seconds') then
    raise exception 'round_over';
  end if;
  insert into public.live_votes (round_id, device_id, choice) values (p_round, p_device, p_choice)
  on conflict (round_id, device_id) do update set choice = excluded.choice;
end $$;

-- Bildschirm-Kurzlinks: zusätzlich Live-Duell (live) und Gruppe (g)
create or replace function public.save_tv_screen(p_config jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare
  h      text := public.client_ip_hash();
  v_cfg  jsonb;
  v_code text;
  abc    constant text := '23456789ABCDEFGHJKMNPQRSTUVWXYZ';
begin
  if p_config is null or jsonb_typeof(p_config) <> 'object' then raise exception 'invalid_config'; end if;
  select coalesce(jsonb_object_agg(k, left(v, 120)), '{}'::jsonb) into v_cfg
  from (select key k, p_config ->> key v from jsonb_object_keys(p_config) key) x
  where k in ('f', 'dreh', 'bg', 'ac', 'card', 'k', 'n', 's', 't', 'live', 'g') and v is not null and v <> '';
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

-- ───────────────────────── Gruppen und Ligen ─────────────────────────
create table if not exists public.groups (
  id          bigint generated always as identity primary key,
  code        text unique not null check (code ~ '^[2-9A-HJKMNP-Z]{6}$'),
  name        text not null check (char_length(name) between 3 and 40),
  owner_user  uuid not null references auth.users on delete cascade,
  created_at  timestamptz not null default now()
);
create table if not exists public.group_members (
  group_id   bigint not null references public.groups on delete cascade,
  user_id    uuid   not null references auth.users on delete cascade,
  joined_at  timestamptz not null default now(),
  primary key (group_id, user_id)
);
create index if not exists group_members_user on public.group_members (user_id);
alter table public.groups enable row level security;
alter table public.group_members enable row level security;

create or replace function public.group_id_of(p_code text) returns bigint
language sql stable security definer set search_path = public as $$
  select g.id from public.groups g where g.code = upper(trim(coalesce(p_code, '')))
$$;

create or replace function public.create_group(p_name text) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_user uuid := auth.uid();
  v_name text := regexp_replace(trim(coalesce(p_name, '')), '\s+', ' ', 'g');
  v_code text; v_id bigint;
  abc constant text := '23456789ABCDEFGHJKMNPQRSTUVWXYZ';
begin
  if v_user is null then raise exception 'not_logged_in'; end if;
  if public.is_banned(v_user) then raise exception 'banned'; end if;
  if char_length(v_name) not between 3 and 40 then raise exception 'invalid_group_name'; end if;
  if public.has_banned_words(v_name) then raise exception 'bad_words'; end if;
  if (select count(*) from public.groups g where g.owner_user = v_user) >= 5 then raise exception 'group_limit'; end if;
  loop
    v_code := (select string_agg(substr(abc, 1 + floor(random() * length(abc))::int, 1), '') from generate_series(1, 6));
    begin
      insert into public.groups (code, name, owner_user) values (v_code, v_name, v_user) returning id into v_id;
      exit;
    exception when unique_violation then null;
    end;
  end loop;
  insert into public.group_members (group_id, user_id) values (v_id, v_user);
  return v_code;
end $$;

create or replace function public.join_group(p_code text) returns text
language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid(); v_id bigint := public.group_id_of(p_code);
begin
  if v_user is null then raise exception 'not_logged_in'; end if;
  if v_id is null then raise exception 'group_not_found'; end if;
  if public.is_banned(v_user) then raise exception 'banned'; end if;
  if not exists (select 1 from public.group_members m where m.group_id = v_id and m.user_id = v_user) then
    if (select count(*) from public.group_members m where m.user_id = v_user) >= 30 then raise exception 'group_limit'; end if;
    if (select count(*) from public.group_members m where m.group_id = v_id) >= 1000 then raise exception 'group_full'; end if;
    insert into public.group_members (group_id, user_id) values (v_id, v_user);
  end if;
  return (select g.name from public.groups g where g.id = v_id);
end $$;

create or replace function public.leave_group(p_code text) returns void
language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid(); v_id bigint := public.group_id_of(p_code);
begin
  if v_user is null then raise exception 'not_logged_in'; end if;
  if exists (select 1 from public.groups g where g.id = v_id and g.owner_user = v_user) then raise exception 'owner_cannot_leave'; end if;
  delete from public.group_members m where m.group_id = v_id and m.user_id = v_user;
end $$;

-- Verwaltung durch den Gründer: umbenennen, Mitglied entfernen, löschen
create or replace function public.manage_group(p_code text, p_action text, p_value text default null) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_user uuid := auth.uid(); v_id bigint := public.group_id_of(p_code);
  v_name text := regexp_replace(trim(coalesce(p_value, '')), '\s+', ' ', 'g');
  v_target uuid;
begin
  if v_user is null then raise exception 'not_logged_in'; end if;
  if not exists (select 1 from public.groups g where g.id = v_id and g.owner_user = v_user) then raise exception 'not_owner'; end if;
  if p_action = 'rename' then
    if char_length(v_name) not between 3 and 40 then raise exception 'invalid_group_name'; end if;
    if public.has_banned_words(v_name) then raise exception 'bad_words'; end if;
    update public.groups g set name = v_name where g.id = v_id;
  elsif p_action = 'remove' then
    select p.id into v_target from public.profiles p where lower(p.username) = lower(ltrim(v_name, '@'));
    if v_target is null or v_target = v_user then raise exception 'user_not_found'; end if;
    delete from public.group_members m where m.group_id = v_id and m.user_id = v_target;
  elsif p_action = 'delete' then
    delete from public.groups g where g.id = v_id;
  else
    raise exception 'invalid_action';
  end if;
end $$;

-- Gruppe ansehen: für alle mit dem Code (enthält nur öffentliche Witze)
create or replace function public.get_group(p_code text)
returns table (code text, name text, members int, owner_name text, is_member boolean, is_owner boolean, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select g.code, g.name,
         (select count(*)::int from public.group_members m where m.group_id = g.id),
         (select p.username from public.profiles p where p.id = g.owner_user),
         exists (select 1 from public.group_members m where m.group_id = g.id and m.user_id = auth.uid()),
         g.owner_user = auth.uid(), g.created_at
  from public.groups g where g.code = upper(trim(coalesce(p_code, '')))
$$;

create or replace function public.my_groups()
returns table (code text, name text, members int, is_owner boolean)
language sql stable security definer set search_path = public as $$
  select g.code, g.name, (select count(*)::int from public.group_members m2 where m2.group_id = g.id), g.owner_user = auth.uid()
  from public.group_members m join public.groups g on g.id = m.group_id
  where m.user_id = auth.uid()
  order by m.joined_at
$$;

-- Zeitraum: week = 7 Tage, month = aktueller Kalendermonat, all = immer
create or replace function public.group_since(p_range text) returns timestamptz
language sql stable as $$
  select case p_range when 'week' then now() - interval '7 days'
                      when 'month' then date_trunc('month', now() at time zone 'Europe/Berlin') at time zone 'Europe/Berlin'
                      else '-infinity'::timestamptz end
$$;

create or replace function public.group_ranking(p_device uuid, p_code text, p_range text, p_limit int default 20)
returns table (id bigint, body text, category_slug text, author_name text, created_at timestamptz,
               up_count int, down_count int, score double precision, is_own boolean, my_vote smallint)
language sql stable security definer set search_path = public as $$
  select f.id, f.body, f.category_slug, f.author_name, f.created_at, f.up_count, f.down_count, f.score,
         (f.author_device = p_device or f.author_user = auth.uid()) is true, v.value
  from public.joke_feed f
  join public.group_members m on m.user_id = f.author_user and m.group_id = public.group_id_of(p_code)
  left join public.votes v on v.joke_id = f.id and v.device_id = p_device
  where f.status = 'visible' and f.created_at >= public.group_since(p_range)
  order by f.score desc, f.up_count + f.down_count desc, f.created_at desc
  limit least(greatest(p_limit, 1), 50)
$$;

create or replace function public.group_members_ranking(p_code text, p_range text)
returns table (username text, jokes int, up_count int, is_owner boolean)
language sql stable security definer set search_path = public as $$
  select p.username,
         count(f.id)::int,
         coalesce(sum(f.up_count), 0)::int,
         g.owner_user = m.user_id
  from public.group_members m
  join public.groups g on g.id = m.group_id
  join public.profiles p on p.id = m.user_id
  left join public.joke_feed f on f.author_user = m.user_id and f.status = 'visible' and f.created_at >= public.group_since(p_range)
  where m.group_id = public.group_id_of(p_code)
  group by p.username, g.owner_user, m.user_id
  order by 3 desc, 2 desc, p.username
  limit 200
$$;

-- Admin: Gruppen ansehen und löschen
create or replace function public.admin_groups(p_key text)
returns table (code text, name text, owner_name text, members int, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.admin_check(p_key) then raise exception 'not_admin'; end if;
  return query
    select g.code, g.name, p.username, (select count(*)::int from public.group_members m where m.group_id = g.id), g.created_at
    from public.groups g left join public.profiles p on p.id = g.owner_user
    order by g.created_at desc limit 300;
end $$;

create or replace function public.admin_delete_group(p_key text, p_code text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.admin_check(p_key) then raise exception 'not_admin'; end if;
  delete from public.groups g where g.code = upper(trim(coalesce(p_code, '')));
end $$;

-- ───────────────────────── Rechte ─────────────────────────
revoke all on public.quiz_results, public.live_rounds, public.live_votes, public.groups, public.group_members from anon, authenticated;
revoke execute on function public.quiz_pool(), public.group_id_of(text), public.group_since(text) from public, anon, authenticated;
revoke execute on function
  public.get_quiz(boolean, int, text[]), public.submit_quiz(uuid, int),
  public.live_round(text, uuid, boolean, text[]), public.live_vote(uuid, bigint, int), public.save_tv_screen(jsonb),
  public.create_group(text), public.join_group(text), public.leave_group(text), public.manage_group(text, text, text),
  public.get_group(text), public.my_groups(), public.group_ranking(uuid, text, text, int), public.group_members_ranking(text, text),
  public.admin_groups(text), public.admin_delete_group(text, text) from public;
grant execute on function
  public.get_quiz(boolean, int, text[]), public.submit_quiz(uuid, int),
  public.live_round(text, uuid, boolean, text[]), public.live_vote(uuid, bigint, int), public.save_tv_screen(jsonb),
  public.get_group(text), public.group_ranking(uuid, text, text, int), public.group_members_ranking(text, text),
  public.admin_groups(text), public.admin_delete_group(text, text) to anon, authenticated;
grant execute on function
  public.create_group(text), public.join_group(text), public.leave_group(text), public.manage_group(text, text, text),
  public.my_groups() to authenticated;
revoke execute on function public.create_group(text), public.join_group(text), public.leave_group(text),
  public.manage_group(text, text, text), public.my_groups() from anon;
grant execute on all functions in schema public to service_role;
grant all on all tables in schema public to service_role;
