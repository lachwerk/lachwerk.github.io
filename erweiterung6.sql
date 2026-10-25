-- ═══════════════════════════════════════════════════════════════════
-- Lachwerk – Erweiterung 6: Konto selbst löschen, Pointen melden
-- Setzt erweiterung.sql bis erweiterung5.sql voraus. Mehrfach ausführen ist unschädlich.
-- ═══════════════════════════════════════════════════════════════════

-- ───────────────────────── Konto selbst löschen ─────────────────────────
-- p_with_content = true: auch alle eigenen Witze und Pointen endgültig löschen.
-- Sonst bleiben sie erhalten, aber ohne Verbindung zum Konto und mit dem Namen „Gelöschtes Konto“.
create or replace function public.delete_my_account(p_with_content boolean default false)
returns void
language plpgsql security definer set search_path = public, auth as $$
declare v_user uuid := auth.uid();
begin
  if v_user is null then raise exception 'not_logged_in'; end if;
  if p_with_content then
    delete from public.jokes j where j.author_user = v_user;
    delete from public.battle_entries e where e.author_user = v_user;
  else
    update public.jokes j set author_name = 'Gelöschtes Konto' where j.author_user = v_user;
    update public.battle_entries e set author_name = 'Gelöschtes Konto' where e.author_user = v_user;
  end if;
  -- Konto löschen: Profil, Push-Abos usw. hängen per „on delete cascade“ daran,
  -- verbleibende Witze/Pointen per „on delete set null“
  delete from auth.users u where u.id = v_user;
end $$;

-- ───────────────────────── Pointen melden ─────────────────────────
alter table public.battle_entries add column if not exists report_count int not null default 0;
alter table public.battle_entries add column if not exists reviewed_at  timestamptz;
alter table public.battle_entries drop constraint if exists battle_entries_status_check;
alter table public.battle_entries add constraint battle_entries_status_check check (status in ('visible', 'hidden', 'removed'));

create table if not exists public.battle_reports (
  entry_id    bigint not null references public.battle_entries on delete cascade,
  device_id   uuid   not null,
  ip_hash     text,
  created_at  timestamptz not null default now(),
  primary key (entry_id, device_id)
);
alter table public.battle_reports enable row level security;

-- Ab 3 Meldungen von verschiedenen Anschlüssen ausgeblendet, nach einer Freigabe erst ab 10
create or replace function public.report_punchline(p_device uuid, p_entry bigint) returns void
language plpgsql security definer set search_path = public as $$
declare
  h     text := public.client_ip_hash();
  v_cnt int;
begin
  if p_device is null then raise exception 'invalid_device'; end if;
  if not exists (select 1 from public.battle_entries e where e.id = p_entry and e.status = 'visible') then
    raise exception 'joke_not_found';
  end if;
  insert into public.battle_reports (entry_id, device_id, ip_hash) values (p_entry, p_device, h) on conflict do nothing;
  select count(distinct coalesce(r.ip_hash, r.device_id::text)) into v_cnt from public.battle_reports r where r.entry_id = p_entry;
  update public.battle_entries e set
    report_count = v_cnt,
    status = case when e.status = 'visible' and v_cnt >= (case when e.reviewed_at is null then 3 else 10 end) then 'hidden' else e.status end
  where e.id = p_entry;
end $$;

-- Admin: zusätzlich gemeldete bzw. ausgeblendete Pointen (kind = 'reported')
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
    (select 'reported', e.id, e.body, e.author_name || ' · ' || e.report_count || ' Meldungen' || case when e.status = 'hidden' then ' · ausgeblendet' else '' end, e.created_at
     from public.battle_entries e where e.status = 'hidden' or (e.status = 'visible' and e.report_count > 0)
     order by e.status desc, e.report_count desc limit 50)
    union all
    (select 'entry', e.id, e.body, e.author_name, e.created_at
     from public.battle_entries e where e.status = 'visible' order by e.created_at desc limit 50);
end $$;

create or replace function public.admin_approve_punchline(p_key text, p_entry bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.admin_check(p_key) then raise exception 'not_admin'; end if;
  delete from public.battle_reports r where r.entry_id = p_entry;
  update public.battle_entries e set status = 'visible', report_count = 0, reviewed_at = now() where e.id = p_entry;
end $$;

-- Übersicht: offene Meldungen zählen jetzt auch Pointen mit
create or replace function public.admin_open_punch_reports(p_key text) returns int
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.admin_check(p_key) then raise exception 'not_admin'; end if;
  return (select count(*) from public.battle_entries e where e.status = 'hidden' or (e.status = 'visible' and e.report_count > 0));
end $$;

-- ───────────────────────── Rechte ─────────────────────────
revoke all on public.battle_reports from anon, authenticated;
revoke execute on function public.delete_my_account(boolean), public.report_punchline(uuid, bigint),
  public.admin_battle(text), public.admin_approve_punchline(text, bigint), public.admin_open_punch_reports(text) from public;
grant execute on function public.delete_my_account(boolean) to authenticated;
grant execute on function public.report_punchline(uuid, bigint), public.admin_battle(text),
  public.admin_approve_punchline(text, bigint), public.admin_open_punch_reports(text) to anon, authenticated;
grant execute on all functions in schema public to service_role;
grant all on all tables in schema public to service_role;
