-- ═══════════════════════════════════════════════════════════════════
-- Lachwerk – Erweiterung 11: Witze-Suche, Erfolgs-Nachrichten für Autoren
-- Setzt die bisherigen Erweiterungen voraus. Mehrfach ausführen ist unschädlich.
-- ═══════════════════════════════════════════════════════════════════

-- ───────────────────────── Suche ─────────────────────────
-- Alle Suchwörter (ab 2 Zeichen, höchstens 6) müssen im Witz vorkommen; sortiert nach Score
create or replace function public.search_jokes(p_device uuid, p_query text, p_category text default null,
                                               p_limit int default 30, p_offset int default 0)
returns table (id bigint, body text, category_slug text, author_name text, created_at timestamptz,
               up_count int, down_count int, score double precision, is_own boolean, my_vote smallint)
language sql stable security definer set search_path = public, extensions as $$
  with terms as (
    select array_agg(t) as a from (
      select t from regexp_split_to_table(public.normalize_joke(left(coalesce(p_query, ''), 100)), '\s+') t
      where char_length(t) >= 2 limit 6) x)
  select f.id, f.body, f.category_slug, f.author_name, f.created_at, f.up_count, f.down_count, f.score,
         (f.author_device = p_device or f.author_user = auth.uid()) is true, v.value
  from public.joke_feed f
  join public.jokes j on j.id = f.id
  cross join terms
  left join public.votes v on v.joke_id = f.id and v.device_id = p_device
  where f.status = 'visible' and terms.a is not null
    and (p_category is null or f.category_slug = p_category)
    and not exists (select 1 from unnest(terms.a) t where j.body_norm not like '%' || t || '%')
  order by f.score desc, f.up_count + f.down_count desc, f.created_at desc
  limit least(greatest(p_limit, 1), 50) offset greatest(p_offset, 0)
$$;

-- ───────────────────────── Erfolge für Autoren ─────────────────────────
-- Jeder Meilenstein wird pro Witz nur einmal gemeldet
create table if not exists public.joke_milestones (
  joke_id     bigint not null references public.jokes on delete cascade,
  kind        text   not null,
  created_at  timestamptz not null default now(),
  primary key (joke_id, kind)
);
alter table public.joke_milestones enable row level security;

-- Neue Meilensteine abholen und als erledigt markieren (nur für die Edge Function „push“).
-- Pro Witz kommt nur der wichtigste neue Meilenstein zurück.
create or replace function public.take_milestones()
returns table (joke_id bigint, user_id uuid, kind text, likes int, body text)
language plpgsql security definer set search_path = public as $$
begin
  return query
  with day_rank as (
    select f.id, row_number() over (order by f.score desc, f.up_count + f.down_count desc, f.created_at desc) as rn
    from public.joke_feed f
    where f.status = 'visible' and f.created_at > now() - interval '24 hours'),
  cand as (
    select j.id, j.author_user, k.kind, k.prio
    from public.jokes j
    left join day_rank d on d.id = j.id
    cross join lateral (values
      ('day1',     100, coalesce(d.rn = 1, false) and j.up_count >= 3),
      ('top3',      90, coalesce(d.rn <= 3, false) and j.up_count >= 3),
      ('likes500',  60, j.up_count >= 500),
      ('likes250',  55, j.up_count >= 250),
      ('likes100',  50, j.up_count >= 100),
      ('likes50',   40, j.up_count >= 50),
      ('likes25',   30, j.up_count >= 25),
      ('likes10',   20, j.up_count >= 10)) as k(kind, prio, ok)
    where j.status = 'visible' and j.author_user is not null and k.ok
      and not exists (select 1 from public.joke_milestones m where m.joke_id = j.id and m.kind = k.kind)),
  ins as (
    insert into public.joke_milestones (joke_id, kind) select c.id, c.kind from cand c on conflict do nothing returning 1),
  best as (
    select distinct on (c.id) c.id, c.author_user, c.kind from cand c order by c.id, c.prio desc)
  select b.id, b.author_user, b.kind, j.up_count, j.body
  from best b join public.jokes j on j.id = b.id
  where (select count(*) from ins) >= 0;
end $$;

-- Bisher schon erreichte Meilensteine still als erledigt markieren (keine Nachrichten für Altes)
select count(*) from public.take_milestones();

-- Alle 15 Minuten prüfen; die Edge Function schickt nur zwischen 8 und 22 Uhr
select cron.unschedule(j.jobid) from cron.job j where j.jobname = 'lachwerk-milestones-push';
select cron.schedule('lachwerk-milestones-push', '*/15 * * * *', $cron$
  select net.http_post(
    url := 'https://yssqvkhmglwdxvjurxag.supabase.co/functions/v1/push',
    headers := '{"Content-Type": "application/json", "apikey": "sb_publishable_TI6LLkRXgR6BIR9TykIBPg_KCItfwho"}'::jsonb,
    body := '{"type": "milestones"}'::jsonb)
$cron$);

-- ───────────────────────── Rechte ─────────────────────────
revoke all on public.joke_milestones from anon, authenticated;
revoke execute on function public.take_milestones() from public, anon, authenticated;
revoke execute on function public.search_jokes(uuid, text, text, int, int) from public;
grant execute on function public.search_jokes(uuid, text, text, int, int) to anon, authenticated;
grant execute on all functions in schema public to service_role;
grant all on all tables in schema public to service_role;
