-- ═══════════════════════════════════════════════════════════════════
-- Lachwerk – Erweiterung 3: größerer Admin-Bereich
-- Übersicht, Aktivität, Witze suchen und bearbeiten, Nutzer sperren,
-- Top-Listen, Ankündigungs-Banner, Export. Setzt erweiterung.sql und erweiterung2.sql voraus.
--
-- Für eine SCHON eingerichtete Datenbank: einmal komplett im Supabase SQL Editor
-- ausführen (Run). Mehrfach ausführen ist unschädlich.
-- Bei einer Neueinrichtung nicht nötig: supabase.sql enthält diesen Teil bereits.
-- ═══════════════════════════════════════════════════════════════════

-- ───────────────────────── Sperren von Nutzern ─────────────────────────
alter table public.profiles add column if not exists banned_at  timestamptz;
alter table public.profiles add column if not exists ban_reason text;

create or replace function public.is_banned(p_user uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select p.banned_at is not null from public.profiles p where p.id = p_user), false)
$$;

-- Witz posten: wie bisher, zusätzlich Sperre
create or replace function public.post_joke(p_device uuid, p_category text, p_body text)
returns bigint
language plpgsql security definer set search_path = public, extensions as $$
declare
  h      text := public.client_ip_hash();
  v_user uuid := auth.uid();
  v_name text;
  v_body text := trim(coalesce(p_body, ''));
  v_norm text;
  v_cat  int;
  v_dup  bigint;
  v_id   bigint;
begin
  if v_user is null then raise exception 'not_logged_in'; end if;
  select p.username into v_name from public.profiles p where p.id = v_user;
  if v_name is null then raise exception 'not_logged_in'; end if;
  if public.is_banned(v_user) then raise exception 'banned'; end if;
  if p_device is null then raise exception 'invalid_device'; end if;
  if char_length(v_body) not between 10 and 500 then raise exception 'invalid_body'; end if;
  if public.has_banned_words(v_body) then raise exception 'bad_words'; end if;

  select c.id into v_cat from public.categories c where c.slug = p_category;
  if v_cat is null then raise exception 'invalid_category'; end if;

  if (select count(*) from public.jokes j where j.author_user = v_user and j.created_at > now() - interval '24 hours') >= 10
     or (select count(*) from public.jokes j where j.ip_hash = h and j.created_at > now() - interval '24 hours') >= 20 then
    raise exception 'post_limit';
  end if;

  v_norm := public.normalize_joke(v_body);
  select j.id into v_dup
  from public.jokes j
  where j.status = 'visible' and j.body_norm % v_norm and similarity(j.body_norm, v_norm) >= 0.6
  order by similarity(j.body_norm, v_norm) desc
  limit 1;
  if v_dup is not null then
    raise exception 'duplicate' using detail = v_dup::text;
  end if;

  insert into public.jokes (category_id, body, author_name, author_device, author_user, ip_hash)
  values (v_cat, v_body, v_name, p_device, v_user, h)
  returning jokes.id into v_id;
  return v_id;
end $$;

-- Pointe einreichen: wie bisher, zusätzlich Sperre
create or replace function public.post_punchline(p_device uuid, p_prompt int, p_body text)
returns bigint
language plpgsql security definer set search_path = public as $$
declare
  h      text := public.client_ip_hash();
  v_user uuid := auth.uid();
  v_name text;
  v_body text := trim(coalesce(p_body, ''));
  v_id   bigint;
begin
  if v_user is null then raise exception 'not_logged_in'; end if;
  select p.username into v_name from public.profiles p where p.id = v_user;
  if v_name is null then raise exception 'not_logged_in'; end if;
  if public.is_banned(v_user) then raise exception 'banned'; end if;
  if p_device is null then raise exception 'invalid_device'; end if;
  if char_length(v_body) not between 2 and 200 then raise exception 'invalid_punchline'; end if;
  if public.has_banned_words(v_body) then raise exception 'bad_words'; end if;
  if not exists (select 1 from public.battle_prompts p where p.id = p_prompt and p.day = (now() at time zone 'Europe/Berlin')::date) then
    raise exception 'battle_closed';
  end if;
  if (select count(*) from public.battle_entries e where e.prompt_id = p_prompt and e.author_user = v_user) >= 3 then
    raise exception 'battle_limit';
  end if;
  if (select count(*) from public.battle_entries e where e.ip_hash = h and e.created_at > now() - interval '24 hours') >= 20 then
    raise exception 'post_limit';
  end if;
  if exists (select 1 from public.battle_entries e where e.prompt_id = p_prompt and e.status = 'visible'
             and public.normalize_joke(e.body) = public.normalize_joke(v_body)) then
    raise exception 'duplicate_punchline';
  end if;
  insert into public.battle_entries (prompt_id, body, author_user, author_name, author_device, ip_hash)
  values (p_prompt, v_body, v_user, v_name, p_device, h) returning battle_entries.id into v_id;
  return v_id;
end $$;

-- Eigenes Profil: zusätzlich, ob das Konto gesperrt ist (für einen Hinweis in der App)
drop function if exists public.my_profile();
create function public.my_profile() returns table (username text, banned boolean)
language sql stable security definer set search_path = public as $$
  select p.username, p.banned_at is not null from public.profiles p where p.id = auth.uid()
$$;

-- ───────────────────────── Ankündigung (Banner auf der Startseite) ─────────────────────────
create or replace function public.get_announcement() returns text
language sql stable security definer set search_path = public as $$
  select nullif(trim(s.value), '') from public.settings s where s.key = 'announcement'
$$;

create or replace function public.admin_set_announcement(p_key text, p_text text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.admin_check(p_key) then raise exception 'not_admin'; end if;
  if char_length(coalesce(p_text, '')) > 280 then raise exception 'invalid_value'; end if;
  insert into public.settings (key, value) values ('announcement', trim(coalesce(p_text, '')))
  on conflict (key) do update set value = excluded.value;
end $$;

-- ───────────────────────── Übersicht ─────────────────────────
-- Alle Kennzahlen in einem Aufruf (heute/gestern nach deutscher Zeit)
create or replace function public.admin_overview(p_key text) returns json
language plpgsql security definer set search_path = public as $$
declare
  d0 timestamptz := ((now() at time zone 'Europe/Berlin')::date)::timestamp at time zone 'Europe/Berlin';
  d1 timestamptz := d0 - interval '1 day';
  r  json;
begin
  if not public.admin_check(p_key) then raise exception 'not_admin'; end if;
  perform public.crown_pending();
  with per as (
    select x.label, x.t0, x.t1 from (values ('today', d0, now()), ('yesterday', d1, d0)) x(label, t0, t1)
  ), stats as (
    select per.label, json_build_object(
      'visitors', (select count(distinct dev) from (
          select v.device_id dev from public.votes v where v.created_at >= per.t0 and v.created_at < per.t1
          union all select r.device_id from public.reactions r where r.created_at >= per.t0 and r.created_at < per.t1
          union all select q.device_id from public.duel_votes q where q.created_at >= per.t0 and q.created_at < per.t1
          union all select b.device_id from public.battle_votes b where b.created_at >= per.t0 and b.created_at < per.t1) z),
      'votes',      (select count(*) from public.votes v where v.created_at >= per.t0 and v.created_at < per.t1),
      'reactions',  (select count(*) from public.reactions r where r.created_at >= per.t0 and r.created_at < per.t1),
      'duels',      (select count(*) from public.duel_votes q where q.created_at >= per.t0 and q.created_at < per.t1),
      'jokes',      (select count(*) from public.jokes j where j.author_user is not null and j.created_at >= per.t0 and j.created_at < per.t1),
      'punchlines', (select count(*) from public.battle_entries e where e.created_at >= per.t0 and e.created_at < per.t1),
      'signups',    (select count(*) from public.profiles p where p.created_at >= per.t0 and p.created_at < per.t1),
      'reports',    (select count(*) from public.reports rp where rp.created_at >= per.t0 and rp.created_at < per.t1)
    ) as s from per
  )
  select json_build_object(
    'today',     (select s from stats where label = 'today'),
    'yesterday', (select s from stats where label = 'yesterday'),
    'open_reports', (select count(*) from public.jokes j where j.status = 'hidden' or (j.status = 'visible' and j.report_count > 0)),
    'users',     (select count(*) from public.profiles),
    'banned',    (select count(*) from public.profiles p where p.banned_at is not null),
    'jokes_visible', (select count(*) from public.jokes j where j.status = 'visible' and j.created_at <= now()),
    'queued',    (select count(*) from public.jokes j where j.status = 'visible' and j.created_at > now()),
    'queue_until', (select max(j.created_at) from public.jokes j where j.status = 'visible' and j.created_at > now()),
    'crown',     (select json_build_object('day', w.day, 'id', j.id, 'body', j.body, 'author', j.author_name)
                  from public.daily_winners w join public.jokes j on j.id = w.joke_id order by w.day desc limit 1),
    'challenge', (select json_build_object('title', c.title, 'ends_at', c.ends_at,
                    'entries', (select count(*) from public.jokes j where j.challenge_id = c.id and j.status = 'visible'))
                  from public.challenges c where now() >= c.starts_at and now() < c.ends_at order by c.ends_at limit 1),
    'battle',    (select json_build_object('setup', p.setup,
                    'entries', (select count(*) from public.battle_entries e where e.prompt_id = p.id and e.status = 'visible'))
                  from public.battle_prompts p where p.day = (now() at time zone 'Europe/Berlin')::date),
    'battle_pool', (select count(*) from public.battle_prompts p where p.day is null),
    'announcement', public.get_announcement()
  ) into r;
  return r;
end $$;

-- Letzte Aktivitäten (neue Witze von Nutzern, Pointen, Registrierungen, Meldungen)
create or replace function public.admin_activity(p_key text, p_limit int default 40)
returns table (kind text, at timestamptz, body text, who text, ref bigint)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not public.admin_check(p_key) then raise exception 'not_admin'; end if;
  return query
    select * from (
      (select 'joke'::text, j.created_at, j.body, j.author_name, j.id
       from public.jokes j where j.author_user is not null order by j.created_at desc limit 40)
      union all
      (select 'punchline', e.created_at, e.body, e.author_name, e.id
       from public.battle_entries e order by e.created_at desc limit 40)
      union all
      (select 'signup', p.created_at, null, p.username, null::bigint
       from public.profiles p order by p.created_at desc limit 40)
      union all
      (select 'report', r.created_at, j.body, j.author_name, j.id
       from public.reports r join public.jokes j on j.id = r.joke_id order by r.created_at desc limit 40)
    ) a
    where a.created_at <= now()
    order by 2 desc
    limit least(greatest(p_limit, 1), 100);
end $$;

-- ───────────────────────── Witze verwalten ─────────────────────────
-- p_status: 'visible', 'hidden', 'removed', 'queued' (noch nicht erschienen) oder null = alle
create or replace function public.admin_search_jokes(p_key text, p_query text default null, p_category text default null,
                                                     p_status text default null, p_author text default null,
                                                     p_limit int default 50, p_offset int default 0)
returns table (id bigint, body text, category_slug text, author_name text, created_at timestamptz,
               up_count int, down_count int, report_count int, status text, is_user boolean)
language plpgsql stable security definer set search_path = public, extensions as $$
#variable_conflict use_column
begin
  if not public.admin_check(p_key) then raise exception 'not_admin'; end if;
  return query
    select j.id, j.body, c.slug, j.author_name, j.created_at, j.up_count, j.down_count, j.report_count,
           case when j.status = 'visible' and j.created_at > now() then 'queued' else j.status end,
           j.author_user is not null
    from public.jokes j join public.categories c on c.id = j.category_id
    where (coalesce(trim(p_query), '') = '' or j.body ilike '%' || trim(p_query) || '%' or j.id::text = trim(p_query))
      and (p_category is null or p_category = '' or c.slug = p_category)
      and (p_author is null or p_author = '' or lower(j.author_name) = lower(trim(p_author)))
      and (p_status is null or p_status = ''
           or (p_status = 'queued' and j.status = 'visible' and j.created_at > now())
           or (p_status = 'visible' and j.status = 'visible' and j.created_at <= now())
           or (p_status not in ('queued', 'visible') and j.status = p_status))
    order by j.created_at desc
    limit least(greatest(p_limit, 1), 200) offset greatest(p_offset, 0);
end $$;

create or replace function public.admin_update_joke(p_key text, p_id bigint, p_body text, p_category text)
returns void
language plpgsql security definer set search_path = public as $$
declare v_cat int; v_body text := trim(coalesce(p_body, ''));
begin
  if not public.admin_check(p_key) then raise exception 'not_admin'; end if;
  if char_length(v_body) not between 10 and 500 then raise exception 'invalid_body'; end if;
  select c.id into v_cat from public.categories c where c.slug = p_category;
  if v_cat is null then raise exception 'invalid_category'; end if;
  update public.jokes j set body = v_body, category_id = v_cat where j.id = p_id;
  if not found then raise exception 'joke_not_found'; end if;
end $$;

-- ───────────────────────── Nutzer verwalten ─────────────────────────
create or replace function public.admin_users(p_key text, p_query text default null, p_limit int default 100)
returns table (username text, created_at timestamptz, jokes int, up_count int, down_count int, punchlines int,
               reports int, last_activity timestamptz, banned_at timestamptz, ban_reason text)
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
           p.banned_at, p.ban_reason
    from public.profiles p
    where coalesce(trim(p_query), '') = '' or p.username ilike '%' || trim(p_query) || '%'
    order by p.created_at desc
    limit least(greatest(p_limit, 1), 500);
end $$;

-- Sperren (p_ban = true) oder entsperren (false). Gesperrte können nichts mehr posten.
create or replace function public.admin_ban_user(p_key text, p_username text, p_ban boolean, p_reason text default null)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.admin_check(p_key) then raise exception 'not_admin'; end if;
  update public.profiles p set banned_at = case when p_ban then now() else null end,
                               ban_reason = case when p_ban then nullif(trim(coalesce(p_reason, '')), '') else null end
  where lower(p.username) = lower(trim(p_username));
  if not found then raise exception 'user_not_found'; end if;
end $$;

-- Alle Witze und Pointen eines Nutzers entfernen. Gibt die Anzahl zurück.
create or replace function public.admin_remove_user_content(p_key text, p_username text)
returns int
language plpgsql security definer set search_path = public as $$
declare v_user uuid; n1 int; n2 int;
begin
  if not public.admin_check(p_key) then raise exception 'not_admin'; end if;
  select p.id into v_user from public.profiles p where lower(p.username) = lower(trim(p_username));
  if v_user is null then raise exception 'user_not_found'; end if;
  update public.jokes j set status = 'removed', reviewed_at = now() where j.author_user = v_user and j.status <> 'removed';
  get diagnostics n1 = row_count;
  update public.battle_entries e set status = 'removed' where e.author_user = v_user and e.status <> 'removed';
  get diagnostics n2 = row_count;
  return n1 + n2;
end $$;

-- ───────────────────────── Top-Listen und Export ─────────────────────────
-- kind: 'week' (beste der Woche, ab 3 Stimmen), 'all' (meiste Likes), 'reported', 'reacted', 'duel', 'flop' (schlechteste der Woche)
create or replace function public.admin_top(p_key text)
returns table (kind text, id bigint, body text, author_name text, n int, score double precision)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not public.admin_check(p_key) then raise exception 'not_admin'; end if;
  return query
    (select 'week'::text, f.id, f.body, f.author_name, (f.up_count + f.down_count)::int, f.score
     from public.joke_feed f where f.status = 'visible' and f.created_at > now() - interval '7 days' and f.up_count + f.down_count >= 3
     order by f.score desc limit 5)
    union all
    (select 'all', f.id, f.body, f.author_name, f.up_count, f.score
     from public.joke_feed f where f.status = 'visible' order by f.up_count desc, f.score desc limit 5)
    union all
    (select 'flop', f.id, f.body, f.author_name, f.down_count, f.score
     from public.joke_feed f where f.status = 'visible' and f.created_at > now() - interval '7 days' and f.up_count + f.down_count >= 3
     order by (f.down_count::float / (f.up_count + f.down_count)) desc, f.down_count desc limit 5)
    union all
    (select 'reported', f.id, f.body, f.author_name, f.report_count, f.score
     from public.joke_feed f where f.report_count > 0 order by f.report_count desc limit 5)
    union all
    (select 'reacted', f.id, f.body, f.author_name, t.n::int, f.score
     from (select r.joke_id, count(*) as n from public.reactions r group by r.joke_id order by 2 desc limit 5) t
     join public.joke_feed f on f.id = t.joke_id)
    union all
    (select 'duel', f.id, f.body, f.author_name, j.duel_count, j.elo
     from public.jokes j join public.joke_feed f on f.id = j.id where j.duel_count > 0 and f.status = 'visible'
     order by j.elo desc limit 5);
end $$;

create or replace function public.admin_export(p_key text)
returns table (id bigint, category text, body text, author text, created_at timestamptz, up_count int, down_count int,
               report_count int, status text)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not public.admin_check(p_key) then raise exception 'not_admin'; end if;
  return query
    select j.id, c.slug, j.body, j.author_name, j.created_at, j.up_count, j.down_count, j.report_count,
           case when j.status = 'visible' and j.created_at > now() then 'queued' else j.status end
    from public.jokes j join public.categories c on c.id = j.category_id
    order by j.id
    limit 20000;
end $$;

-- ───────────────────────── Rechte ─────────────────────────
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
  public.admin_export(text)
to anon, authenticated;
