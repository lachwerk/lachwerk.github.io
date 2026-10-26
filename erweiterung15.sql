-- ═══════════════════════════════════════════════════════════════════
-- Lachwerk – Erweiterung 15: Admin-Dashboard, Mehrfachauswahl, Nutzer-Details,
-- Moderations-Protokoll und Sicherheits-Hinweise.
-- Setzt die bisherigen Erweiterungen voraus. Mehrfach ausführen ist unschädlich.
-- ═══════════════════════════════════════════════════════════════════

-- ───────────────────────── Protokoll ─────────────────────────
-- Jede Admin-Aktion wird mit „wer, wann, was“ festgehalten (nur für Admins sichtbar, 1 Jahr lang).
create table if not exists public.admin_log (
  id      bigint generated always as identity primary key,
  at      timestamptz not null default now(),
  tx      bigint not null default txid_current(),
  actor   text not null,
  action  text not null,
  target  text,
  detail  text,
  n       int  not null default 1
);
create index if not exists admin_log_at on public.admin_log (at desc);
create index if not exists admin_log_target on public.admin_log (target, at desc);
-- Sammel-Einträge (z. B. „12 Witze eingeplant“): ein Eintrag pro Aktion und Vorgang
create unique index if not exists admin_log_tx_agg on public.admin_log (tx, action) where target is null;
alter table public.admin_log enable row level security;

-- Interne Notiz zu einem Konto (nur für Admins)
alter table public.profiles add column if not exists admin_note text check (char_length(admin_note) <= 500);

-- Wer gerade als Admin handelt, merkt sich die Datenbank für die Dauer des Aufrufs.
create or replace function public.owner_check(p_key text) returns boolean
language plpgsql volatile security definer set search_path = public, extensions as $$
declare ok boolean;
begin
  ok := char_length(coalesce(p_key, '')) >= 12
        and coalesce((select s.value = crypt(p_key, s.value) from public.settings s where s.key = 'admin_key'), false);
  if ok then perform set_config('lachwerk.actor', 'Admin-Schlüssel', true); end if;
  return ok;
end $$;

create or replace function public.admin_check(p_key text) returns boolean
language plpgsql volatile security definer set search_path = public as $$
declare v_name text;
begin
  if public.owner_check(p_key) then return true; end if;
  select p.username into v_name from public.profiles p
  where p.id = auth.uid() and p.role = 'admin' and p.banned_at is null;
  if v_name is null then return false; end if;
  perform set_config('lachwerk.actor', '@' || v_name, true);
  return true;
end $$;

create or replace function public.admin_actor() returns text
language sql stable as $$ select nullif(current_setting('lachwerk.actor', true), '') $$;

create or replace function public.admin_log_add(p_action text, p_target text, p_detail text) returns void
language plpgsql security definer set search_path = public as $$
declare a text := public.admin_actor();
begin
  if a is null then return; end if;
  if p_target is null then
    insert into public.admin_log (actor, action, detail) values (a, p_action, left(p_detail, 140))
    on conflict (tx, action) where target is null do update set n = public.admin_log.n + 1, at = now();
  else
    insert into public.admin_log (actor, action, target, detail) values (a, p_action, p_target, left(p_detail, 140));
  end if;
end $$;

-- Witze: Status, Text, Kategorie, Zeitpunkt
create or replace function public.trg_log_jokes() returns trigger
language plpgsql security definer set search_path = public as $$
declare t text; d text;
begin
  if public.admin_actor() is null then return null; end if;
  d := left(split_part(new.body, E'\n', 1), 90);
  if tg_op = 'INSERT' then
    perform public.admin_log_add(case when new.created_at > now() + interval '1 minute' then 'joke_plan' else 'joke_add' end, null, d);
    return null;
  end if;
  t := '#' || new.id;
  if new.status is distinct from old.status then
    perform public.admin_log_add(case new.status when 'visible' then 'joke_restore' when 'hidden' then 'joke_hide' else 'joke_remove' end, t, d);
  elsif old.report_count > 0 and new.report_count = 0 then
    perform public.admin_log_add('reports_clear', t, d);
  end if;
  if new.body is distinct from old.body then perform public.admin_log_add('joke_edit', t, d); end if;
  if new.category_id is distinct from old.category_id then
    perform public.admin_log_add('joke_category', t, (select c.name from public.categories c where c.id = new.category_id) || ': ' || d);
  end if;
  return null;
end $$;
drop trigger if exists log_jokes on public.jokes;
create trigger log_jokes after insert or update of status, body, category_id, report_count on public.jokes for each row execute function public.trg_log_jokes();

-- Konten: Sperre, Admin-Rechte, Notiz
create or replace function public.trg_log_profiles() returns trigger
language plpgsql security definer set search_path = public as $$
declare t text := '@' || new.username;
begin
  if public.admin_actor() is null then return null; end if;
  if new.banned_at is distinct from old.banned_at then
    perform public.admin_log_add(case when new.banned_at is null then 'user_unban' else 'user_ban' end, t, new.ban_reason);
  end if;
  if new.role is distinct from old.role then
    perform public.admin_log_add(case when new.role = 'admin' then 'role_on' else 'role_off' end, t, null);
  end if;
  if new.admin_note is distinct from old.admin_note then perform public.admin_log_add('user_note', t, new.admin_note); end if;
  return null;
end $$;
drop trigger if exists log_profiles on public.profiles;
create trigger log_profiles after update of banned_at, role, admin_note on public.profiles for each row execute function public.trg_log_profiles();

-- Wortfilter (einmal pro Speichern)
create or replace function public.trg_log_words() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.admin_actor() is not null then
    perform public.admin_log_add('words_save', null, (select count(*) from public.banned_words) || ' Wörter');
  end if;
  return null;
end $$;
drop trigger if exists log_words on public.banned_words;
create trigger log_words after insert on public.banned_words for each statement execute function public.trg_log_words();

-- Einstellungen: Ankündigung und Kontakt
create or replace function public.trg_log_settings() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.admin_actor() is null or new.key not in ('announcement', 'contact_email') then return null; end if;
  perform public.admin_log_add(case new.key when 'announcement' then 'announcement' else 'contact' end, null, nullif(new.value, ''));
  return null;
end $$;
drop trigger if exists log_settings on public.settings;
create trigger log_settings after insert or update on public.settings for each row execute function public.trg_log_settings();

-- Challenges, Sponsoren, Gruppen
create or replace function public.trg_log_misc() returns trigger
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if public.admin_actor() is null then return null; end if;
  if tg_op = 'DELETE' then r := old; else r := new; end if;
  if tg_table_name = 'challenges' then
    perform public.admin_log_add('challenge_save', 'Challenge', r.title);
  elsif tg_table_name = 'sponsors' then
    perform public.admin_log_add(case when tg_op = 'DELETE' then 'sponsor_delete' else 'sponsor_save' end, 'Sponsor', r.name);
  elsif tg_table_name = 'groups' and tg_op = 'DELETE' then
    perform public.admin_log_add('group_delete', 'Gruppe', r.name);
  end if;
  return null;
end $$;
drop trigger if exists log_misc on public.challenges;
create trigger log_misc after insert or update on public.challenges for each row execute function public.trg_log_misc();
drop trigger if exists log_misc on public.sponsors;
create trigger log_misc after insert or update or delete on public.sponsors for each row execute function public.trg_log_misc();
drop trigger if exists log_misc on public.groups;
create trigger log_misc after delete on public.groups for each row execute function public.trg_log_misc();

create or replace function public.admin_log_list(p_key text, p_limit int default 50, p_offset int default 0, p_target text default null)
returns table (at timestamptz, actor text, action text, target text, detail text, n int)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not public.admin_check(p_key) then raise exception 'not_admin'; end if;
  delete from public.admin_log l where l.at < now() - interval '1 year';
  return query
    select l.at, l.actor, l.action, l.target, l.detail, l.n from public.admin_log l
    where p_target is null or l.target = p_target
    order by l.at desc, l.id desc
    limit least(greatest(p_limit, 1), 200) offset greatest(p_offset, 0);
end $$;

-- ───────────────────────── Dashboard ─────────────────────────
create or replace function public.admin_dashboard(p_key text) returns json
language plpgsql security definer set search_path = public as $$
declare
  d0  date := (now() at time zone 'Europe/Berlin')::date;
  t30 timestamptz := ((d0 - 29)::timestamp) at time zone 'Europe/Berlin';
  t7  timestamptz := now() - interval '7 days';
  r   json;
begin
  if not public.admin_check(p_key) then raise exception 'not_admin'; end if;
  with days as (select generate_series(d0 - 29, d0, interval '1 day')::date as d),
  v as (select (x.created_at at time zone 'Europe/Berlin')::date as d, count(*) as n, count(distinct x.device_id) as dev
        from public.votes x where x.created_at >= t30 group by 1),
  j as (select (x.created_at at time zone 'Europe/Berlin')::date as d, count(*) as n
        from public.jokes x where x.author_user is not null and x.created_at >= t30 and x.created_at <= now() group by 1),
  s as (select (x.created_at at time zone 'Europe/Berlin')::date as d, count(*) as n from public.profiles x where x.created_at >= t30 group by 1),
  rp as (select (x.created_at at time zone 'Europe/Berlin')::date as d, count(*) as n from public.reports x where x.created_at >= t30 group by 1)
  select json_build_object(
    'days', (select json_agg(json_build_object(
                'day', days.d, 'visitors', coalesce(vd.uniques, 0), 'views', coalesce(vd.views, 0),
                'voters', coalesce(v.dev, 0), 'votes', coalesce(v.n, 0), 'jokes', coalesce(j.n, 0),
                'signups', coalesce(s.n, 0), 'reports', coalesce(rp.n, 0)) order by days.d)
             from days left join public.visit_daily vd on vd.day = days.d left join v on v.d = days.d
             left join j on j.d = days.d left join s on s.d = days.d left join rp on rp.d = days.d),
    'funnel', json_build_object(
       'visitors', (select coalesce(sum(vd.uniques), 0) from public.visit_daily vd where vd.day > d0 - 7),
       'voters',   (select count(distinct z.dev) from (
                      select x.device_id dev from public.votes x where x.created_at >= t7
                      union all select x.device_id from public.duel_votes x where x.created_at >= t7
                      union all select x.device_id from public.reactions x where x.created_at >= t7) z),
       'posters',  (select count(distinct x.author_user) from public.jokes x where x.author_user is not null and x.created_at >= t7 and x.created_at <= now()),
       'signups',  (select count(*) from public.profiles x where x.created_at >= t7)),
    'hours', (select json_agg(coalesce(h.n, 0) order by g.i)
              from generate_series(0, 23) g(i)
              left join (select floor(extract(epoch from (now() - x.created_at)) / 3600)::int as ago, count(*) as n
                         from public.votes x where x.created_at > now() - interval '24 hours' group by 1) h on h.ago = 23 - g.i),
    'like_rate', (select round(100.0 * count(*) filter (where x.value = 1) / nullif(count(*), 0)) from public.votes x where x.created_at >= t7),
    'votes_per_joke', (select round(avg(x.up_count + x.down_count), 1) from public.jokes x
                       where x.status = 'visible' and x.created_at between now() - interval '14 days' and now() - interval '1 day'),
    'authors_7',  (select count(distinct x.author_user) from public.jokes x where x.author_user is not null and x.created_at >= t7 and x.created_at <= now()),
    'authors_30', (select count(distinct x.author_user) from public.jokes x where x.author_user is not null and x.created_at >= t30 and x.created_at <= now()),
    'top_authors', (select json_agg(a order by a.likes desc, a.jokes desc) from (
                      select p.username, count(distinct x.id) as jokes,
                             count(vt.*) filter (where vt.value = 1) as likes, count(vt.*) filter (where vt.value = -1) as dislikes
                      from public.jokes x join public.profiles p on p.id = x.author_user
                      left join public.votes vt on vt.joke_id = x.id and vt.created_at >= t30
                      where x.status = 'visible' and x.created_at <= now()
                      group by p.username
                      having count(vt.*) > 0
                      order by 3 desc, 2 desc limit 8) a),
    'top_cats', (select json_agg(c order by c.votes desc) from (
                   select cat.name, count(*) as votes from public.votes x join public.jokes jj on jj.id = x.joke_id
                   join public.categories cat on cat.id = jj.category_id where x.created_at >= t7
                   group by cat.name order by 2 desc limit 6) c)
  ) into r;
  return r;
end $$;

-- ───────────────────────── Sicherheit ─────────────────────────
create or replace function public.admin_security(p_key text) returns json
language plpgsql security definer set search_path = public as $$
declare r json;
begin
  if not public.admin_check(p_key) then raise exception 'not_admin'; end if;
  select json_build_object(
    -- Viele Witze in kurzer Zeit
    'flood_users', (select json_agg(z) from (
        select p.username, count(*) as n from public.jokes x join public.profiles p on p.id = x.author_user
        where x.created_at > now() - interval '24 hours' and x.created_at <= now()
        group by p.username having count(*) >= 5 order by 2 desc limit 10) z),
    -- Auffällig viele Stimmen von einem Gerät bzw. Anschluss
    'flood_devices', (select json_agg(z) from (
        select left(x.device_id::text, 6) as dev, count(*) as n from public.votes x
        where x.created_at > now() - interval '24 hours' group by x.device_id having count(*) >= 150 order by 2 desc limit 10) z),
    'flood_ips', (select count(*) from (
        select 1 from public.votes x where x.created_at > now() - interval '24 hours' and x.ip_hash is not null
        group by x.ip_hash having count(*) >= 400) z),
    -- Konten, deren Witze oft gemeldet werden
    'reported_users', (select json_agg(z) from (
        select p.username, count(*) as n from public.reports rp join public.jokes x on x.id = rp.joke_id
        join public.profiles p on p.id = x.author_user
        where rp.created_at > now() - interval '7 days'
        group by p.username having count(*) >= 3 order by 2 desc limit 10) z),
    -- Mehrere Konten auf einem Gerät
    'shared_devices', (select json_agg(z) from (
        select string_agg(distinct p.username, ', ') as names, count(distinct p.id) as n
        from public.jokes x join public.profiles p on p.id = x.author_user
        where x.author_device <> '00000000-0000-0000-0000-000000000000'
        group by x.author_device having count(distinct p.id) >= 2 order by 2 desc limit 10) z),
    'signups_24h', (select count(*) from public.profiles p where p.created_at > now() - interval '24 hours'),
    'admins', (select json_agg(p.username order by p.username) from public.profiles p where p.role = 'admin'),
    'banned', (select json_agg(z) from (
        select p.username, p.banned_at, p.ban_reason from public.profiles p where p.banned_at is not null
        order by p.banned_at desc limit 15) z),
    'recent_reports', (select json_agg(z) from (
        select x.id, left(split_part(x.body, E'\n', 1), 90) as body, x.author_name, x.status, x.report_count,
               max(rp.created_at) as at, count(*) as n
        from public.reports rp join public.jokes x on x.id = rp.joke_id
        where rp.created_at > now() - interval '30 days'
        group by x.id order by max(rp.created_at) desc limit 15) z)
  ) into r;
  return r;
end $$;

-- ───────────────────────── Nutzer-Details ─────────────────────────
create or replace function public.admin_user_detail(p_key text, p_username text) returns json
language plpgsql security definer set search_path = public as $$
declare v public.profiles; devs uuid[]; r json;
begin
  if not public.admin_check(p_key) then raise exception 'not_admin'; end if;
  select * into v from public.profiles p where lower(p.username) = lower(trim(p_username));
  if v.id is null then raise exception 'user_not_found'; end if;
  select coalesce(array_agg(distinct x.author_device), '{}') into devs from public.jokes x where x.author_user = v.id;
  select json_build_object(
    'username', v.username, 'created_at', v.created_at, 'role', v.role, 'banned_at', v.banned_at,
    'ban_reason', v.ban_reason, 'note', v.admin_note,
    'visible', (select count(*) from public.jokes x where x.author_user = v.id and x.status = 'visible' and x.created_at <= now()),
    'queued',  (select count(*) from public.jokes x where x.author_user = v.id and x.status = 'visible' and x.created_at > now()),
    'hidden',  (select count(*) from public.jokes x where x.author_user = v.id and x.status = 'hidden'),
    'removed', (select count(*) from public.jokes x where x.author_user = v.id and x.status = 'removed'),
    'up',      (select coalesce(sum(x.up_count), 0) from public.jokes x where x.author_user = v.id and x.status <> 'removed'),
    'down',    (select coalesce(sum(x.down_count), 0) from public.jokes x where x.author_user = v.id and x.status <> 'removed'),
    'reports', (select count(*) from public.reports rp join public.jokes x on x.id = rp.joke_id where x.author_user = v.id),
    'punchlines', (select count(*) from public.battle_entries e where e.author_user = v.id and e.status = 'visible'),
    'first_joke', (select min(x.created_at) from public.jokes x where x.author_user = v.id),
    'last_joke',  (select max(x.created_at) from public.jokes x where x.author_user = v.id and x.created_at <= now()),
    'devices', cardinality(devs),
    'votes_given', (select count(*) from public.votes x where x.device_id = any(devs)),
    'push', exists (select 1 from public.push_subscriptions ps where ps.user_id = v.id),
    'groups', (select count(*) from public.group_members gm where gm.user_id = v.id),
    'groups_owned', (select count(*) from public.groups g where g.owner_user = v.id),
    'best', (select json_build_object('id', x.id, 'body', left(x.body, 120), 'up', x.up_count) from public.jokes x
             where x.author_user = v.id and x.status = 'visible' and x.created_at <= now() order by x.up_count desc, x.id limit 1),
    'same_device', (select json_agg(distinct p.username) from public.jokes x join public.profiles p on p.id = x.author_user
                    where x.author_device = any(devs) and x.author_device <> '00000000-0000-0000-0000-000000000000' and p.id <> v.id),
    'jokes', (select json_agg(z order by z.created_at desc) from (
        select x.id, x.body, c.slug as category_slug, x.up_count, x.down_count, x.report_count, x.created_at,
               case when x.status = 'visible' and x.created_at > now() then 'queued' else x.status end as status
        from public.jokes x join public.categories c on c.id = x.category_id
        where x.author_user = v.id order by x.created_at desc limit 40) z),
    'log', (select json_agg(z order by z.at desc) from (
        select l.at, l.actor, l.action, l.target, l.detail from public.admin_log l
        where l.target = '@' || v.username
           or l.target in (select '#' || x.id from public.jokes x where x.author_user = v.id)
        order by l.at desc limit 30) z)
  ) into r;
  return r;
end $$;

create or replace function public.admin_set_note(p_key text, p_username text, p_note text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.admin_check(p_key) then raise exception 'not_admin'; end if;
  if char_length(coalesce(p_note, '')) > 500 then raise exception 'invalid_value'; end if;
  update public.profiles p set admin_note = nullif(trim(coalesce(p_note, '')), '')
  where lower(p.username) = lower(trim(p_username));
  if not found then raise exception 'user_not_found'; end if;
end $$;

-- ───────────────────────── Witze: Mehrfachauswahl und Posten ─────────────────────────
-- p_status: 'visible' (freigeben, Meldungen verwerfen), 'hidden' (ausblenden), 'removed' (entfernen)
create or replace function public.admin_bulk_status(p_key text, p_ids bigint[], p_status text) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not public.admin_check(p_key) then raise exception 'not_admin'; end if;
  if p_status not in ('visible', 'hidden', 'removed') then raise exception 'invalid_status'; end if;
  if cardinality(coalesce(p_ids, '{}')) = 0 then return 0; end if;
  if cardinality(p_ids) > 200 then raise exception 'invalid_value'; end if;
  if p_status = 'visible' then
    delete from public.reports r where r.joke_id = any(p_ids);
    update public.jokes j set status = 'visible', report_count = 0, reviewed_at = now()
    where j.id = any(p_ids) and (j.status <> 'visible' or j.report_count > 0);
  else
    update public.jokes j set status = p_status, reviewed_at = now() where j.id = any(p_ids) and j.status <> p_status;
  end if;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.admin_bulk_category(p_key text, p_ids bigint[], p_category text) returns int
language plpgsql security definer set search_path = public as $$
declare v_cat int; n int;
begin
  if not public.admin_check(p_key) then raise exception 'not_admin'; end if;
  select c.id into v_cat from public.categories c where c.slug = p_category;
  if v_cat is null then raise exception 'invalid_category'; end if;
  if cardinality(coalesce(p_ids, '{}')) > 200 then raise exception 'invalid_value'; end if;
  update public.jokes j set category_id = v_cat where j.id = any(coalesce(p_ids, '{}')) and j.category_id <> v_cat;
  get diagnostics n = row_count;
  return n;
end $$;

-- Einen Witz als „Lachwerk“ posten: p_mode 'now' (sofort), 'queue' (hinten in den Vorrat), 'at' (zu p_at)
create or replace function public.admin_post_joke(p_key text, p_category text, p_body text, p_mode text default 'now', p_at timestamptz default null)
returns timestamptz
language plpgsql security definer set search_path = public, extensions as $$
declare v_cat int; v_body text := trim(coalesce(p_body, '')); v_norm text; v_when timestamptz;
begin
  if not public.admin_check(p_key) then raise exception 'not_admin'; end if;
  select c.id into v_cat from public.categories c where c.slug = p_category;
  if v_cat is null then raise exception 'invalid_category'; end if;
  if char_length(v_body) not between 10 and 500 then raise exception 'invalid_body'; end if;
  v_norm := public.normalize_joke(v_body);
  if exists (select 1 from public.jokes j where j.status <> 'removed' and j.body_norm % v_norm and similarity(j.body_norm, v_norm) >= 0.6) then
    raise exception 'duplicate';
  end if;
  if p_mode = 'queue' then
    select greatest(now(), coalesce(max(j.created_at), now())) + interval '6 hours' into v_when
    from public.jokes j where j.status = 'visible' and j.author_user is null and j.created_at > now();
  elsif p_mode = 'at' then
    if p_at is null or p_at < now() - interval '5 minutes' or p_at > now() + interval '90 days' then raise exception 'invalid_value'; end if;
    v_when := greatest(p_at, now());
  else
    v_when := now();
  end if;
  insert into public.jokes (category_id, body, author_name, author_device, created_at)
  values (v_cat, v_body, 'Lachwerk', '00000000-0000-0000-0000-000000000000', v_when);
  return v_when;
end $$;

-- Nutzerliste: zusätzlich Push und Notiz-Hinweis (für Sortierung und Übersicht im Admin-Bereich)
drop function if exists public.admin_users2(text, text, int);
create function public.admin_users2(p_key text, p_query text default null, p_limit int default 500)
returns table (username text, created_at timestamptz, jokes int, up_count int, down_count int, punchlines int,
               reports int, last_activity timestamptz, banned_at timestamptz, ban_reason text, role text,
               has_note boolean, push boolean)
language plpgsql security definer set search_path = public as $$
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
           greatest((select max(j.created_at) from public.jokes j where j.author_user = p.id and j.created_at <= now()),
                    (select max(e.created_at) from public.battle_entries e where e.author_user = p.id)),
           p.banned_at, p.ban_reason, p.role, p.admin_note is not null,
           exists (select 1 from public.push_subscriptions s where s.user_id = p.id)
    from public.profiles p
    where coalesce(trim(p_query), '') = '' or p.username ilike '%' || trim(p_query) || '%'
    order by (p.role is not null) desc, p.created_at desc
    limit least(greatest(p_limit, 1), 1000);
end $$;

-- ───────────────────────── Rechte ─────────────────────────
revoke all on public.admin_log from anon, authenticated;
revoke execute on function public.admin_log_add(text, text, text), public.trg_log_jokes(), public.trg_log_profiles(),
  public.trg_log_words(), public.trg_log_settings(), public.trg_log_misc() from public, anon, authenticated;
revoke execute on function public.admin_log_list(text, int, int, text), public.admin_dashboard(text), public.admin_security(text),
  public.admin_user_detail(text, text), public.admin_set_note(text, text, text), public.admin_bulk_status(text, bigint[], text),
  public.admin_bulk_category(text, bigint[], text), public.admin_post_joke(text, text, text, text, timestamptz),
  public.admin_users2(text, text, int) from public;
grant execute on function public.admin_check(text),
  public.admin_log_list(text, int, int, text), public.admin_dashboard(text), public.admin_security(text),
  public.admin_user_detail(text, text), public.admin_set_note(text, text, text), public.admin_bulk_status(text, bigint[], text),
  public.admin_bulk_category(text, bigint[], text), public.admin_post_joke(text, text, text, text, timestamptz),
  public.admin_users2(text, text, int) to anon, authenticated;
grant execute on all functions in schema public to service_role;
grant all on all tables in schema public to service_role;
