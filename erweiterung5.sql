-- ═══════════════════════════════════════════════════════════════════
-- Lachwerk – Erweiterung 5: Push-Nachrichten
-- Teil 1 (diese Datei): Abos speichern, öffentlicher Schlüssel, Zeitplan.
-- Teil 2: Edge Function „push“ (Datei supabase/functions/push/index.ts),
--         im Supabase-Dashboard unter Edge Functions anlegen, „Verify JWT“ aus.
--
-- Die Schlüssel (VAPID) erzeugt die Edge Function beim ersten Aufruf selbst und legt sie
-- in public.settings ab. Niemand muss einen geheimen Schlüssel abtippen.
-- Mehrfach ausführen ist unschädlich.
-- ═══════════════════════════════════════════════════════════════════

create extension if not exists pg_net;
create extension if not exists pg_cron;

create table if not exists public.push_subscriptions (
  endpoint    text primary key check (endpoint ~ '^https://' and char_length(endpoint) <= 1000),
  p256dh      text not null check (char_length(p256dh) <= 200),
  auth        text not null check (char_length(auth) <= 100),
  device_id   uuid not null,
  user_id     uuid references auth.users on delete cascade,
  topics      text[] not null default '{daily}',
  created_at  timestamptz not null default now(),
  last_sent   timestamptz,
  fails       int not null default 0
);
create index if not exists push_subscriptions_user on public.push_subscriptions (user_id);
alter table public.push_subscriptions enable row level security;

-- Öffentlicher Schlüssel für den Browser (null, solange die Edge Function noch nie lief)
create or replace function public.get_push_key() returns text
language sql stable security definer set search_path = public as $$
  select nullif(s.value, '') from public.settings s where s.key = 'vapid_public'
$$;

-- Abo speichern bzw. aktualisieren. p_sub ist das JSON von PushSubscription.toJSON().
create or replace function public.push_subscribe(p_device uuid, p_sub json, p_topics text[] default '{daily}')
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_end text := p_sub ->> 'endpoint';
begin
  if p_device is null or v_end is null then raise exception 'invalid_value'; end if;
  if (select count(*) from public.push_subscriptions s where s.device_id = p_device) >= 5 then
    delete from public.push_subscriptions s where s.device_id = p_device and s.endpoint <> v_end;
  end if;
  insert into public.push_subscriptions (endpoint, p256dh, auth, device_id, user_id, topics)
  values (v_end, p_sub -> 'keys' ->> 'p256dh', p_sub -> 'keys' ->> 'auth', p_device, auth.uid(),
          coalesce((select array_agg(t) from unnest(p_topics) t where t in ('daily', 'battle', 'mine')), '{daily}'))
  on conflict (endpoint) do update set p256dh = excluded.p256dh, auth = excluded.auth, device_id = excluded.device_id,
     user_id = coalesce(excluded.user_id, push_subscriptions.user_id), topics = excluded.topics, fails = 0;
end $$;

create or replace function public.push_unsubscribe(p_endpoint text) returns void
language sql security definer set search_path = public as $$
  delete from public.push_subscriptions s where s.endpoint = p_endpoint
$$;

-- Für den Admin-Bereich: Anzahl der Abos
create or replace function public.admin_push_stats(p_key text)
returns table (subs int, daily int, battle int, mine int, last_daily text, ready boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.admin_check(p_key) then raise exception 'not_admin'; end if;
  return query select
    (select count(*) from public.push_subscriptions)::int,
    (select count(*) from public.push_subscriptions s where 'daily' = any(s.topics))::int,
    (select count(*) from public.push_subscriptions s where 'battle' = any(s.topics))::int,
    (select count(*) from public.push_subscriptions s where 'mine' = any(s.topics))::int,
    (select s.value from public.settings s where s.key = 'push_last_daily'),
    exists (select 1 from public.settings s where s.key = 'vapid_public');
end $$;

-- ───────────────────────── Zeitplan ─────────────────────────
-- Ruft die Edge Function täglich um 18:05 und 19:05 UTC auf (= 20:05 deutsche Sommer- bzw. Winterzeit).
-- Die Funktion selbst prüft, dass es in Deutschland nach 20 Uhr ist und heute noch nichts verschickt wurde.
select cron.unschedule(j.jobid) from cron.job j where j.jobname = 'lachwerk-daily-push';
select cron.schedule('lachwerk-daily-push', '5 18,19 * * *', $cron$
  select net.http_post(
    url := 'https://yssqvkhmglwdxvjurxag.supabase.co/functions/v1/push',
    headers := '{"Content-Type": "application/json", "apikey": "sb_publishable_TI6LLkRXgR6BIR9TykIBPg_KCItfwho"}'::jsonb,
    body := '{"type": "daily"}'::jsonb)
$cron$);
-- Battle-Erinnerung um 12:05 deutscher Zeit (10:05 und 11:05 UTC, die Funktion prüft die Uhrzeit)
select cron.unschedule(j.jobid) from cron.job j where j.jobname = 'lachwerk-battle-push';
select cron.schedule('lachwerk-battle-push', '5 10,11 * * *', $cron$
  select net.http_post(
    url := 'https://yssqvkhmglwdxvjurxag.supabase.co/functions/v1/push',
    headers := '{"Content-Type": "application/json", "apikey": "sb_publishable_TI6LLkRXgR6BIR9TykIBPg_KCItfwho"}'::jsonb,
    body := '{"type": "battle"}'::jsonb)
$cron$);

-- ───────────────────────── Rechte ─────────────────────────
revoke all on public.push_subscriptions from anon, authenticated;
revoke execute on function public.get_push_key(), public.push_subscribe(uuid, json, text[]), public.push_unsubscribe(text),
  public.admin_push_stats(text) from public;
grant execute on function public.get_push_key(), public.push_subscribe(uuid, json, text[]), public.push_unsubscribe(text),
  public.admin_push_stats(text) to anon, authenticated;
-- Die Edge Function arbeitet mit der Rolle service_role (nur auf dem Server verfügbar)
grant execute on all functions in schema public to service_role;
grant all on all tables in schema public to service_role;
