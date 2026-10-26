-- ═══════════════════════════════════════════════════════════════════
-- Lachwerk – Erweiterung 2: Pointen-Battle, Monats-Saison, Lieblingskategorien,
-- Wortfilter. Setzt erweiterung.sql voraus.
--
-- Für eine SCHON eingerichtete Datenbank: einmal komplett im Supabase SQL Editor
-- ausführen (Run). Mehrfach ausführen ist unschädlich.
-- Bei einer Neueinrichtung nicht nötig: supabase.sql enthält diesen Teil bereits.
-- ═══════════════════════════════════════════════════════════════════

-- ───────────────────────── Wortfilter ─────────────────────────
-- Wörter werden als ganzes Wort gesucht. Endet ein Eintrag auf *, zählt er als Wortanfang
-- (z. B. „fick*“ trifft auch „ficken“). Pflege im Admin-Bereich unter „Wortfilter“.

create table if not exists public.banned_words (
  word text primary key check (word ~ '^[[:alnum:]äöüß]{2,40}\*?$')
);
insert into public.banned_words (word)
select unnest(array['arschloch', 'hurensohn', 'wichser', 'fotze', 'missgeburt', 'spast*', 'spasti', 'schwuchtel',
                    'kanake*', 'neger*', 'nutte', 'schlampe', 'fick*', 'behindi', 'mongo', 'judensau', 'zigeuner*'])
where not exists (select 1 from public.settings s where s.key = 'banned_seeded')
on conflict do nothing;
insert into public.settings (key, value) values ('banned_seeded', '1') on conflict do nothing;

create or replace function public.has_banned_words(t text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.banned_words b
    where case when b.word like '%*'
               then (' ' || public.normalize_joke(t)) like ('% ' || rtrim(b.word, '*') || '%')
               else (' ' || public.normalize_joke(t) || ' ') like ('% ' || b.word || ' %') end)
$$;

-- Witz posten: wie bisher, zusätzlich mit Wortfilter
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

-- ───────────────────────── Pointen-Battle ─────────────────────────
-- Jeden Tag ein Witzanfang ohne Pointe. Angemeldete Nutzer schreiben Pointen (max. 3 pro Tag),
-- alle stimmen ab. Die Anfänge kommen aus einem Vorrat (Admin → Battle).

create table if not exists public.battle_prompts (
  id          serial primary key,
  setup       text not null unique check (char_length(setup) between 10 and 300),
  day         date unique,                     -- an welchem Tag (deutsche Zeit) er dran war
  created_at  timestamptz not null default now()
);
create table if not exists public.battle_entries (
  id            bigint generated always as identity primary key,
  prompt_id     int    not null references public.battle_prompts on delete cascade,
  body          text   not null check (char_length(body) between 2 and 200),
  author_user   uuid   references auth.users on delete set null,
  author_name   text   not null,
  author_device uuid   not null,
  ip_hash       text,
  status        text   not null default 'visible' check (status in ('visible', 'removed')),
  up_count      int    not null default 0,
  down_count    int    not null default 0,
  created_at    timestamptz not null default now()
);
create index if not exists battle_entries_prompt on public.battle_entries (prompt_id);
create index if not exists battle_entries_user on public.battle_entries (author_user, created_at);
create table if not exists public.battle_votes (
  entry_id    bigint   not null references public.battle_entries on delete cascade,
  device_id   uuid     not null,
  ip_hash     text,
  value       smallint not null check (value in (-1, 1)),
  created_at  timestamptz not null default now(),
  primary key (entry_id, device_id)
);
create index if not exists battle_votes_ip on public.battle_votes (ip_hash, created_at);

-- Heutigen Anfang holen (beim ersten Aufruf des Tages wird der nächste aus dem Vorrat gezogen)
create or replace function public.get_battle_today()
returns table (id int, setup text, day date, entries int)
language plpgsql volatile security definer set search_path = public as $$
#variable_conflict use_column
declare
  d date := (now() at time zone 'Europe/Berlin')::date;
  v int;
begin
  select p.id into v from public.battle_prompts p where p.day = d;
  if v is null then
    begin
      update public.battle_prompts p set day = d
      where p.id = (select q.id from public.battle_prompts q where q.day is null order by q.id limit 1)
      returning p.id into v;
    exception when unique_violation then
      select p.id into v from public.battle_prompts p where p.day = d;
    end;
  end if;
  return query
    select p.id, p.setup, p.day,
           (select count(*) from public.battle_entries e where e.prompt_id = p.id and e.status = 'visible')::int
    from public.battle_prompts p where p.id = v;
end $$;

create or replace function public.get_battle_entries(p_device uuid, p_prompt int)
returns table (id bigint, body text, author_name text, created_at timestamptz, up_count int, down_count int,
               score double precision, is_own boolean, my_vote smallint)
language sql stable security definer set search_path = public as $$
  select e.id, e.body, e.author_name, e.created_at, e.up_count, e.down_count,
         public.wilson_lower(e.up_count, e.down_count),
         (e.author_device = p_device or e.author_user = auth.uid()) is true, v.value
  from public.battle_entries e
  left join public.battle_votes v on v.entry_id = e.id and v.device_id = p_device
  where e.prompt_id = p_prompt and e.status = 'visible'
  order by 7 desc, e.up_count desc, e.created_at
  limit 100
$$;

-- Vergangene Battles mit Sieger
create or replace function public.get_battle_archive(p_limit int default 7)
returns table (id int, setup text, day date, entries int, winner_body text, winner_name text, winner_up int)
language sql stable security definer set search_path = public as $$
  select p.id, p.setup, p.day,
         (select count(*) from public.battle_entries e where e.prompt_id = p.id and e.status = 'visible')::int,
         w.body, w.author_name, w.up_count
  from public.battle_prompts p
  left join lateral (
    select e.body, e.author_name, e.up_count from public.battle_entries e
    where e.prompt_id = p.id and e.status = 'visible' and e.up_count >= 1
    order by public.wilson_lower(e.up_count, e.down_count) desc, e.up_count desc, e.created_at limit 1) w on true
  where p.day is not null and p.day < (now() at time zone 'Europe/Berlin')::date
  order by p.day desc
  limit least(greatest(p_limit, 1), 60)
$$;

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

-- p_value: 1 = gut, -1 = schlecht, 0 = Stimme zurücknehmen
create or replace function public.vote_punchline(p_device uuid, p_entry bigint, p_value int)
returns table (up_count int, down_count int)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare
  h text := public.client_ip_hash();
  v_dev uuid; v_user uuid;
begin
  if p_device is null then raise exception 'invalid_device'; end if;
  if p_value is null or p_value not in (-1, 0, 1) then raise exception 'invalid_value'; end if;
  select e.author_device, e.author_user into v_dev, v_user from public.battle_entries e where e.id = p_entry and e.status = 'visible';
  if not found then raise exception 'joke_not_found'; end if;
  if v_dev = p_device or (v_user is not null and v_user = auth.uid()) then raise exception 'own_joke'; end if;
  if p_value = 0 then
    delete from public.battle_votes v where v.entry_id = p_entry and v.device_id = p_device;
  else
    if not exists (select 1 from public.battle_votes v where v.entry_id = p_entry and v.device_id = p_device) then
      if (select count(*) from public.battle_votes v where v.ip_hash = h and v.created_at > now() - interval '1 hour') >= 300 then
        raise exception 'rate_limited';
      end if;
      if (select count(*) from public.battle_votes v where v.entry_id = p_entry and v.ip_hash = h) >= 5 then
        raise exception 'ip_limit';
      end if;
    end if;
    insert into public.battle_votes (entry_id, device_id, ip_hash, value) values (p_entry, p_device, h, p_value)
    on conflict (entry_id, device_id) do update set value = excluded.value;
  end if;
  update public.battle_entries e set
    up_count   = (select count(*) from public.battle_votes v where v.entry_id = p_entry and v.value = 1),
    down_count = (select count(*) from public.battle_votes v where v.entry_id = p_entry and v.value = -1)
  where e.id = p_entry;
  return query select e.up_count, e.down_count from public.battle_entries e where e.id = p_entry;
end $$;

-- ───────────────────────── Monats-Saison ─────────────────────────

create table if not exists public.season_winners (
  month       date primary key,                 -- erster Tag des Monats
  user_id     uuid references auth.users on delete set null,
  username    text not null,
  score       double precision not null,
  crowned_at  timestamptz not null default now()
);

-- Krönt abgeschlossene Monate (max. 3 zurück): bester Autor nach Wilson-Score, mind. 10 Stimmen
create or replace function public.crown_seasons() returns void
language plpgsql security definer set search_path = public as $$
declare
  v_last date := (date_trunc('month', now() at time zone 'Europe/Berlin') - interval '1 month')::date;
  v_m    date;
  t0 timestamptz; t1 timestamptz;
begin
  select coalesce((max(s.month) + interval '1 month')::date, (v_last - interval '2 months')::date) into v_m from public.season_winners s;
  while v_m <= v_last loop
    t0 := v_m::timestamp at time zone 'Europe/Berlin';
    t1 := (v_m + interval '1 month')::timestamp at time zone 'Europe/Berlin';
    insert into public.season_winners (month, user_id, username, score)
    select v_m, p.id, p.username, public.wilson_lower(sum(j.up_count)::double precision, sum(j.down_count)::double precision)
    from public.jokes j join public.profiles p on p.id = j.author_user
    where j.status = 'visible' and j.created_at >= t0 and j.created_at < t1
    group by p.id, p.username
    having sum(j.up_count + j.down_count) >= 10
    order by 4 desc, sum(j.up_count) desc
    limit 1
    on conflict do nothing;
    v_m := (v_m + interval '1 month')::date;
  end loop;
end $$;

create or replace function public.get_season_winners(p_limit int default 12)
returns table (month date, username text, score double precision)
language plpgsql volatile security definer set search_path = public as $$
#variable_conflict use_column
begin
  perform public.crown_seasons();
  return query select s.month, s.username, s.score from public.season_winners s order by s.month desc limit least(greatest(p_limit, 1), 36);
end $$;

-- Autoren-Rangliste jetzt auch für den laufenden Monat ('month')
create or replace function public.get_author_ranking(p_range text, p_limit int default 30)
returns table (username text, jokes int, up_count int, down_count int, score double precision)
language sql stable security definer set search_path = public as $$
  select p.username, count(*)::int, sum(f.up_count)::int, sum(f.down_count)::int,
         public.wilson_lower(sum(f.up_count)::double precision, sum(f.down_count)::double precision)
  from public.joke_feed f
  join public.profiles p on p.id = f.author_user
  where f.status = 'visible'
    and case p_range
          when 'all'   then true
          when 'month' then f.created_at >= (date_trunc('month', now() at time zone 'Europe/Berlin') at time zone 'Europe/Berlin')
          else f.created_at > now() - interval '7 days'
        end
  group by p.id, p.username
  having sum(f.up_count + f.down_count) >= case when p_range = 'all' then 20 when p_range = 'month' then 10 else 5 end
  order by 5 desc, 3 desc
  limit least(greatest(p_limit, 1), 100)
$$;

-- Profil: zusätzlich gewonnene Saisons
drop function if exists public.get_profile(text);
create function public.get_profile(p_name text)
returns table (username text, member_since timestamptz, jokes int, up_count int, down_count int,
               top_up int, crowns int, challenge_wins int, best_rank int, season_wins int, punchlines int)
language sql stable security definer set search_path = public as $$
  select p.username, p.created_at,
         count(j.id)::int, coalesce(sum(j.up_count), 0)::int, coalesce(sum(j.down_count), 0)::int,
         coalesce(max(j.up_count), 0)::int,
         (select count(*) from public.daily_winners w join public.jokes x on x.id = w.joke_id where x.author_user = p.id)::int,
         (select count(*) from public.challenge_winners cw where cw.author_user = p.id)::int,
         (select min(r.rk) from (
            select f.author_user, row_number() over (order by f.score desc, f.up_count + f.down_count desc, f.created_at desc) as rk
            from public.joke_feed f where f.status = 'visible' and f.created_at > now() - interval '24 hours') r
          where r.author_user = p.id)::int,
         (select count(*) from public.season_winners s where s.user_id = p.id)::int,
         (select count(*) from public.battle_entries e where e.author_user = p.id and e.status = 'visible')::int
  from public.profiles p
  left join public.jokes j on j.author_user = p.id and j.status = 'visible' and j.created_at <= now()
  where lower(p.username) = lower(trim(p_name))
  group by p.id, p.username, p.created_at
$$;

-- ───────────────────────── Lieblingskategorien ─────────────────────────
-- Wie get_unrated bzw. get_duel, aber nur aus den gewählten Kategorien (leer = alle)

create or replace function public.get_unrated2(p_device uuid, p_exclude bigint[] default '{}', p_limit int default 10, p_cats text[] default null)
returns table (id bigint, body text, category_slug text, author_name text, created_at timestamptz,
               up_count int, down_count int, score double precision, is_own boolean, my_vote smallint)
language sql volatile security definer set search_path = public as $$
  select f.id, f.body, f.category_slug, f.author_name, f.created_at, f.up_count, f.down_count, f.score,
         false, null::smallint
  from public.joke_feed f
  where f.status = 'visible'
    and (p_cats is null or cardinality(p_cats) = 0 or f.category_slug = any(p_cats))
    and f.author_device <> p_device
    and (auth.uid() is null or f.author_user is null or f.author_user <> auth.uid())
    and not (f.id = any(coalesce(p_exclude, '{}')))
    and not exists (select 1 from public.votes v where v.joke_id = f.id and v.device_id = p_device)
  order by (f.up_count + f.down_count >= 20), (f.created_at < now() - interval '7 days'), random()
  limit least(greatest(p_limit, 1), 30)
$$;

create or replace function public.get_duel2(p_device uuid, p_cats text[] default null)
returns table (id bigint, body text, category_slug text, author_name text, created_at timestamptz,
               up_count int, down_count int, score double precision, is_own boolean, my_vote smallint)
language plpgsql volatile security definer set search_path = public as $$
#variable_conflict use_column
declare
  a bigint; a_elo double precision; b bigint;
  cats int[];
begin
  if p_device is null then raise exception 'invalid_device'; end if;
  if p_cats is not null and cardinality(p_cats) > 0 then
    select array_agg(c.id) into cats from public.categories c where c.slug = any(p_cats);
  end if;
  for i in 1..5 loop
    select j.id, j.elo into a, a_elo from public.jokes j
    where j.status = 'visible' and j.created_at <= now() and j.author_device <> p_device
      and (cats is null or j.category_id = any(cats))
      and (auth.uid() is null or j.author_user is null or j.author_user <> auth.uid())
    order by (j.duel_count < 10) desc, random()
    limit 1;
    if a is null then return; end if;
    select j.id into b from public.jokes j
    where j.status = 'visible' and j.created_at <= now() and j.id <> a and j.author_device <> p_device
      and (cats is null or j.category_id = any(cats))
      and (auth.uid() is null or j.author_user is null or j.author_user <> auth.uid())
      and not exists (select 1 from public.duel_votes d where d.device_id = p_device
                        and least(d.winner, d.loser) = least(a, j.id) and greatest(d.winner, d.loser) = greatest(a, j.id))
    order by abs(j.elo - a_elo) + random() * 150
    limit 1;
    exit when b is not null;
  end loop;
  if b is null then return; end if;
  return query
    select f.id, f.body, f.category_slug, f.author_name, f.created_at, f.up_count, f.down_count, f.score, false, v.value
    from public.joke_feed f
    left join public.votes v on v.joke_id = f.id and v.device_id = p_device
    where f.id in (a, b)
    order by random();
end $$;

-- ───────────────────────── Admin: Wortfilter und Battle ─────────────────────────

create or replace function public.admin_get_words(p_key text)
returns table (word text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.admin_check(p_key) then raise exception 'not_admin'; end if;
  return query select b.word from public.banned_words b order by b.word;
end $$;

-- Ersetzt die komplette Liste
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

create or replace function public.admin_add_prompts(p_key text, p_setups text[])
returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not public.admin_check(p_key) then raise exception 'not_admin'; end if;
  insert into public.battle_prompts (setup)
  select distinct trim(s) from unnest(coalesce(p_setups, '{}')) s where char_length(trim(s)) between 10 and 300
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

-- Vorrat an Anfängen und die neuesten Pointen (zum Moderieren)
create or replace function public.admin_battle(p_key text)
returns table (kind text, id bigint, text1 text, text2 text, at timestamptz)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not public.admin_check(p_key) then raise exception 'not_admin'; end if;
  return query
    (select 'prompt'::text, p.id::bigint, p.setup, null::text, p.created_at
     from public.battle_prompts p where p.day is null order by p.id limit 100)
    union all
    (select 'entry', e.id, e.body, e.author_name, e.created_at
     from public.battle_entries e where e.status = 'visible' order by e.created_at desc limit 50);
end $$;

create or replace function public.admin_remove_punchline(p_key text, p_entry bigint)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.admin_check(p_key) then raise exception 'not_admin'; end if;
  update public.battle_entries e set status = 'removed' where e.id = p_entry;
end $$;

-- ───────────────────────── Rechte ─────────────────────────

alter table public.banned_words   enable row level security;
alter table public.battle_prompts enable row level security;
alter table public.battle_entries enable row level security;
alter table public.battle_votes   enable row level security;
alter table public.season_winners enable row level security;

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
  public.admin_save_challenge(text, int, text, text, timestamptz, timestamptz),
  public.admin_stats(text, int),
  public.admin_totals(text),
  public.admin_category_stats(text),
  public.admin_bulk_add(text, text, text[], int),
  public.admin_get_words(text),
  public.admin_set_words(text, text[]),
  public.admin_add_prompts(text, text[]),
  public.admin_battle(text),
  public.admin_remove_punchline(text, bigint)
to anon, authenticated;

-- ───────────────────────── Start-Vorrat für das Pointen-Battle ─────────────────────────
insert into public.battle_prompts (setup) values
  ('Treffen sich zwei Hanteln im Fitnessstudio. Sagt die eine: …'),
  ('Warum nimmt der Pinguin immer einen Regenschirm mit?'),
  ('Was sagt der Toaster morgens zum Kühlschrank?'),
  ('Chef: „Sie wollen mehr Gehalt? Nennen Sie mir einen guten Grund.“ Ich: …'),
  ('Warum ist die Kaffeemaschine im Büro beleidigt?'),
  ('Was steht auf dem Grabstein eines Navis?'),
  ('Fritzchen kommt zu spät. Lehrerin: „Und was ist heute deine Ausrede?“ Fritzchen: …'),
  ('Warum hat die Giraffe kein Handy?'),
  ('Was macht ein Schneemann im Sommerurlaub?'),
  ('Was sagt das WLAN, wenn es Feierabend hat?'),
  ('Zwei Tomaten gehen über die Straße. Sagt die eine: …'),
  ('Warum trägt der Oktopus acht verschiedene Socken?'),
  ('Was denkt das Laufband, wenn den ganzen Tag keiner kommt?'),
  ('Mein Kühlschrank hat mir heute eine Nachricht geschrieben: …'),
  ('Warum ging der Kaktus zum Friseur?'),
  ('Was sagt der Drucker, wenn man ihn wirklich dringend braucht?'),
  ('Wie nennt man einen Vampir, der nur Gemüse isst?'),
  ('Der Wetterbericht für morgen: …'),
  ('Warum hat der Mond nie Hunger?'),
  ('Ein Igel, ein Luftballon und ein Kaktus gehen in eine Bar. Sagt der Barkeeper: …'),
  ('Was sagt die Socke, die in der Waschmaschine verschwunden ist?'),
  ('Warum hat der Elefant kein Social Media?'),
  ('Oma hat ihr erstes Smartphone. Ihre erste Nachricht in der Familiengruppe: …'),
  ('Was macht ein Gespenst im Fitnessstudio?'),
  ('Was steht im Lebenslauf eines Faultiers?'),
  ('Der Wecker klingelt. Ich: …'),
  ('Was sagt der Bleistift zum Radiergummi?'),
  ('Warum streiten sich Gabel und Löffel in der Schublade?'),
  ('Was ist das Lieblingsessen eines Computers?'),
  ('Mein Trainer sagt: „Noch zehn Wiederholungen!“ Ich: …')
on conflict do nothing;
