-- ═══════════════════════════════════════════════════════════════════
-- Lachwerk – Datenbank für die Version OHNE Anmeldung
-- Einmal komplett im Supabase SQL Editor ausführen (Run).
-- Danach unten den Admin-Schlüssel setzen (letzte Zeile).
-- ═══════════════════════════════════════════════════════════════════
--
-- Prinzip: Lesen, Liken und Bewerten geht ohne Konto (zufällige Geräte-ID im Browser).
-- Zum POSTEN braucht man ein Konto (Supabase Auth, E-Mail + Passwort).
-- Besucher greifen NIE direkt auf Tabellen zu, sondern nur über die
-- Funktionen unten. Die prüfen Limits, Duplikate und eigene Witze.
-- IP-Adressen werden nur gesalzen gehasht gespeichert.

create schema if not exists extensions;
create extension if not exists pg_trgm  with schema extensions;
create extension if not exists pgcrypto with schema extensions;

-- ───────────────────────── Tabellen ─────────────────────────

create table public.settings (
  key   text primary key,
  value text not null
);
insert into public.settings (key, value)
values ('ip_salt', encode(extensions.gen_random_bytes(16), 'hex'));

create table public.categories (
  id        serial primary key,
  slug      text unique not null,
  name      text not null,
  position  int not null default 0
);

-- Konten: Supabase Auth verwaltet E-Mail und Passwort (auth.users),
-- hier liegt nur der öffentliche Benutzername.
create table public.profiles (
  id          uuid primary key references auth.users on delete cascade,
  username    text not null check (username ~ '^[A-Za-z0-9_.äöüÄÖÜß]{3,20}$'),
  created_at  timestamptz not null default now()
);
create unique index profiles_username_lower on public.profiles (lower(username));

-- Bei jeder Registrierung automatisch ein Profil anlegen (Name aus den Anmeldedaten)
create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_name text := trim(coalesce(new.raw_user_meta_data ->> 'username', ''));
  i      int  := 0;
begin
  -- Ungültiger oder schon vergebener Name: Ersatzname wählen (die Registrierung darf nie scheitern)
  while v_name !~ '^[A-Za-z0-9_.äöüÄÖÜß]{3,20}$'
        or exists (select 1 from public.profiles p where lower(p.username) = lower(v_name)) loop
    i := i + 1;
    v_name := 'nutzer_' || substr(md5(new.id::text || i::text), 1, 10);
  end loop;
  insert into public.profiles (id, username) values (new.id, v_name);
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Text vereinheitlichen (für den Duplikat-Check)
create function public.normalize_joke(t text) returns text
language sql immutable as $$
  select trim(regexp_replace(lower(t), '[^[:alnum:]]+', ' ', 'g'))
$$;

create table public.jokes (
  id             bigint generated always as identity primary key,
  category_id    int  not null references public.categories,
  body           text not null check (char_length(body) between 10 and 500),
  body_norm      text generated always as (public.normalize_joke(body)) stored,
  author_name    text not null check (char_length(author_name) between 2 and 24),
  author_device  uuid not null,
  author_user    uuid references auth.users on delete set null,   -- Konto des Verfassers
  ip_hash        text,
  status         text not null default 'visible' check (status in ('visible', 'hidden', 'removed')),
  up_count       int  not null default 0,
  down_count     int  not null default 0,
  report_count   int  not null default 0,
  reviewed_at    timestamptz,                 -- gesetzt, sobald die Moderation geprüft hat
  created_at     timestamptz not null default now()
);
create index jokes_visible_recent on public.jokes (created_at desc) where status = 'visible';
create index jokes_device_recent  on public.jokes (author_device, created_at desc);
create index jokes_user_recent    on public.jokes (author_user, created_at desc);
create index jokes_ip_recent      on public.jokes (ip_hash, created_at desc);
create index jokes_body_trgm      on public.jokes using gin (body_norm extensions.gin_trgm_ops);

create table public.votes (
  joke_id     bigint   not null references public.jokes on delete cascade,
  device_id   uuid     not null,
  ip_hash     text,
  value       smallint not null check (value in (-1, 1)),
  created_at  timestamptz not null default now(),
  primary key (joke_id, device_id)
);
create index votes_ip_recent  on public.votes (ip_hash, created_at);
create index votes_joke_ip    on public.votes (joke_id, ip_hash);
create index votes_device     on public.votes (device_id);

create table public.reports (
  joke_id     bigint not null references public.jokes on delete cascade,
  device_id   uuid   not null,
  ip_hash     text,
  created_at  timestamptz not null default now(),
  primary key (joke_id, device_id)
);

-- ───────────────────────── Hilfsfunktionen ─────────────────────────

-- IP des Aufrufers (von Supabase im Header übergeben), gesalzen gehasht
create function public.client_ip_hash() returns text
language sql stable security definer set search_path = public, extensions as $$
  select encode(digest(
    coalesce(trim(split_part(nullif(current_setting('request.headers', true), '')::json ->> 'x-forwarded-for', ',', 1)), '')
    || (select s.value from public.settings s where s.key = 'ip_salt'),
    'sha256'), 'hex')
$$;

-- Wilson-Score (Untergrenze, 95 %): faire Sortierung auch bei wenigen Stimmen
create function public.wilson_lower(up double precision, down double precision)
returns double precision language sql immutable as $$
  select case when up + down <= 0 then 0 else
    ( up/(up+down) + 1.9208/(up+down)
      - 1.96 * sqrt( (up/(up+down)) * (1 - up/(up+down)) / (up+down) + 0.9604/((up+down)*(up+down)) ) )
    / (1 + 3.8416/(up+down))
  end
$$;

create view public.joke_feed as
  select j.id, j.body, c.slug as category_slug, j.author_name, j.author_device, j.author_user, j.created_at,
         j.up_count, j.down_count, j.report_count, j.status, j.reviewed_at,
         public.wilson_lower(j.up_count, j.down_count) as score
  from public.jokes j
  join public.categories c on c.id = j.category_id
  where j.created_at <= now();   -- vorgeplante Witze erscheinen erst an ihrem Tag

-- ───────────────────────── Lesen ─────────────────────────

-- Ranking: day = letzte 24 h, week = letzte 7 Tage, all = ab 20 Stimmen
create function public.get_ranking(p_device uuid, p_range text, p_category text default null,
                                   p_limit int default 30, p_offset int default 0)
returns table (id bigint, body text, category_slug text, author_name text, created_at timestamptz,
               up_count int, down_count int, score double precision, is_own boolean, my_vote smallint)
language sql stable security definer set search_path = public as $$
  select f.id, f.body, f.category_slug, f.author_name, f.created_at, f.up_count, f.down_count, f.score,
         (f.author_device = p_device or f.author_user = auth.uid()) is true, v.value
  from public.joke_feed f
  left join public.votes v on v.joke_id = f.id and v.device_id = p_device
  where f.status = 'visible'
    and (p_category is null or f.category_slug = p_category)
    and case p_range
          when 'day'  then f.created_at > now() - interval '24 hours'
          when 'week' then f.created_at > now() - interval '7 days'
          else f.up_count + f.down_count >= 20
        end
  order by f.score desc, f.up_count + f.down_count desc, f.created_at desc
  limit least(greatest(p_limit, 1), 100) offset greatest(p_offset, 0)
$$;

create function public.get_joke(p_device uuid, p_id bigint)
returns table (id bigint, body text, category_slug text, author_name text, created_at timestamptz,
               up_count int, down_count int, score double precision, is_own boolean, my_vote smallint)
language sql stable security definer set search_path = public as $$
  select f.id, f.body, f.category_slug, f.author_name, f.created_at, f.up_count, f.down_count, f.score,
         (f.author_device = p_device or f.author_user = auth.uid()) is true, v.value
  from public.joke_feed f
  left join public.votes v on v.joke_id = f.id and v.device_id = p_device
  where f.id = p_id and f.status = 'visible'
$$;

-- Swipe-Modus: noch nicht bewertete Witze, zuerst die mit unter 20 Stimmen
create function public.get_unrated(p_device uuid, p_exclude bigint[] default '{}', p_limit int default 10)
returns table (id bigint, body text, category_slug text, author_name text, created_at timestamptz,
               up_count int, down_count int, score double precision, is_own boolean, my_vote smallint)
language sql volatile security definer set search_path = public as $$
  select f.id, f.body, f.category_slug, f.author_name, f.created_at, f.up_count, f.down_count, f.score,
         false, null::smallint
  from public.joke_feed f
  where f.status = 'visible'
    and f.author_device <> p_device
    and (auth.uid() is null or f.author_user is null or f.author_user <> auth.uid())
    and not (f.id = any(coalesce(p_exclude, '{}')))
    and not exists (select 1 from public.votes v where v.joke_id = f.id and v.device_id = p_device)
  order by (f.up_count + f.down_count >= 20), (f.created_at < now() - interval '7 days'), random()
  limit least(greatest(p_limit, 1), 30)
$$;

-- Gibt es den Witz schon? (Live-Hinweis beim Tippen)
create function public.find_similar(p_body text)
returns table (id bigint, body text, match real)
language sql stable security definer set search_path = public, extensions as $$
  select j.id, j.body, similarity(j.body_norm, public.normalize_joke(p_body))
  from public.jokes j
  where j.status = 'visible'
    and j.body_norm % public.normalize_joke(p_body)
    and similarity(j.body_norm, public.normalize_joke(p_body)) >= 0.6
  order by 3 desc
  limit 1
$$;

-- ───────────────────────── Schreiben ─────────────────────────

-- Abstimmen. p_value: 1 = Like, -1 = Dislike, 0 = Stimme zurücknehmen
create function public.cast_vote(p_device uuid, p_joke bigint, p_value int)
returns table (up_count int, down_count int)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare
  h        text := public.client_ip_hash();
  v_author uuid;
  v_user   uuid;
begin
  if p_device is null then raise exception 'invalid_device'; end if;
  if p_value is null or p_value not in (-1, 0, 1) then raise exception 'invalid_value'; end if;

  select j.author_device, j.author_user into v_author, v_user from public.jokes j where j.id = p_joke and j.status = 'visible';
  if not found then raise exception 'joke_not_found'; end if;
  if v_author = p_device or (v_user is not null and v_user = auth.uid()) then raise exception 'own_joke'; end if;

  if p_value = 0 then
    delete from public.votes v where v.joke_id = p_joke and v.device_id = p_device;
  else
    if not exists (select 1 from public.votes v where v.joke_id = p_joke and v.device_id = p_device) then
      -- max. 300 neue Stimmen pro Stunde und IP
      if (select count(*) from public.votes v where v.ip_hash = h and v.created_at > now() - interval '1 hour') >= 300 then
        raise exception 'rate_limited';
      end if;
      -- max. 5 Stimmen pro Witz und IP (WG, Familie, Firmennetz); bremst Mehrfach-Votes per Inkognito-Fenster
      if (select count(*) from public.votes v where v.joke_id = p_joke and v.ip_hash = h) >= 5 then
        raise exception 'ip_limit';
      end if;
    end if;
    insert into public.votes (joke_id, device_id, ip_hash, value)
    values (p_joke, p_device, h, p_value)
    on conflict (joke_id, device_id) do update set value = excluded.value;
  end if;

  update public.jokes j set
    up_count   = (select count(*) from public.votes v where v.joke_id = p_joke and v.value = 1),
    down_count = (select count(*) from public.votes v where v.joke_id = p_joke and v.value = -1)
  where j.id = p_joke;

  return query select j.up_count, j.down_count from public.jokes j where j.id = p_joke;
end $$;

-- Witz posten: NUR mit Konto. Der Name kommt aus dem Profil. Gibt die neue ID zurück.
create function public.post_joke(p_device uuid, p_category text, p_body text)
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

  select c.id into v_cat from public.categories c where c.slug = p_category;
  if v_cat is null then raise exception 'invalid_category'; end if;

  -- max. 10 Witze pro Konto und 20 pro IP in 24 Stunden
  if (select count(*) from public.jokes j where j.author_user = v_user and j.created_at > now() - interval '24 hours') >= 10
     or (select count(*) from public.jokes j where j.ip_hash = h and j.created_at > now() - interval '24 hours') >= 20 then
    raise exception 'post_limit';
  end if;

  -- Duplikat: ab 60 % Ähnlichkeit mit einem sichtbaren Witz
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

-- Ist ein Benutzername noch frei? (für die Registrierung)
create function public.username_available(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select trim(coalesce(p_name, '')) ~ '^[A-Za-z0-9_.äöüÄÖÜß]{3,20}$'
     and not exists (select 1 from public.profiles p where lower(p.username) = lower(trim(p_name)))
$$;

-- Eigenes Profil (nach dem Anmelden)
create function public.my_profile() returns table (username text)
language sql stable security definer set search_path = public as $$
  select p.username from public.profiles p where p.id = auth.uid()
$$;

-- Melden. Ab 3 Meldungen von verschiedenen Anschlüssen ausgeblendet,
-- nach einer Freigabe durch die Moderation erst ab 10.
create function public.report_joke(p_device uuid, p_joke bigint)
returns void
language plpgsql security definer set search_path = public as $$
declare
  h     text := public.client_ip_hash();
  v_cnt int;
begin
  if p_device is null then raise exception 'invalid_device'; end if;
  if not exists (select 1 from public.jokes j where j.id = p_joke and j.status = 'visible') then
    raise exception 'joke_not_found';
  end if;

  insert into public.reports (joke_id, device_id, ip_hash) values (p_joke, p_device, h)
  on conflict do nothing;

  select count(distinct coalesce(r.ip_hash, r.device_id::text)) into v_cnt
  from public.reports r where r.joke_id = p_joke;

  update public.jokes j set
    report_count = v_cnt,
    status = case
      when j.status = 'visible' and v_cnt >= (case when j.reviewed_at is null then 3 else 10 end) then 'hidden'
      else j.status end
  where j.id = p_joke;
end $$;

-- ───────────────────────── Moderation (per Admin-Schlüssel) ─────────────────────────

-- Nur im SQL Editor aufrufbar (siehe ganz unten)
create function public.set_admin_key(p_key text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if char_length(coalesce(p_key, '')) < 12 then
    raise exception 'Der Admin-Schlüssel braucht mindestens 12 Zeichen.';
  end if;
  insert into public.settings (key, value) values ('admin_key', crypt(p_key, gen_salt('bf')))
  on conflict (key) do update set value = excluded.value;
end $$;

create function public.admin_check(p_key text) returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select char_length(coalesce(p_key, '')) >= 12
     and coalesce((select s.value = crypt(p_key, s.value) from public.settings s where s.key = 'admin_key'), false)
$$;

-- p_view: 'gemeldet' (ausgeblendet oder gemeldet) oder 'neu' (neueste sichtbare)
create function public.admin_list(p_key text, p_view text)
returns table (id bigint, body text, category_slug text, author_name text, created_at timestamptz,
               up_count int, down_count int, report_count int, status text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.admin_check(p_key) then raise exception 'not_admin'; end if;
  if p_view = 'neu' then
    return query
      select f.id, f.body, f.category_slug, f.author_name, f.created_at, f.up_count, f.down_count, f.report_count, f.status
      from public.joke_feed f where f.status = 'visible'
      order by f.created_at desc limit 50;
  else
    return query
      select f.id, f.body, f.category_slug, f.author_name, f.created_at, f.up_count, f.down_count, f.report_count, f.status
      from public.joke_feed f
      where f.status = 'hidden' or (f.status = 'visible' and f.report_count > 0)
      order by f.status asc, f.report_count desc, f.created_at desc limit 100;
  end if;
end $$;

-- p_status: 'visible' = freigeben (Meldungen verwerfen), 'removed' = entfernen
create function public.admin_set_status(p_key text, p_joke bigint, p_status text)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.admin_check(p_key) then raise exception 'not_admin'; end if;
  if p_status = 'visible' then
    delete from public.reports r where r.joke_id = p_joke;
    update public.jokes j set status = 'visible', report_count = 0, reviewed_at = now() where j.id = p_joke;
  elsif p_status = 'removed' then
    update public.jokes j set status = 'removed', reviewed_at = now() where j.id = p_joke;
  else
    raise exception 'invalid_status';
  end if;
end $$;

-- ───────────────────────── Rechte ─────────────────────────
-- Besucher (anon) dürfen keine Tabelle direkt lesen oder schreiben, nur die Funktionen aufrufen.

alter table public.settings   enable row level security;
alter table public.profiles   enable row level security;
alter table public.categories enable row level security;
alter table public.jokes      enable row level security;
alter table public.votes      enable row level security;
alter table public.reports    enable row level security;

revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke execute on all functions in schema public from public, anon, authenticated;

grant select on public.categories to anon, authenticated;
create policy "Kategorien sind öffentlich" on public.categories for select using (true);

grant execute on function
  public.get_ranking(uuid, text, text, int, int),
  public.get_joke(uuid, bigint),
  public.get_unrated(uuid, bigint[], int),
  public.find_similar(text),
  public.cast_vote(uuid, bigint, int),
  public.post_joke(uuid, text, text),
  public.username_available(text),
  public.my_profile(),
  public.report_joke(uuid, bigint),
  public.admin_check(text),
  public.admin_list(text, text),
  public.admin_set_status(text, bigint, text)
to anon, authenticated;

-- ───────────────────────── Startdaten ─────────────────────────

insert into public.categories (slug, name, position) values
  ('flachwitze', 'Flachwitze', 1),
  ('wortspiele', 'Wortspiele', 2),
  ('tiere',      'Tiere',      3),
  ('schule',     'Schule',     4),
  ('buero',      'Büro',       5),
  ('nerd',       'Nerd',       6),
  ('schwarz',    'Schwarzer Humor', 7),
  ('einzeiler',  'Einzeiler',  8);

-- 360 Startwitze von der „Lachwerk“-Redaktion, vorgeplant über 35 Tage:
-- Rund 5 Tage liegen in der Vergangenheit, danach erscheinen jeden Tag etwa 10 neue Witze.
-- So ist „Heute“ auch ohne neue Beiträge von Besuchern einen Monat lang gefüllt.
-- Bewusst ohne erfundene Stimmen: Die ersten Besucher bewerten sie im Swipe-Modus.
insert into public.jokes (category_id, body, author_name, author_device, created_at)
select c.id, t.body, 'Lachwerk', '00000000-0000-0000-0000-000000000000',
       date_trunc('day', now()) - interval '5 days'
         + ((row_number() over ()) * 3 % 35) * interval '1 day'
         + random() * interval '20 hours'
from (values
  ('flachwitze', 'Was ist grün und klopft an die Tür?
Ein Klopfsalat.'),
  ('flachwitze', 'Was sitzt auf dem Baum und schreit „Aha“?
Ein Uhu mit Sprachfehler.'),
  ('flachwitze', 'Was ist rot und schlecht für die Zähne?
Ein Ziegelstein.'),
  ('flachwitze', 'Was ist braun, klebrig und läuft durch die Wüste?
Ein Karamel.'),
  ('flachwitze', 'Was macht ein Clown im Büro?
Faxen.'),
  ('flachwitze', 'Was ist orange und wandert durch die Berge?
Eine Wanderine.'),
  ('flachwitze', 'Was liegt am Strand und spricht undeutlich?
Eine Nuschel.'),
  ('flachwitze', 'Was ist gelb und kann nicht schwimmen?
Ein Bagger. Er hat nur einen Arm.'),
  ('flachwitze', 'Was ist ein Cowboy ohne Pferd?
Ein Sattelschlepper.'),
  ('flachwitze', 'Was ist schwarz-weiß und hüpft auf und ab?
Ein Pinguin auf dem Trampolin.'),
  ('flachwitze', 'Was ist grün und rennt durch den Wald?
Ein Rudel Gurken.'),
  ('flachwitze', 'Was ist braun und sitzt hinter Gittern?
Eine Knastanie.'),
  ('flachwitze', 'Was steht auf dem Grabstein eines Mathematikers?
„Damit hat er nicht gerechnet.“'),
  ('flachwitze', 'Was ist weiß und springt über die Wiese?
Ein Springquark.'),
  ('flachwitze', 'Was ist blau und riecht nach roter Farbe?
Blaue Farbe.'),
  ('flachwitze', 'Was ist rund, lila und fährt durch die Stadt?
Eine Brombeere mit Führerschein.'),
  ('flachwitze', 'Was sagt ein großer Stift zu einem kleinen Stift?
„Wachs mal, Stift!“'),
  ('flachwitze', 'Was sagt der Mond zur Sonne?
„So groß und darfst nachts immer noch nicht raus.“'),
  ('flachwitze', 'Was ist braun und schwimmt unter Wasser?
Ein U-Brot.'),
  ('flachwitze', 'Was ist die Lieblingsmusik von Steinen?
Rock.'),
  ('flachwitze', 'Was macht ein Zahnarzt ohne Patienten?
Er bohrt in der Nase.'),
  ('flachwitze', 'Was ist gelb, krumm und schwimmt auf dem See?
Eine Schwanane.'),
  ('flachwitze', 'Was ist grau, steht auf der Wiese und telefoniert?
Ein Telefant.'),
  ('flachwitze', 'Was ist rot und sitzt auf dem Klo?
Eine Klomate.'),
  ('flachwitze', 'Was ist gelb und schießt?
Eine Banone.'),
  ('flachwitze', 'Was hat vier Räder und fliegt?
Ein Müllwagen.'),
  ('flachwitze', 'Was ist grau und kann nicht schwimmen?
Eine Wand.'),
  ('flachwitze', 'Was ist rot und fährt ständig rauf und runter?
Eine Tomate im Aufzug.'),
  ('flachwitze', 'Was ist grün und hat Räder?
Gras. Das mit den Rädern war gelogen.'),
  ('flachwitze', 'Was macht ein Keks im Krankenhaus?
Er fühlt sich ganz krümelig.'),
  ('flachwitze', 'Was ist braun, haarig und trägt eine Sonnenbrille?
Eine Kokosnuss im Urlaub.'),
  ('flachwitze', 'Was ist schwarz, weiß und rot?
Ein Zebra mit Sonnenbrand.'),
  ('flachwitze', 'Wie nennt man einen Bären ohne Zähne?
Gummibär.'),
  ('flachwitze', 'Was ist braun und ruft „Hilfe“?
Ein Toast, der zu lange im Toaster war.'),
  ('flachwitze', 'Was ist gelb und liegt im Bett?
Eine Banane mit Fieber.'),
  ('flachwitze', 'Wohin geht eine Wolke, wenn es sie juckt?
Zum Wolkenkratzer.'),
  ('flachwitze', 'Was macht Hefeteig im Fitnessstudio?
Er geht auf.'),
  ('flachwitze', 'Was ist ein Fisch ohne Augen?
Ein Fsch.'),
  ('flachwitze', 'Was ist rot und sitzt in der Ecke?
Eine schüchterne Tomate.'),
  ('flachwitze', 'Was ist klein, grün und dreieckig?
Ein kleines grünes Dreieck.'),
  ('flachwitze', 'Was ist cooler als ein Schneemann?
Ein Schneemann mit Sonnenbrille.'),
  ('flachwitze', 'Was ist weiß und rollt den Berg hinauf?
Eine Lawine mit Heimweh.'),
  ('flachwitze', 'Was ist der Unterschied zwischen einem Bäcker und einem Teppich?
Der Bäcker muss um vier Uhr aufstehen, der Teppich kann liegen bleiben.'),
  ('flachwitze', 'Was ist der Unterschied zwischen einem Keks und einem Elefanten?
Einen Keks kann man in den Kakao tunken.'),
  ('flachwitze', 'Sagt die eine Wand zur anderen:
„Wir treffen uns an der Ecke.“'),
  ('flachwitze', 'Zwei Tomaten gehen über die Straße. Die eine wird überfahren.
Sagt die andere: „Komm, Ketchup!“'),
  ('flachwitze', 'Kommt ein Pferd in die Bar. Fragt der Barkeeper:
„Warum so ein langes Gesicht?“'),
  ('flachwitze', 'Kommt ein Skelett in die Bar und bestellt:
„Ein Bier und einen Wischmopp, bitte.“'),
  ('flachwitze', '„Herr Doktor, ich fühle mich wie ein Vorhang.“
„Jetzt reißen Sie sich mal zusammen!“'),
  ('flachwitze', '„Herr Doktor, alle ignorieren mich.“
„Der Nächste, bitte!“'),
  ('flachwitze', '„Herr Ober, was macht die Fliege in meiner Suppe?“
„Sieht nach Rückenschwimmen aus.“'),
  ('flachwitze', '„Herr Ober, der Teller ist ja ganz nass!“
„Das ist die Suppe.“'),
  ('flachwitze', 'Was ist rot und flüstert?
Eine Tomate mit Halsschmerzen.'),
  ('flachwitze', 'Was ist braun und dreht sich im Kreis?
Ein Kaffee, der umgerührt wird.'),
  ('flachwitze', 'Was essen Boxer am liebsten?
Schlagsahne.'),
  ('flachwitze', 'Was sitzt auf dem Dach und raucht?
Ein Schornstein.'),
  ('flachwitze', 'Was hängt an der Wand und macht „Kcat-kcit“?
Eine Uhr, die rückwärts läuft.'),
  ('flachwitze', 'Was machen zwei wütende Schafe?
Sie kriegen sich in die Wolle.'),
  ('flachwitze', 'Was macht ein Kaktus auf einer Party?
Er sticht aus der Menge heraus.'),
  ('flachwitze', 'Was essen Gespenster am liebsten?
Spukhetti.'),
  ('wortspiele', 'Was macht ein Pirat am Computer?
Er drückt die Enter-Taste.'),
  ('wortspiele', 'Wie nennt man einen Bumerang, der nicht zurückkommt?
Stock.'),
  ('wortspiele', 'Was ist ein Keks unter einem Baum?
Ein schattiges Plätzchen.'),
  ('wortspiele', 'Treffen sich zwei Magnete. Sagt der eine:
„Was soll ich heute bloß anziehen?“'),
  ('wortspiele', 'Was sagt ein Gen, wenn es ein anderes trifft?
„Hallo, Gen!“'),
  ('wortspiele', 'Was ist ein Hai mit Kopfhörern?
Ein Hai-Fi.'),
  ('wortspiele', 'Warum gehen Elektriker so gern ins Theater?
Wegen der Spannung.'),
  ('wortspiele', 'Welcher Bus hat den Atlantik überquert?
Kolumbus.'),
  ('wortspiele', 'Wo wohnen Katzen?
Im Miezhaus.'),
  ('wortspiele', 'Was sagt der Ozean zum Strand?
Nichts. Er winkt nur.'),
  ('wortspiele', 'Was macht ein Mathematiker im Garten?
Wurzeln ziehen.'),
  ('wortspiele', 'Was ist ein Schneemann mit Sonnenbrand?
Eine Pfütze.'),
  ('wortspiele', 'Warum können Geister so schlecht lügen?
Man durchschaut sie sofort.'),
  ('wortspiele', 'Warum sind Fische so schlau?
Weil sie in Schulen leben.'),
  ('wortspiele', 'Wie heißt der Bruder von Elvis?
Zwölvis.'),
  ('wortspiele', 'Wie nennt man einen Löwen, der Witze erzählt?
Einen Brüller.'),
  ('wortspiele', 'Warum ist der Kalender so nervös?
Seine Tage sind gezählt.'),
  ('wortspiele', 'Was sagt ein Fisch, der gegen eine Mauer schwimmt?
„Damm!“'),
  ('wortspiele', 'Was sagt der Kühlschrank zur Milch?
„Bleib cool.“'),
  ('wortspiele', 'Warum wurde die Tomate rot?
Sie hat das Salatdressing gesehen.'),
  ('wortspiele', 'Was macht ein Uhrmacher im Urlaub?
Er nimmt sich Zeit.'),
  ('wortspiele', 'Warum sind Bananen krumm?
Weil niemand in den Urwald zog und die Banane gerade bog.'),
  ('wortspiele', 'Was trinken Gespenster am liebsten?
Buuuh-ttermilch.'),
  ('wortspiele', 'Was ist ein Pferd, das Bücher schreibt?
Ein Hengstseller.'),
  ('wortspiele', 'Was ist ein Vampir, der Gemüse isst?
Ein Blutorangen-Fan.'),
  ('wortspiele', 'Warum gewinnt der Pilz jedes Rennen?
Er ist ein Champignon.'),
  ('wortspiele', 'Wie heißt ein Spanier ohne Auto?
Carlos.'),
  ('wortspiele', 'Was sagt ein Spiegel zum anderen?
„Wir sollten uns mal reflektieren.“'),
  ('wortspiele', 'Wie nennt man einen Vogel mit Schulden?
Pleitegeier.'),
  ('wortspiele', 'Warum ging das Buch zum Arzt?
Es hatte Rückenschmerzen.'),
  ('wortspiele', 'Warum war der Baum beim Psychologen?
Er hatte tief verwurzelte Probleme.'),
  ('wortspiele', 'Was ist ein Hund mit Fieber?
Ein Hot Dog.'),
  ('wortspiele', 'Was essen Schauspieler am liebsten?
Rollmops.'),
  ('wortspiele', 'Was essen Autos am liebsten?
Parkplätzchen.'),
  ('wortspiele', 'Welches Instrument spielt ein Fisch?
Kontrabarsch.'),
  ('wortspiele', 'Warum gehen Bäcker nie pleite?
Sie verdienen sich ihr Brot.'),
  ('wortspiele', 'Was macht ein Huhn mit seinem Geld?
Es legt es an.'),
  ('wortspiele', 'Warum ist der Backofen so beliebt?
Er ist einfach warmherzig.'),
  ('wortspiele', 'Ich wollte einen Witz über einen Bleistift erzählen.
Aber er hatte keine Spitze.'),
  ('wortspiele', 'Ich kenne einen Witz über Bauarbeiter.
Aber da wird noch dran gearbeitet.'),
  ('wortspiele', 'Ich würde euch einen Witz über Zeitreisen erzählen.
Aber ihr habt ihn gestern schon nicht gemocht.'),
  ('wortspiele', 'Ich kenne einen Witz über Pizza.
Der ist aber ziemlich käsig.'),
  ('wortspiele', 'Was sagt der große Vulkan zum kleinen Vulkan?
„Ich lava dich.“'),
  ('wortspiele', 'Was sagt die Null zur Acht?
„Schicker Gürtel!“'),
  ('wortspiele', 'Was macht eine Kerze, wenn sie traurig ist?
Sie lässt den Docht hängen.'),
  ('wortspiele', 'Warum gehen Ameisen nicht in die Kirche?
Sie sind In-Sekten.'),
  ('wortspiele', 'Welche Schlange ist die gemeinste?
Die Warteschlange.'),
  ('wortspiele', 'Welche Bank hat kein Geld?
Die Parkbank.'),
  ('wortspiele', 'Welche Hose hat keine Beine?
Die Wasserhose.'),
  ('wortspiele', 'Welcher Stuhl hat keine Beine?
Der Stuhlgang.'),
  ('wortspiele', 'Warum ist der Himmel so hoch?
Damit sich die Vögel nicht den Kopf stoßen.'),
  ('wortspiele', 'Welche Musik hören Luftballons?
Pop.'),
  ('wortspiele', 'Welcher Ball ist nicht rund?
Der Maskenball.'),
  ('wortspiele', 'Welches Schiff hat keine Segel?
Das Kirchenschiff.'),
  ('wortspiele', 'Welcher Hahn kräht nie?
Der Wasserhahn.'),
  ('wortspiele', 'Welche Mutter hat keine Kinder?
Die Schraubenmutter.'),
  ('wortspiele', 'Welcher Zahn beißt nicht?
Der Löwenzahn.'),
  ('wortspiele', 'Welcher Bart wächst nie?
Der Schlüsselbart.'),
  ('wortspiele', 'Welche Birne kann man nicht essen?
Die Glühbirne.'),
  ('wortspiele', 'Welcher Kater hat kein Fell?
Der nach der Party.'),
  ('tiere', 'Treffen sich zwei Schnecken. Fragt die eine: „Warum so schnell unterwegs?“
„Ich hab mein Haus vergessen.“'),
  ('tiere', 'Was macht ein Hai im Computer?
Er surft im Netz.'),
  ('tiere', 'Sagt die eine Kuh: „Muh.“
Sagt die andere: „Das wollte ich auch gerade sagen.“'),
  ('tiere', 'Was ist der Lieblingsfilm von Kühen?
Muhlan Rouge.'),
  ('tiere', 'Ein Pinguin läuft durch die Wüste und denkt:
„Hier muss es aber glatt sein, so viel wie hier gestreut wurde.“'),
  ('tiere', 'Was sagt ein Hamster nach dem Training?
„Ich dreh am Rad.“'),
  ('tiere', 'Warum haben Giraffen so lange Hälse?
Weil ihre Füße so stinken.'),
  ('tiere', 'Wie nennt man ein Schaf ohne Beine?
Eine Wolke.'),
  ('tiere', 'Warum sind Frösche so glücklich?
Sie fressen einfach alles, was sie nervt.'),
  ('tiere', 'Zwei Kühe auf der Weide. Die eine: „Hast du keine Angst vor Rinderwahnsinn?“
Die andere: „Nö, ich bin ein Hubschrauber.“'),
  ('tiere', 'Was sagt die Schnecke, die auf einer Schildkröte reitet?
„Huiii!“'),
  ('tiere', 'Warum ging das Huhn über die Straße?
Um auf die andere Seite zu kommen.'),
  ('tiere', 'Wie umarmen sich Igel?
Ganz vorsichtig.'),
  ('tiere', 'Warum schwimmen Fische nicht auf dem Rücken?
Sonst bekommen sie einen Sonnenbrand am Bauch.'),
  ('tiere', 'Was bestellt ein Pferd im Café?
Einen Hafer-Latte.'),
  ('tiere', 'Fragt der Kunde in der Zoohandlung: „Kann der Papagei sprechen?“
Sagt der Papagei: „Kannst du fliegen?“'),
  ('tiere', 'Was ist ein Kater im Fitnessstudio?
Ein Muskelkater.'),
  ('tiere', 'Welches Tier ist das stärkste?
Die Schnecke. Sie trägt ihr ganzes Haus.'),
  ('tiere', 'Wer sitzt im Dschungel und schummelt?
Mogli.'),
  ('tiere', 'Was hat vier Beine und kann fliegen?
Zwei Vögel.'),
  ('tiere', 'Warum legen Hühner Eier?
Wenn sie sie werfen würden, gingen sie kaputt.'),
  ('tiere', 'Was ist schlimmer als ein Wurm im Apfel?
Ein halber Wurm im Apfel.'),
  ('tiere', 'Treffen sich zwei Hunde. Sagt der eine: „Wau.“ Sagt der andere: „Miau.“
„Wieso miau?“ – „Ich lerne Fremdsprachen.“'),
  ('tiere', 'Was ist braun und schaut durchs Schlüsselloch?
Ein Spannferkel.'),
  ('tiere', 'Warum können Kühe nicht fliegen?
Weil sie kein Muh-tor haben.'),
  ('tiere', 'Wie bekommt man einen Elefanten in den Kühlschrank?
Tür auf, Elefant rein, Tür zu.
Und eine Giraffe? Tür auf, Elefant raus, Giraffe rein, Tür zu.'),
  ('tiere', 'Treffen sich zwei Fische. Sagt der eine: „Hi!“
Sagt der andere: „Wo?!“'),
  ('tiere', 'Warum fliegen Vögel im Winter in den Süden?
Weil es zu Fuß zu weit ist.'),
  ('tiere', 'Welches Tier springt höher als ein Haus?
Jedes. Häuser können nicht springen.'),
  ('tiere', 'Zwei Mäuse sehen eine Fledermaus.
Sagt die eine: „Schau mal, ein Engel!“'),
  ('tiere', 'Warum sitzt die Katze so gern am Computer?
Wegen der Maus.'),
  ('tiere', 'Was machen Kühe in der Disco?
Milchshakes.'),
  ('tiere', 'Wohin gehen Kühe am Wochenende?
Ins Muuuuseum.'),
  ('tiere', 'Zwei Schafe auf der Weide. Sagt das eine: „Mäh.“
Sagt das andere: „Mäh doch selber!“'),
  ('tiere', 'Warum hat der Tausendfüßler das Fußballspiel verpasst?
Bis er alle Schuhe anhatte, war das Spiel vorbei.'),
  ('tiere', 'Ein Elefant und eine Maus laufen über eine Holzbrücke.
Sagt die Maus: „Hörst du, wie wir trampeln?“'),
  ('tiere', 'Wie nennt man eine Kuh, die Gras frisst?
Rasenmäher.'),
  ('tiere', 'Zwei Pinguine auf einer Eisscholle. Sagt der eine: „Du siehst aus, als würdest du einen Frack tragen.“
„Wer sagt denn, dass ich keinen trage?“'),
  ('tiere', 'Zwei Flöhe kommen aus dem Kino. Fragt der eine:
„Gehen wir zu Fuß oder nehmen wir einen Hund?“'),
  ('tiere', 'Warum haben Elefanten rote Augen?
Damit sie sich im Kirschbaum verstecken können.
Hast du schon mal einen Elefanten im Kirschbaum gesehen? Siehst du, es funktioniert.'),
  ('tiere', 'Was war zuerst da, das Huhn oder das Ei?
Ich habe beide online bestellt. Das Huhn kam zuerst.'),
  ('tiere', 'Was sagt der Hahn, wenn er verschlafen hat?
„Kikeri-oh nein!“'),
  ('tiere', 'Was sagt der Wal, wenn er sich nicht entscheiden kann?
„Ich hab die Qual der Wal.“'),
  ('tiere', 'Wie nennt man ein Faultier, das Sport macht?
Ein Wunder.'),
  ('tiere', 'Was sagt das Faultier am Montag?
Nichts. Es schläft bis Mittwoch.'),
  ('tiere', 'Warum sind Flamingos rosa?
Sie haben vergessen, sich einzucremen.'),
  ('tiere', 'Kommt ein Hase in die Bäckerei: „Hattu Möhrenkuchen?“ – „Nein.“ Am nächsten Tag: „Hattu Möhrenkuchen?“ – „Nein!“
Am dritten Tag hat der Bäcker extra einen gebacken. „Hattu Möhrenkuchen?“ – „Ja!“ – „Muss ja eklig schmecken.“'),
  ('tiere', 'Warum geht der Igel in den Blumenladen?
Er besucht seine Verwandtschaft, die Kakteen.'),
  ('tiere', 'Warum fressen Eisbären keine Pinguine?
Sie kriegen die Verpackung nicht auf.'),
  ('tiere', 'Sagt die Raupe zum Schmetterling:
„Du hast dich aber verändert.“'),
  ('tiere', 'Wie nennt man einen Hund, der zaubern kann?
Labrakadabrador.'),
  ('tiere', 'Warum tragen Kühe Glocken?
Weil ihre Hörner nicht funktionieren.'),
  ('tiere', 'Welchen Sport machen Bienen am liebsten?
Summba.'),
  ('tiere', 'Welcher Fisch ist immer gut gelaunt?
Der Lachs.'),
  ('tiere', 'Woran erkennt man, dass ein Elefant im Kühlschrank war?
An den Fußspuren in der Butter.'),
  ('tiere', 'Warum haben Störche so lange Beine?
Damit ihre Füße bis zum Boden reichen.'),
  ('tiere', 'Warum fliegen Eulen nur nachts?
Tagsüber ist zu viel Verkehr.'),
  ('tiere', 'Was zählen Schafe, wenn sie nicht einschlafen können?
Menschen.'),
  ('tiere', 'Zwei Goldfische im Glas. Fragt der eine: „Glaubst du an Gott?“
„Natürlich. Wer wechselt denn sonst das Wasser?“'),
  ('tiere', 'Fragt eine Schlange die andere: „Sind wir eigentlich giftig?“ – „Wieso?“
„Ich hab mir gerade auf die Zunge gebissen.“'),
  ('schule', 'Lehrerin: „Nenne mir fünf Tiere aus Afrika.“
Fritzchen: „Vier Löwen und ein Elefant.“'),
  ('schule', '„Fritzchen, was ist die Mehrzahl von Baum?“
„Wald.“'),
  ('schule', 'Warum ist das Mathebuch traurig?
Es hat zu viele Probleme.'),
  ('schule', '„Fritzchen, warum kommst du zu spät?“
„Auf dem Schild stand doch: Schule – bitte langsam fahren!“'),
  ('schule', 'Lehrerin: „Wenn ich sage: Ich war schön – welche Zeit ist das?“
Fritzchen: „Eindeutig Vergangenheit.“'),
  ('schule', '„Warum hast du eine Sechs in Mathe?“ – „Die Lehrerin hat gefragt, was 3 mal 4 ist. Ich habe 12 gesagt. Dann hat sie gefragt, was 4 mal 3 ist.“
„Und wo ist da der Unterschied?“ – „Genau das habe ich auch gesagt.“'),
  ('schule', 'Lehrer: „Was ist flüssiger als Wasser?“
Schüler: „Hausaufgaben. Die sind überflüssig.“'),
  ('schule', 'Lehrer: „Nenne mir drei Dinge, in denen Milch steckt.“
„Butter, Käse und eine Kuh.“'),
  ('schule', 'Schüler: „Kann man für etwas bestraft werden, das man nicht gemacht hat?“ – Lehrer: „Natürlich nicht.“
Schüler: „Gut. Ich habe meine Hausaufgaben nicht gemacht.“'),
  ('schule', 'Lehrer: „Du hast fünf Äpfel, und ich nehme dir zwei weg. Was hast du dann?“
„Streit.“'),
  ('schule', 'Warum nehmen manche Schüler eine Leiter mit in die Schule?
Sie wollen auf die höhere Schule.'),
  ('schule', 'Lehrerin: „Was passiert, wenn man einen Stein ins Rote Meer wirft?“
Fritzchen: „Er wird nass.“'),
  ('schule', 'Vater: „Wie lief die Mathearbeit?“ – „Fast alles richtig.“ – „Und was war falsch?“
„Die Antworten.“'),
  ('schule', '„Fritzchen, warum schreibst du so langsam?“
„Der Brief ist für Opa, und der kann nicht so schnell lesen.“'),
  ('schule', 'Erdkundelehrer: „Was weißt du über das Tote Meer?“
„Ich wusste nicht mal, dass es krank war.“'),
  ('schule', 'Lehrerin: „Wie viele Sekunden hat ein Jahr?“
Fritzchen: „Zwölf. Zweiter Januar, zweiter Februar …“'),
  ('schule', 'Lehrerin: „Fritzchen, du hast genau die gleichen Fehler wie dein Nachbar.“
„Wir haben ja auch die gleiche Lehrerin.“'),
  ('schule', 'Mutter: „Was habt ihr heute in der Schule gelernt?“
„Offenbar nicht genug. Wir müssen morgen wieder hin.“'),
  ('schule', 'Lehrer: „Was ist schneller, Licht oder Schall?“
Schüler: „Licht. Beim Fernseher kommt erst das Bild und dann der Ton.“'),
  ('schule', '„Fritzchen, was ist 7 mal 7?“ – „49.“ – „Sehr gut!“
„Sehr gut? Das ist perfekt!“'),
  ('schule', 'Warum steht der Musiklehrer vor der verschlossenen Tür?
Er hat seinen Notenschlüssel verloren.'),
  ('schule', 'Lehrerin: „Bilde einen Satz mit ‚obwohl‘.“
Fritzchen: „Ob wohl bald Pause ist?“'),
  ('schule', 'Biolehrer: „Was hat der Mensch, was Tiere nicht haben?“
„Hausaufgaben.“'),
  ('schule', '„Papa, ich war heute der Einzige, der sich gemeldet hat!“ – „Super! Was war die Frage?“
„Wer hat seine Hausaufgaben nicht gemacht?“'),
  ('schule', 'Lehrer: „Wie nennt man jemanden, der immer redet, auch wenn keiner zuhört?“
Fritzchen: „Lehrer.“'),
  ('schule', 'Lehrer: „Was ist die Hälfte von acht?“
Fritzchen: „Waagerecht null, senkrecht drei.“'),
  ('schule', 'Lehrer: „Ich gehe, du gehst, er geht, wir gehen, ihr geht, sie gehen. Was bedeutet das?“
Fritzchen: „Alle sind weg.“'),
  ('schule', 'Lehrer: „Du hast 10 Euro und bittest deinen Vater um 10 Euro. Wie viel hast du dann?“ – „10 Euro.“ – „Du kannst ja nicht rechnen!“
„Sie kennen meinen Vater nicht.“'),
  ('schule', 'Lehrer: „Deine Hausaufgabe ist genau wie die von Max. Was soll ich daraus schließen?“
Fritzchen: „Dass die von Max auch richtig ist?“'),
  ('schule', 'Lehrerin: „Fritzchen, nenne mir zwei Pronomen.“
Fritzchen: „Wer? Ich?“ – „Richtig!“'),
  ('schule', 'Lehrer: „Was ist der Unterschied zwischen Unwissenheit und Gleichgültigkeit?“
Schüler: „Weiß ich nicht und ist mir egal.“ – „Perfekt!“'),
  ('schule', 'Lehrerin: „Ich sage ein Wort, du sagst das Gegenteil. Groß.“ – „Klein.“ – „Hell.“ – „Dunkel.“ – „Ungefähr.“
„Gefähr.“'),
  ('schule', 'Lehrer: „Wie kann man ein rohes Ei einen Meter tief fallen lassen, ohne dass es kaputtgeht?“
Fritzchen: „Man lässt es aus zwei Metern fallen. Den ersten Meter übersteht es.“'),
  ('schule', 'Physiklehrer: „Körper dehnen sich bei Wärme aus und ziehen sich bei Kälte zusammen. Beispiel?“
Fritzchen: „Die Sommerferien sind lang, die Winterferien kurz.“'),
  ('schule', 'Geschichtslehrer: „Wo wurde die Unabhängigkeitserklärung unterschrieben?“
Fritzchen: „Ganz unten.“'),
  ('schule', 'Erdkundelehrer: „Was liegt zwischen Deutschland und Frankreich?“
Fritzchen: „Das ‚und‘.“'),
  ('schule', 'Mathelehrer: „Ich habe zwei Äpfel in der einen Hand und drei in der anderen. Was habe ich?“
Fritzchen: „Riesige Hände.“'),
  ('schule', 'Lehrer: „Ich frage zum letzten Mal: Wer hat das Fenster kaputt gemacht?“
Fritzchen: „Super, dann müssen wir ja nicht mehr antworten.“'),
  ('schule', 'Lehrer: „Dein Aufsatz über deinen Hund ist Wort für Wort derselbe wie der deines Bruders.“
Fritzchen: „Ist ja auch derselbe Hund.“'),
  ('schule', 'Sportlehrer: „Leg dich hin und strample in der Luft, als würdest du Fahrrad fahren.“ Nach einer Weile hört Fritzchen auf. „Warum hörst du auf?“
„Jetzt geht''s bergab.“'),
  ('schule', 'Lehrerin: „Wie viele Buchstaben hat das Alphabet?“
Fritzchen: „Acht. A, L, P, H, A, B, E, T.“'),
  ('schule', 'Lehrer: „Was ist schneller, Wärme oder Kälte?“
Fritzchen: „Wärme. Kälte kann man sich ja einfangen.“'),
  ('schule', 'Lehrer: „Dein Vater hat dir bei den Hausaufgaben geholfen, oder?“
Fritzchen: „Nein, er hat sie ganz allein gemacht.“'),
  ('schule', '„Papa, kannst du im Dunkeln unterschreiben?“ – „Ich denke schon.“
„Dann mach mal das Licht aus und unterschreib mein Zeugnis.“'),
  ('schule', 'Lehrer: „Welcher Monat hat 28 Tage?“
Fritzchen: „Alle.“'),
  ('schule', 'Lehrerin: „Nenne ein Beispiel für Ruhestörung.“
Fritzchen: „Wenn Sie mich im Unterricht wecken.“'),
  ('schule', '„Was ist dein Lieblingsfach?“
„Die große Pause.“'),
  ('schule', 'Lehrer: „Woher weißt du, dass die Erde rund ist?“
Fritzchen: „Egal wo ich hingehe, am Ende lande ich wieder in der Schule.“'),
  ('schule', 'Lehrer: „Was ist die Mehrzahl von Mann?“ – „Männer.“ – „Und von Kind?“
„Zwillinge.“'),
  ('schule', 'Mutter: „Wie war dein erster Schultag?“
„Erster? Muss ich da etwa noch mal hin?“'),
  ('schule', 'Lehrerin: „Nenne mir ein Säugetier ohne Zähne.“
Fritzchen: „Meinen Opa.“'),
  ('schule', 'Lehrer: „Was ist ein Vakuum?“
Fritzchen: „Ich hab''s im Kopf, komme aber gerade nicht drauf.“'),
  ('schule', '„Mama, ich war heute der Schnellste!“ – „Beim Sport?“
„Nein, beim Nachhausegehen.“'),
  ('schule', 'Lehrerin: „Warum ist dein Aufsatz so nass?“
Fritzchen: „Sie wollten doch einen Fließtext.“'),
  ('schule', 'Mathelehrer: „Ein Drittel von euch ist durch den Test gefallen.“
Fritzchen: „So viele sind wir doch gar nicht!“'),
  ('schule', 'Lehrer: „Wer zuletzt lacht …“
Fritzchen: „… hat den Witz nicht verstanden.“'),
  ('schule', '„Wie war die Klassenfahrt?“
„Super! Der Lehrer hat uns zwei Tage lang nicht gefunden.“'),
  ('schule', 'Lehrerin: „Wer weiß, was Hieroglyphen sind?“
Fritzchen: „Die Schrift von unserem Hausarzt.“'),
  ('schule', 'Biolehrer: „Was hat sechs Beine, ist grün und sitzt auf einem Blatt?“
Fritzchen: „Keine Ahnung, aber es krabbelt Ihnen gerade den Arm hoch.“'),
  ('schule', 'Lehrer: „Wenn du so weitermachst, wirst du nie versetzt!“
Fritzchen: „Auch gut. Dann bleibe ich in Ihrer Klasse.“'),
  ('buero', 'Chef: „Sie kommen jeden Tag zu spät!“
Ich: „Dafür gehe ich auch früher.“'),
  ('buero', 'Meine Kaffeemaschine hat gekündigt.
Sie fühlt sich ausgepresst.'),
  ('buero', 'Chef: „Was ist Ihre größte Schwäche?“ – „Ehrlichkeit.“ – „Das ist doch keine Schwäche!“
„Ihre Meinung ist mir ehrlich gesagt egal.“'),
  ('buero', 'Kollege: „Ich habe mir vorgenommen, ab heute nichts mehr aufzuschieben.“ – „Und?“
„Fange ich morgen an.“'),
  ('buero', '„Wie lange arbeiten Sie schon hier?“
„Seit mir der Chef mit Kündigung gedroht hat.“'),
  ('buero', 'Chef: „Wir müssen Kosten sparen.“
Mitarbeiter: „Dann streichen wir doch die Meetings, in denen wir übers Kostensparen reden.“'),
  ('buero', 'Was ist ein Meeting?
Ein Ort, an dem man Minuten protokolliert und Stunden verliert.'),
  ('buero', 'Mein Chef sagte: „Denken Sie mal außerhalb der Box.“
Jetzt sitze ich auf dem Flur.'),
  ('buero', '„Wo sehen Sie sich in fünf Jahren?“
„Ehrlich gesagt sehe ich schon heute nicht ganz scharf.“'),
  ('buero', '„Was können Sie besonders gut?“ – „Schnell rechnen.“ – „Was ist 37 mal 49?“ – „Zwölf.“ – „Das ist falsch!“
„Aber schnell.“'),
  ('buero', 'Chef: „Ab sofort gibt es Gleitzeit.“
Ich: „Super, dann gleite ich jetzt nach Hause.“'),
  ('buero', 'Montag ist der Tag, an dem der Kaffee härter arbeitet als ich.'),
  ('buero', 'Ich bin nicht faul.
Ich bin im Energiesparmodus.'),
  ('buero', 'Warum kam der Drucker zu spät zur Arbeit?
Papierstau.'),
  ('buero', 'Chef: „Warum waren Sie gestern nicht da?“ – „Mir ging es nicht gut.“ – „Und heute?“
„Auch nicht. Aber zu Hause ist das WLAN schlechter.“'),
  ('buero', 'E-Mail vom Chef: „Kurze Frage.“
Es folgen elf Absätze.'),
  ('buero', '„Mit freundlichen Grüßen“ heißt im Büro übersetzt:
„Ich bin kurz davor zu explodieren.“'),
  ('buero', 'Homeoffice ist, wenn alle Kollegen plötzlich Katzen, Kinder und eine Zimmerpflanze haben, die unbedingt in die Kamera wollen.'),
  ('buero', 'Chef: „Sie sind schon wieder zu spät!“
„Sie haben doch gesagt, ich soll mir Zeit lassen.“'),
  ('buero', 'Was ist die beliebteste Sportart im Büro?
Aufschieben. Geht allein und im Team.'),
  ('buero', 'Personalchefin: „Wir suchen jemanden, der Verantwortung übernimmt.“
Bewerber: „Perfekt. In meinem alten Job war ich für jeden Fehler verantwortlich.“'),
  ('buero', '„Chef, ich brauche mehr Gehalt. Drei Firmen sind hinter mir her.“ – „Welche denn?“
„Strom, Gas und Telefon.“'),
  ('buero', 'Ich habe mein Passwort in „falsch“ geändert.
Wenn ich es vergesse, sagt der Computer: „Ihr Passwort ist falsch.“'),
  ('buero', 'Ich arbeite super unter Druck.
Deshalb fange ich immer erst am letzten Tag an.'),
  ('buero', 'Chef: „Warum tragen Sie zwei verschiedene Socken?“
„Keine Ahnung, ich habe zu Hause noch so ein Paar.“'),
  ('buero', 'Bewerbungsgespräch: „Haben Sie Erfahrung mit Teamarbeit?“
„Ja, ich habe schon oft andere für mich arbeiten lassen.“'),
  ('buero', '„Was sind Ihre Stärken?“ – „Ich bin sehr anpassungsfähig.“ – „Und Ihre Schwächen?“
„Welche hätten Sie denn gern?“'),
  ('buero', 'Chef: „Warum kommen Sie zu spät?“
„Ich habe von der Arbeit geträumt und wollte das Projekt noch fertig machen.“'),
  ('buero', '„Wie viele Leute arbeiten in Ihrer Firma?“
„Ungefähr die Hälfte.“'),
  ('buero', '„Ich war heute super produktiv!“ – „Was hast du geschafft?“
„Meine To-do-Liste geschrieben.“'),
  ('buero', '„Ich habe zwei Stunden an einem Problem gesessen.“ – „Und?“
„Das Problem war, dass der Monitor aus war.“'),
  ('buero', 'Kollege: „Gehen wir in der Mittagspause joggen?“
„Ich mache schon Sport. Ich renne jeden Morgen dem Bus hinterher.“'),
  ('buero', 'Chef: „Sie sind schon wieder nicht an Ihrem Platz!“
„Ich arbeite gerade agil.“'),
  ('buero', 'E-Mail mit dem Betreff „WICHTIG!!!“
Inhalt: „Wer hat meinen Joghurt aus dem Kühlschrank genommen?“'),
  ('buero', 'Heute Morgen habe ich aus Versehen auf „Allen antworten“ geklickt.
Jetzt kennt mich die ganze Firma.'),
  ('buero', 'Personalchef: „Wir zahlen 1.500 Euro, nach einem halben Jahr 2.500.“
Bewerber: „Gut, dann komme ich in einem halben Jahr wieder.“'),
  ('buero', '„Sind Sie mit Ihrem Gehalt zufrieden?“
„Mit dem Gehalt schon. Nur nicht mit der Höhe.“'),
  ('buero', 'Ich wurde in der Uhrenfabrik entlassen.
Angeblich habe ich zu viele Überstunden gemacht.'),
  ('buero', 'Ich habe in der Orangensaftfabrik gekündigt.
Ich konnte mich einfach nicht konzentrieren.'),
  ('buero', 'Ich habe beim Bäcker aufgehört.
Ich wollte mein Brot anders verdienen.'),
  ('buero', 'Mein Chef will, dass ich eine Präsentation über Zeitmanagement halte.
Ich bin nur noch nicht dazu gekommen.'),
  ('buero', 'Chef: „Ab heute ist unser Büro papierlos.“
Mitarbeiter: „Super. Und wo soll ich die Anweisung jetzt ausdrucken?“'),
  ('buero', 'Kollege: „Ich bin heute im Homeoffice.“ – „Du sitzt doch direkt neben mir.“
„Körperlich ja. Geistig bin ich zu Hause.“'),
  ('buero', 'Teambuilding:
Wenn alle gemeinsam auf den Feierabend warten.'),
  ('buero', '„Was machst du als Projektmanager eigentlich den ganzen Tag?“
„Ich frage andere, wann sie fertig sind.“'),
  ('buero', '„Warum arbeitest du so gern im Team?“
„Dann kann ich die Schuld besser verteilen.“'),
  ('buero', 'Chef: „Sie haben die ganze Woche nichts gemacht!“
„Ich wollte die Kollegen nicht unter Druck setzen.“'),
  ('buero', '„Chef, darf ich morgen früher gehen? Meine Frau will mit mir Möbel kaufen.“ – „Auf keinen Fall.“
„Danke, Chef! Ich wusste, Sie lassen mich nicht im Stich.“'),
  ('buero', 'Was ist das Gegenteil von einem Meeting?
Arbeiten.'),
  ('buero', 'Stellenanzeige: „Wir sind wie eine Familie.“
Übersetzt: „Pünktlich Feierabend gibt es hier nicht.“'),
  ('buero', '„Hast du kurz fünf Minuten?“
Das gefährlichste Wort im Büro ist „kurz“.'),
  ('buero', 'Der Kopierer funktioniert immer.
Außer, man hat es eilig.'),
  ('buero', 'Chef: „Ich bin offen für jede Kritik.“ – „Dann hätte ich da etwas …“
„Aber nicht jetzt.“'),
  ('buero', 'Warum ist die Kaffeemaschine wichtiger als der Chef?
Ohne Kaffeemaschine läuft hier gar nichts.'),
  ('buero', '„Wie lang ist bei euch die Mittagspause?“
„So lange, bis der Chef es merkt.“'),
  ('buero', 'Ich habe eine Allergie gegen Montagsmeetings.
Symptome: Gähnen, Augenrollen und plötzliche Zahnarzttermine.'),
  ('buero', '„Haben Sie Hobbys?“
„Ja. Feierabend.“'),
  ('buero', 'Chef: „Warum haben Sie gestern nicht angerufen, dass Sie krank sind?“
„Ich war zu krank zum Telefonieren. Aber ich hab''s auf Instagram gepostet.“'),
  ('buero', 'Büro-Mathematik:
5 Minuten Pause + 1 Kaffee + 1 Kollege mit Neuigkeiten = 45 Minuten.'),
  ('buero', '„Was machst du eigentlich im Homeoffice?“
„Meistens die Wäsche.“'),
  ('nerd', 'Warum verwechseln Programmierer Halloween und Weihnachten?
Weil OCT 31 = DEC 25.'),
  ('nerd', 'Es gibt 10 Arten von Menschen:
Die, die Binär verstehen, und die anderen.'),
  ('nerd', 'Ein SQL-Query geht in eine Bar, sieht zwei Tische und fragt:
„Darf ich euch joinen?“'),
  ('nerd', 'Wie viele Programmierer braucht man, um eine Glühbirne zu wechseln?
Keinen. Das ist ein Hardware-Problem.'),
  ('nerd', '„Schatz, hol bitte ein Brot. Und wenn es Eier gibt, bring sechs mit.“
Der Programmierer kommt mit sechs Broten zurück: „Es gab Eier.“'),
  ('nerd', 'Warum gehen Programmierer nicht gern in die Natur?
Zu viele Bugs.'),
  ('nerd', 'Ich würde dir einen UDP-Witz erzählen.
Aber ich weiß nicht, ob er ankommt.'),
  ('nerd', '„Willst du einen TCP-Witz hören?“
„Ja, ich will einen TCP-Witz hören.“
„Okay, ich erzähle dir jetzt einen TCP-Witz.“'),
  ('nerd', 'Was trinken Programmierer am liebsten?
Java.'),
  ('nerd', 'Mein Passwort ist die letzte Ziffer von Pi.'),
  ('nerd', 'Warum war der Laptop so müde?
Er hatte zu viele Tabs offen.'),
  ('nerd', 'Ein Physiker, ein Chemiker und ein Informatiker sitzen im Auto. Plötzlich geht der Motor aus.
Der Informatiker: „Lasst uns alle aussteigen und wieder einsteigen.“'),
  ('nerd', 'Es gibt zwei schwierige Dinge in der Informatik:
Cache-Invalidierung, Namensgebung und Off-by-one-Fehler.'),
  ('nerd', 'Wie nennt man acht Hobbits?
Ein Hobbyte.'),
  ('nerd', 'Ein Informatiker stellt abends zwei Gläser ans Bett:
Eines mit Wasser, falls er Durst bekommt, und ein leeres, falls nicht.'),
  ('nerd', 'Was ist der Unterschied zwischen einem Bug und einem Feature?
Die Dokumentation.'),
  ('nerd', '„Bei mir läuft es aber!“
„Gut, dann liefern wir deinen Rechner aus.“'),
  ('nerd', 'Optimist: „Das Glas ist halb voll.“ Pessimist: „Das Glas ist halb leer.“
Informatiker: „Das Glas ist doppelt so groß wie nötig.“'),
  ('nerd', 'Um Rekursion zu verstehen, muss man zuerst Rekursion verstehen.'),
  ('nerd', 'Warum frieren Windows-Nutzer so oft?
Zu viele offene Fenster.'),
  ('nerd', 'Sagt ein Atom zum anderen: „Ich habe ein Elektron verloren.“ – „Bist du sicher?“
„Ja, ich bin positiv.“'),
  ('nerd', 'Warum sollte man Atomen nicht trauen?
Sie stecken hinter allem.'),
  ('nerd', 'Schrödingers Katze geht in eine Bar.
Und nicht.'),
  ('nerd', 'Heisenberg wird von der Polizei angehalten: „Wissen Sie, wie schnell Sie waren?“
„Nein, aber ich weiß genau, wo ich bin.“'),
  ('nerd', 'Ein Programmierer kommt nie zu spät.
Er hat nur eine hohe Latenz.'),
  ('nerd', 'Warum mögen Programmierer dunkle Bildschirme?
Weil Licht Bugs anzieht.'),
  ('nerd', 'In welcher Kneipe treffen sich Programmierer?
In der Foo-Bar.'),
  ('nerd', '„git push --force“ ist kein Befehl.
Es ist eine Drohung.'),
  ('nerd', 'Mein Code funktioniert nicht und ich weiß nicht, warum.
Mein Code funktioniert und ich weiß nicht, warum.'),
  ('nerd', '99 kleine Bugs im Code, 99 kleine Bugs.
Einen gefixt, neu kompiliert: 127 kleine Bugs im Code.'),
  ('nerd', 'Warum kam der Programmierer nicht mehr aus der Dusche?
Auf dem Shampoo stand: Auftragen, ausspülen, wiederholen.'),
  ('nerd', 'Mein WLAN heißt jetzt „Polizei-Überwachungswagen 3“.
Seitdem parken die Nachbarn woanders.'),
  ('nerd', 'Es gibt drei Arten von Menschen:
Die, die zählen können, und die, die es nicht können.'),
  ('nerd', 'Sagt i zu π: „Sei doch mal rational!“
Sagt π: „Werd du erst mal real.“'),
  ('nerd', 'Ein Neutron geht in eine Bar und fragt: „Was kostet ein Bier?“
Der Barkeeper: „Für dich? Keine Ladung.“'),
  ('nerd', 'Ich würde ja einen Chemiewitz erzählen.
Aber ich bekomme sowieso keine Reaktion.'),
  ('nerd', 'Warum ging der Computer zum Arzt?
Er hatte einen Virus.'),
  ('nerd', 'Anruf beim IT-Support: „Da steht: Drücken Sie eine beliebige Taste.“
„Ja, und?“ – „Ich finde die Taste ‚Beliebig‘ nicht.“'),
  ('nerd', '„Ihr Passwort muss mindestens 8 Zeichen lang sein.“
„Schneewittchen und die sieben Zwerge.“'),
  ('nerd', '„Wie lief dein Tag?“ – „Ich habe acht Stunden programmiert.“
„Und heute?“ – „Acht Stunden gelöscht.“'),
  ('nerd', 'Ein guter Programmierer schaut immer in beide Richtungen,
bevor er eine Einbahnstraße überquert.'),
  ('nerd', 'Meine smarte Glühbirne hat ein Update bekommen.
Jetzt geht ihr endlich ein Licht auf.'),
  ('nerd', 'Mein Kühlschrank hat jetzt WLAN.
Jetzt weiß das ganze Internet, dass ich nachts Käse esse.'),
  ('nerd', 'Warum ist der Browser so dick?
Er isst zu viele Cookies.'),
  ('nerd', 'Warum hat der Roboter Urlaub genommen?
Er musste mal richtig abschalten.'),
  ('nerd', 'Ein Ingenieur, ein Physiker und ein Mathematiker sehen in Schottland ein schwarzes Schaf. Ingenieur: „In Schottland sind die Schafe schwarz.“ Physiker: „In Schottland gibt es mindestens ein schwarzes Schaf.“
Mathematiker: „In Schottland gibt es mindestens ein Schaf, das auf mindestens einer Seite schwarz ist.“'),
  ('nerd', 'Was macht ein Mathematiker, wenn ihm kalt ist?
Er stellt sich in die Ecke. Da sind 90 Grad.'),
  ('nerd', 'Mathematiker sterben nicht.
Sie verlieren nur ihre Funktion.'),
  ('nerd', 'Was ist ein Polarbär?
Ein rechtwinkliger Bär nach dem Koordinatenwechsel.'),
  ('nerd', 'Ein Tester geht in eine Bar. Bestellt 1 Bier. 0 Bier. 99999999 Bier. −1 Bier. Eine Eidechse.
Der erste echte Gast fragt, wo die Toilette ist. Die Bar geht in Flammen auf.'),
  ('nerd', 'Wie viele Softwaretester braucht man, um eine Glühbirne zu wechseln?
Keinen. Sie melden nur, dass es dunkel ist.'),
  ('nerd', 'Warum hat sich die Tabelle von der Datenbank getrennt?
Zu viele Fremdschlüssel.'),
  ('nerd', 'Warum haben Elektriker immer gute Laune?
Sie sind gut geerdet.'),
  ('nerd', 'Was sagt der Akku zum Handy?
„Ich bin am Ende.“'),
  ('nerd', 'Mein Handy hat noch 1 % Akku.
So konzentriert habe ich noch nie gearbeitet.'),
  ('nerd', 'Ein Physiker im Café: „Einen Espresso ohne Milch, bitte.“
Kellner: „Milch ist leider aus. Darf es ein Espresso ohne Sahne sein?“'),
  ('nerd', 'Unendlich viele Mathematiker gehen in eine Bar. Der erste bestellt ein Bier, der zweite ein halbes, der dritte ein Viertel …
Der Barkeeper stellt zwei Bier hin: „Ihr müsst eure Grenzen kennen.“'),
  ('nerd', 'Drei Statistiker gehen auf die Jagd. Der erste schießt einen Meter links vorbei, der zweite einen Meter rechts.
Der dritte jubelt: „Im Durchschnitt getroffen!“'),
  ('nerd', 'Wie nennt man einen Laptop ohne Akku?
Einen Desktop.'),
  ('nerd', 'Was ist schlimmer als ein Bug?
Ein Bug, der nur freitags um 17 Uhr auftaucht.')
) as t(cat, body)
join public.categories c on c.slug = t.cat;

-- ═══════════════════════════════════════════════════════════════════
-- Erweiterung: Witz des Tages, Profile, Autoren, Duell, Reaktionen, Challenge,
-- Hinweise, Statistik und Witz-Vorrat (identisch mit erweiterung.sql)
-- ═══════════════════════════════════════════════════════════════════

-- ───────────────────────── Neue Tabellen und Spalten ─────────────────────────

-- Witz des Tages: jeden Abend um 20 Uhr (deutsche Zeit) wird der beste Witz der letzten 24 Stunden gekrönt
create table if not exists public.daily_winners (
  day         date primary key,
  joke_id     bigint not null references public.jokes on delete cascade,
  crowned_at  timestamptz not null default now()
);
create index if not exists daily_winners_joke on public.daily_winners (joke_id);

-- Reaktionen: 😂 (lol), 🙄 (sigh), 💀 (dead) – eine pro Gerät und Witz
create table if not exists public.reactions (
  joke_id     bigint not null references public.jokes on delete cascade,
  device_id   uuid   not null,
  ip_hash     text,
  kind        text   not null check (kind in ('lol', 'sigh', 'dead')),
  created_at  timestamptz not null default now(),
  primary key (joke_id, device_id)
);
create index if not exists reactions_recent on public.reactions (created_at);
create index if not exists reactions_ip     on public.reactions (ip_hash, created_at);

-- Duell: zwei Witze nebeneinander, Elo-Wertung
alter table public.jokes add column if not exists elo        double precision not null default 1000;
alter table public.jokes add column if not exists duel_count int not null default 0;
create table if not exists public.duel_votes (
  id          bigint generated always as identity primary key,
  winner      bigint not null references public.jokes on delete cascade,
  loser       bigint not null references public.jokes on delete cascade,
  device_id   uuid   not null,
  ip_hash     text,
  created_at  timestamptz not null default now()
);
create unique index if not exists duel_votes_pair on public.duel_votes (device_id, least(winner, loser), greatest(winner, loser));
create index if not exists duel_votes_ip on public.duel_votes (ip_hash, created_at);
create index if not exists duel_votes_recent on public.duel_votes (created_at);

-- Wochen-Challenge: ein Thema mit eigener Rangliste
create table if not exists public.challenges (
  id           serial primary key,
  title        text not null check (char_length(title) between 3 and 80),
  description  text not null default '' check (char_length(description) <= 300),
  starts_at    timestamptz not null,
  ends_at      timestamptz not null,
  created_at   timestamptz not null default now(),
  check (ends_at > starts_at)
);
alter table public.jokes add column if not exists challenge_id int references public.challenges on delete set null;
create index if not exists jokes_challenge on public.jokes (challenge_id) where challenge_id is not null;

-- Für die Statistik
create index if not exists votes_recent on public.votes (created_at);
create index if not exists jokes_recent on public.jokes (created_at);

-- ───────────────────────── Witz des Tages ─────────────────────────

-- Krönt alle abgeschlossenen Tage (max. 7 zurück), die noch keinen Sieger haben.
-- Wird bei jedem Aufruf der Highlights mit erledigt, ein Zeitplan ist nicht nötig.
create or replace function public.crown_pending() returns void
language plpgsql security definer set search_path = public as $$
declare
  v_local timestamp := now() at time zone 'Europe/Berlin';
  v_last  date := case when v_local::time >= time '20:00' then v_local::date else v_local::date - 1 end;
  v_day   date;
  v_end   timestamptz;
  v_joke  bigint;
begin
  select coalesce(max(w.day) + 1, v_last - 6) into v_day from public.daily_winners w;
  if v_day < v_last - 6 then v_day := v_last - 6; end if;
  while v_day <= v_last loop
    v_end := (v_day + time '20:00') at time zone 'Europe/Berlin';
    v_joke := null;
    -- 1. Wahl: bester Witz der 24 Stunden bis 20 Uhr
    select j.id into v_joke from public.jokes j
    where j.status = 'visible' and j.created_at > v_end - interval '24 hours' and j.created_at <= v_end
      and j.up_count >= 1
      and not exists (select 1 from public.daily_winners w where w.joke_id = j.id)
    order by public.wilson_lower(j.up_count, j.down_count) desc, j.up_count desc, j.created_at
    limit 1;
    -- Ruhiger Tag: bester noch nicht gekrönter Witz der letzten 7 Tage
    if v_joke is null then
      select j.id into v_joke from public.jokes j
      where j.status = 'visible' and j.created_at > v_end - interval '7 days' and j.created_at <= v_end
        and j.up_count >= 1
        and not exists (select 1 from public.daily_winners w where w.joke_id = j.id)
      order by public.wilson_lower(j.up_count, j.down_count) desc, j.up_count desc, j.created_at
      limit 1;
    end if;
    if v_joke is not null then
      insert into public.daily_winners (day, joke_id) values (v_day, v_joke) on conflict do nothing;
    end if;
    v_day := v_day + 1;
  end loop;
end $$;

-- Die letzten gekrönten Witze, neuester zuerst
create or replace function public.get_daily(p_device uuid, p_limit int default 7)
returns table (day date, id bigint, body text, category_slug text, author_name text, created_at timestamptz,
               up_count int, down_count int, score double precision, is_own boolean, my_vote smallint)
language plpgsql volatile security definer set search_path = public as $$
#variable_conflict use_column
begin
  perform public.crown_pending();
  return query
    select w.day, f.id, f.body, f.category_slug, f.author_name, f.created_at, f.up_count, f.down_count, f.score,
           (f.author_device = p_device or f.author_user = auth.uid()) is true, v.value
    from public.daily_winners w
    join public.joke_feed f on f.id = w.joke_id and f.status = 'visible'
    left join public.votes v on v.joke_id = f.id and v.device_id = p_device
    order by w.day desc
    limit least(greatest(p_limit, 1), 60);
end $$;

-- ───────────────────────── Reaktionen ─────────────────────────

create or replace function public.set_reaction(p_device uuid, p_joke bigint, p_kind text)
returns void
language plpgsql security definer set search_path = public as $$
declare
  h        text := public.client_ip_hash();
  v_author uuid;
  v_user   uuid;
begin
  if p_device is null then raise exception 'invalid_device'; end if;
  select j.author_device, j.author_user into v_author, v_user from public.jokes j
  where j.id = p_joke and j.status = 'visible' and j.created_at <= now();
  if not found then raise exception 'joke_not_found'; end if;
  if v_author = p_device or (v_user is not null and v_user = auth.uid()) then raise exception 'own_joke'; end if;

  if p_kind is null or p_kind = '' then
    delete from public.reactions r where r.joke_id = p_joke and r.device_id = p_device;
    return;
  end if;
  if p_kind not in ('lol', 'sigh', 'dead') then raise exception 'invalid_value'; end if;
  if not exists (select 1 from public.reactions r where r.joke_id = p_joke and r.device_id = p_device)
     and (select count(*) from public.reactions r where r.ip_hash = h and r.created_at > now() - interval '1 hour') >= 300 then
    raise exception 'rate_limited';
  end if;
  insert into public.reactions (joke_id, device_id, ip_hash, kind) values (p_joke, p_device, h, p_kind)
  on conflict (joke_id, device_id) do update set kind = excluded.kind;
end $$;

-- Zähler für eine Liste von Witzen (und die eigene Reaktion)
create or replace function public.get_reactions(p_device uuid, p_ids bigint[])
returns table (joke_id bigint, lol int, sigh int, dead int, mine text)
language sql stable security definer set search_path = public as $$
  select r.joke_id,
         count(*) filter (where r.kind = 'lol')::int,
         count(*) filter (where r.kind = 'sigh')::int,
         count(*) filter (where r.kind = 'dead')::int,
         max(r.kind) filter (where r.device_id = p_device)
  from public.reactions r
  where r.joke_id = any(coalesce(p_ids[1:200], '{}'))
  group by r.joke_id
$$;

-- Meiste Reaktionen einer Art in den letzten 7 Tagen (z. B. „Größter Seufzer der Woche“)
create or replace function public.get_reaction_top(p_device uuid, p_kind text, p_limit int default 3)
returns table (id bigint, body text, category_slug text, author_name text, created_at timestamptz,
               up_count int, down_count int, score double precision, is_own boolean, my_vote smallint, n int)
language sql stable security definer set search_path = public as $$
  select f.id, f.body, f.category_slug, f.author_name, f.created_at, f.up_count, f.down_count, f.score,
         (f.author_device = p_device or f.author_user = auth.uid()) is true, v.value, t.n
  from (select r.joke_id, count(*)::int as n from public.reactions r
        where r.kind = p_kind and r.created_at > now() - interval '7 days'
        group by r.joke_id) t
  join public.joke_feed f on f.id = t.joke_id and f.status = 'visible'
  left join public.votes v on v.joke_id = f.id and v.device_id = p_device
  order by t.n desc, f.score desc
  limit least(greatest(p_limit, 1), 20)
$$;

-- ───────────────────────── Duell ─────────────────────────

-- Zwei Witze mit ähnlicher Duell-Wertung, die dieses Gerät noch nicht gegeneinander hatte
create or replace function public.get_duel(p_device uuid)
returns table (id bigint, body text, category_slug text, author_name text, created_at timestamptz,
               up_count int, down_count int, score double precision, is_own boolean, my_vote smallint)
language plpgsql volatile security definer set search_path = public as $$
#variable_conflict use_column
declare
  a bigint; a_elo double precision; b bigint;
begin
  if p_device is null then raise exception 'invalid_device'; end if;
  for i in 1..5 loop
    select j.id, j.elo into a, a_elo from public.jokes j
    where j.status = 'visible' and j.created_at <= now() and j.author_device <> p_device
      and (auth.uid() is null or j.author_user is null or j.author_user <> auth.uid())
    order by (j.duel_count < 10) desc, random()
    limit 1;
    if a is null then return; end if;
    select j.id into b from public.jokes j
    where j.status = 'visible' and j.created_at <= now() and j.id <> a and j.author_device <> p_device
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

create or replace function public.cast_duel(p_device uuid, p_winner bigint, p_loser bigint)
returns void
language plpgsql security definer set search_path = public as $$
declare
  h   text := public.client_ip_hash();
  ew  double precision; el double precision; exp_w double precision;
  k   constant double precision := 24;
  n   int;
begin
  if p_device is null then raise exception 'invalid_device'; end if;
  if p_winner is null or p_loser is null or p_winner = p_loser then raise exception 'invalid_value'; end if;
  if (select count(*) from public.duel_votes d where d.ip_hash = h and d.created_at > now() - interval '1 hour') >= 300 then
    raise exception 'rate_limited';
  end if;
  -- Zeilen sperren, damit gleichzeitige Duelle sich nicht überschreiben (feste Reihenfolge gegen Deadlocks)
  perform 1 from public.jokes j where j.id in (p_winner, p_loser) and j.status = 'visible' order by j.id for update;
  get diagnostics n = row_count;
  if n <> 2 then raise exception 'joke_not_found'; end if;
  if exists (select 1 from public.jokes j where j.id in (p_winner, p_loser)
             and (j.author_device = p_device or (j.author_user is not null and j.author_user = auth.uid()))) then
    raise exception 'own_joke';
  end if;
  insert into public.duel_votes (winner, loser, device_id, ip_hash) values (p_winner, p_loser, p_device, h)
  on conflict do nothing;
  if not found then return; end if;   -- dieses Paar hat das Gerät schon entschieden
  select j.elo into ew from public.jokes j where j.id = p_winner;
  select j.elo into el from public.jokes j where j.id = p_loser;
  exp_w := 1 / (1 + power(10, (el - ew) / 400));
  update public.jokes j set elo = j.elo + k * (1 - exp_w), duel_count = j.duel_count + 1 where j.id = p_winner;
  update public.jokes j set elo = j.elo - k * (1 - exp_w), duel_count = j.duel_count + 1 where j.id = p_loser;
end $$;

-- Duell-Champions: beste Elo-Wertung ab 5 Duellen
create or replace function public.get_duel_ranking(p_device uuid, p_limit int default 10)
returns table (id bigint, body text, category_slug text, author_name text, created_at timestamptz,
               up_count int, down_count int, score double precision, is_own boolean, my_vote smallint,
               elo int, duels int)
language sql stable security definer set search_path = public as $$
  select f.id, f.body, f.category_slug, f.author_name, f.created_at, f.up_count, f.down_count, f.score,
         (f.author_device = p_device or f.author_user = auth.uid()) is true, v.value,
         round(j.elo)::int, j.duel_count
  from public.jokes j
  join public.joke_feed f on f.id = j.id and f.status = 'visible'
  left join public.votes v on v.joke_id = f.id and v.device_id = p_device
  where j.duel_count >= 5
  order by j.elo desc
  limit least(greatest(p_limit, 1), 50)
$$;

-- ───────────────────────── Autoren und Profile ─────────────────────────

-- Witzbold-Rangliste: Wilson-Score über alle Stimmen eines Autors.
-- Mindestens 5 Stimmen (Woche) bzw. 20 (Alltime), damit Masse allein nicht gewinnt.
create or replace function public.get_author_ranking(p_range text, p_limit int default 30)
returns table (username text, jokes int, up_count int, down_count int, score double precision)
language sql stable security definer set search_path = public as $$
  select p.username, count(*)::int, sum(f.up_count)::int, sum(f.down_count)::int,
         public.wilson_lower(sum(f.up_count)::double precision, sum(f.down_count)::double precision)
  from public.joke_feed f
  join public.profiles p on p.id = f.author_user
  where f.status = 'visible'
    and (p_range = 'all' or f.created_at > now() - interval '7 days')
  group by p.id, p.username
  having sum(f.up_count + f.down_count) >= case when p_range = 'all' then 20 else 5 end
  order by 5 desc, 3 desc
  limit least(greatest(p_limit, 1), 100)
$$;

-- Sieger beendeter Challenges (bester Beitrag mit mindestens einem Like)
create or replace view public.challenge_winners as
  select c.id as challenge_id, w.id as joke_id, w.author_user
  from public.challenges c
  cross join lateral (
    select j.id, j.author_user from public.jokes j
    where j.challenge_id = c.id and j.status = 'visible' and j.up_count >= 1
    order by public.wilson_lower(j.up_count, j.down_count) desc, j.up_count desc, j.created_at
    limit 1) w
  where c.ends_at <= now();

create or replace function public.get_profile(p_name text)
returns table (username text, member_since timestamptz, jokes int, up_count int, down_count int,
               top_up int, crowns int, challenge_wins int, best_rank int)
language sql stable security definer set search_path = public as $$
  select p.username, p.created_at,
         count(j.id)::int, coalesce(sum(j.up_count), 0)::int, coalesce(sum(j.down_count), 0)::int,
         coalesce(max(j.up_count), 0)::int,
         (select count(*) from public.daily_winners w join public.jokes x on x.id = w.joke_id where x.author_user = p.id)::int,
         (select count(*) from public.challenge_winners cw where cw.author_user = p.id)::int,
         (select min(r.rk) from (
            select f.author_user, row_number() over (order by f.score desc, f.up_count + f.down_count desc, f.created_at desc) as rk
            from public.joke_feed f where f.status = 'visible' and f.created_at > now() - interval '24 hours') r
          where r.author_user = p.id)::int
  from public.profiles p
  left join public.jokes j on j.author_user = p.id and j.status = 'visible' and j.created_at <= now()
  where lower(p.username) = lower(trim(p_name))
  group by p.id, p.username, p.created_at
$$;

create or replace function public.get_profile_jokes(p_device uuid, p_name text, p_limit int default 30, p_offset int default 0)
returns table (id bigint, body text, category_slug text, author_name text, created_at timestamptz,
               up_count int, down_count int, score double precision, is_own boolean, my_vote smallint)
language sql stable security definer set search_path = public as $$
  select f.id, f.body, f.category_slug, f.author_name, f.created_at, f.up_count, f.down_count, f.score,
         (f.author_device = p_device or f.author_user = auth.uid()) is true, v.value
  from public.joke_feed f
  join public.profiles p on p.id = f.author_user and lower(p.username) = lower(trim(p_name))
  left join public.votes v on v.joke_id = f.id and v.device_id = p_device
  where f.status = 'visible'
  order by f.score desc, f.up_count desc, f.created_at desc
  limit least(greatest(p_limit, 1), 100) offset greatest(p_offset, 0)
$$;

-- Hinweise für angemeldete Autoren: Platz 1–3 heute, Witz des Tages, Like-Meilensteine
create or replace function public.my_highlights()
returns table (kind text, joke_id bigint, value int, body text)
language plpgsql volatile security definer set search_path = public as $$
#variable_conflict use_column
declare
  v_user uuid := auth.uid();
begin
  if v_user is null then return; end if;
  perform public.crown_pending();
  return query
    select 'rank'::text, r.id, r.rk::int, r.body from (
      select f.id, f.body, f.author_user,
             row_number() over (order by f.score desc, f.up_count + f.down_count desc, f.created_at desc) as rk
      from public.joke_feed f where f.status = 'visible' and f.created_at > now() - interval '24 hours') r
    where r.author_user = v_user and r.rk <= 3
    union all
    select 'crown', j.id, to_char(w.day, 'YYYYMMDD')::int, j.body
    from public.daily_winners w join public.jokes j on j.id = w.joke_id
    where j.author_user = v_user and w.day > current_date - 7
    union all
    select 'likes', j.id,
           (select max(m) from unnest(array[10, 25, 50, 100, 250, 500, 1000]) m where m <= j.up_count), j.body
    from public.jokes j
    where j.author_user = v_user and j.status = 'visible' and j.up_count >= 10;
end $$;

-- ───────────────────────── Challenge ─────────────────────────

-- Witz posten und (falls aktiv) bei der Challenge einreichen
create or replace function public.post_joke(p_device uuid, p_category text, p_body text, p_challenge int)
returns bigint
language plpgsql security definer set search_path = public as $$
declare
  v_id bigint;
begin
  v_id := public.post_joke(p_device, p_category, p_body);
  if p_challenge is not null and exists (
       select 1 from public.challenges c where c.id = p_challenge and now() >= c.starts_at and now() < c.ends_at) then
    update public.jokes j set challenge_id = p_challenge where j.id = v_id;
  end if;
  return v_id;
end $$;

-- Laufende und die letzten beendeten Challenges
create or replace function public.get_challenges()
returns table (id int, title text, description text, starts_at timestamptz, ends_at timestamptz,
               active boolean, entries int, winner_name text, winner_joke bigint)
language sql stable security definer set search_path = public as $$
  select c.id, c.title, c.description, c.starts_at, c.ends_at,
         now() >= c.starts_at and now() < c.ends_at,
         (select count(*) from public.jokes j where j.challenge_id = c.id and j.status = 'visible')::int,
         (select x.author_name from public.jokes x where x.id = cw.joke_id), cw.joke_id
  from public.challenges c
  left join public.challenge_winners cw on cw.challenge_id = c.id
  where c.starts_at <= now()
  order by (now() < c.ends_at) desc, c.ends_at desc
  limit 6
$$;

create or replace function public.get_challenge_ranking(p_device uuid, p_challenge int, p_limit int default 30)
returns table (id bigint, body text, category_slug text, author_name text, created_at timestamptz,
               up_count int, down_count int, score double precision, is_own boolean, my_vote smallint)
language sql stable security definer set search_path = public as $$
  select f.id, f.body, f.category_slug, f.author_name, f.created_at, f.up_count, f.down_count, f.score,
         (f.author_device = p_device or f.author_user = auth.uid()) is true, v.value
  from public.joke_feed f
  join public.jokes j on j.id = f.id and j.challenge_id = p_challenge
  left join public.votes v on v.joke_id = f.id and v.device_id = p_device
  where f.status = 'visible'
  order by f.score desc, f.up_count + f.down_count desc, f.created_at desc
  limit least(greatest(p_limit, 1), 100)
$$;

-- Challenge anlegen (p_id null) oder ändern
create or replace function public.admin_save_challenge(p_key text, p_id int, p_title text, p_description text,
                                                       p_starts timestamptz, p_ends timestamptz)
returns int
language plpgsql security definer set search_path = public as $$
declare
  v_id int;
begin
  if not public.admin_check(p_key) then raise exception 'not_admin'; end if;
  if p_starts is null or p_ends is null or p_ends <= p_starts then raise exception 'invalid_value'; end if;
  if p_id is null then
    insert into public.challenges (title, description, starts_at, ends_at)
    values (trim(p_title), trim(coalesce(p_description, '')), p_starts, p_ends) returning challenges.id into v_id;
  else
    update public.challenges c set title = trim(p_title), description = trim(coalesce(p_description, '')),
           starts_at = p_starts, ends_at = p_ends where c.id = p_id returning c.id into v_id;
  end if;
  return v_id;
end $$;

-- ───────────────────────── Statistik und Vorrat (Admin) ─────────────────────────

create or replace function public.admin_stats(p_key text, p_days int default 14)
returns table (day date, votes int, voters int, reactions int, duels int, new_jokes int, signups int)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not public.admin_check(p_key) then raise exception 'not_admin'; end if;
  return query
    with d as (
      select g::date as day,
             (g::date::timestamp at time zone 'Europe/Berlin') as t0,
             ((g::date + 1)::timestamp at time zone 'Europe/Berlin') as t1
      from generate_series((now() at time zone 'Europe/Berlin')::date - (least(greatest(p_days, 1), 90) - 1),
                           (now() at time zone 'Europe/Berlin')::date, interval '1 day') g)
    select d.day,
      (select count(*) from public.votes v where v.created_at >= d.t0 and v.created_at < d.t1)::int,
      (select count(distinct x.dev) from (
         select v.device_id as dev from public.votes v where v.created_at >= d.t0 and v.created_at < d.t1
         union all select r.device_id from public.reactions r where r.created_at >= d.t0 and r.created_at < d.t1
         union all select q.device_id from public.duel_votes q where q.created_at >= d.t0 and q.created_at < d.t1) x)::int,
      (select count(*) from public.reactions r where r.created_at >= d.t0 and r.created_at < d.t1)::int,
      (select count(*) from public.duel_votes q where q.created_at >= d.t0 and q.created_at < d.t1)::int,
      (select count(*) from public.jokes j where j.author_user is not null and j.created_at >= d.t0 and j.created_at < d.t1)::int,
      (select count(*) from public.profiles p where p.created_at >= d.t0 and p.created_at < d.t1)::int
    from d order by d.day;
end $$;

create or replace function public.admin_totals(p_key text)
returns table (jokes int, user_jokes int, users int, votes int, devices int, queued int, queue_until timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.admin_check(p_key) then raise exception 'not_admin'; end if;
  return query select
    (select count(*) from public.jokes j where j.status = 'visible' and j.created_at <= now())::int,
    (select count(*) from public.jokes j where j.status = 'visible' and j.author_user is not null)::int,
    (select count(*) from public.profiles)::int,
    (select count(*) from public.votes)::int,
    (select count(distinct v.device_id) from public.votes v)::int,
    (select count(*) from public.jokes j where j.status = 'visible' and j.created_at > now())::int,
    (select max(j.created_at) from public.jokes j where j.status = 'visible' and j.created_at > now());
end $$;

create or replace function public.admin_category_stats(p_key text)
returns table (slug text, name text, jokes int, queued int, votes_week int)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not public.admin_check(p_key) then raise exception 'not_admin'; end if;
  return query
    select c.slug, c.name,
      (select count(*) from public.jokes j where j.category_id = c.id and j.status = 'visible' and j.created_at <= now())::int,
      (select count(*) from public.jokes j where j.category_id = c.id and j.status = 'visible' and j.created_at > now())::int,
      (select count(*) from public.votes v join public.jokes j on j.id = v.joke_id
        where j.category_id = c.id and v.created_at > now() - interval '7 days')::int
    from public.categories c order by c.position;
end $$;

-- Witz-Vorrat: mehrere Witze auf einmal einplanen. Sie erscheinen nacheinander
-- (p_per_day pro Tag) im Anschluss an die schon geplanten Witze. Duplikate werden übersprungen.
create or replace function public.admin_bulk_add(p_key text, p_category text, p_bodies text[], p_per_day int)
returns table (inserted int, skipped int)
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_cat   int;
  v_start timestamptz;
  v_step  interval := interval '24 hours' / least(greatest(coalesce(p_per_day, 3), 1), 48);
  v_body  text;
  v_norm  text;
  v_ins   int := 0;
  v_skip  int := 0;
begin
  if not public.admin_check(p_key) then raise exception 'not_admin'; end if;
  select c.id into v_cat from public.categories c where c.slug = p_category;
  if v_cat is null then raise exception 'invalid_category'; end if;
  select greatest(now(), coalesce(max(j.created_at), now())) into v_start
  from public.jokes j where j.status = 'visible' and j.author_user is null and j.created_at > now();
  foreach v_body in array coalesce(p_bodies[1:500], '{}') loop
    v_body := trim(v_body);
    if char_length(v_body) not between 10 and 500 then v_skip := v_skip + 1; continue; end if;
    v_norm := public.normalize_joke(v_body);
    if exists (select 1 from public.jokes j where j.status <> 'removed' and j.body_norm % v_norm
               and similarity(j.body_norm, v_norm) >= 0.6) then
      v_skip := v_skip + 1; continue;
    end if;
    v_ins := v_ins + 1;
    insert into public.jokes (category_id, body, author_name, author_device, created_at)
    values (v_cat, v_body, 'Lachwerk', '00000000-0000-0000-0000-000000000000', v_start + v_step * v_ins);
  end loop;
  return query select v_ins, v_skip;
end $$;

-- ───────────────────────── Rechte ─────────────────────────

alter table public.daily_winners enable row level security;
alter table public.reactions     enable row level security;
alter table public.duel_votes    enable row level security;
alter table public.challenges    enable row level security;

revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke execute on all functions in schema public from public, anon, authenticated;
grant select on public.categories to anon, authenticated;

grant execute on function
  public.get_ranking(uuid, text, text, int, int),
  public.get_joke(uuid, bigint),
  public.get_unrated(uuid, bigint[], int),
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
  public.cast_duel(uuid, bigint, bigint),
  public.get_duel_ranking(uuid, int),
  public.get_author_ranking(text, int),
  public.get_profile(text),
  public.get_profile_jokes(uuid, text, int, int),
  public.my_highlights(),
  public.get_challenges(),
  public.get_challenge_ranking(uuid, int, int),
  public.admin_save_challenge(text, int, text, text, timestamptz, timestamptz),
  public.admin_stats(text, int),
  public.admin_totals(text),
  public.admin_category_stats(text),
  public.admin_bulk_add(text, text, text[], int)
to anon, authenticated;

-- ───────────────────────── Erste Challenge ─────────────────────────
-- Läuft bis Sonntag 20 Uhr (deutsche Zeit). Nur, wenn es noch keine Challenge gibt.
insert into public.challenges (title, description, starts_at, ends_at)
select 'Witze übers Fitnessstudio',
       'Hanteln, Laufband, Neujahrsvorsätze: Dein bester Witz rund ums Training. Der Beitrag mit dem besten Score am Sonntagabend gewinnt.',
       now(),
       case when e > now() then e else e + interval '7 days' end
from (select ((date_trunc('week', now() at time zone 'Europe/Berlin') + interval '6 days 20 hours')
              at time zone 'Europe/Berlin') as e) x
where not exists (select 1 from public.challenges);

-- ═══════════════════════════════════════════════════════════════════
-- Erweiterung 2: Pointen-Battle, Monats-Saison, Lieblingskategorien, Wortfilter
-- (identisch mit erweiterung2.sql)
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

-- ═══════════════════════════════════════════════════════════════════
-- Erweiterung 3: größerer Admin-Bereich (identisch mit erweiterung3.sql)
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

-- ═══════════════════════════════════════════════════════════════════
-- Erweiterung 4: Sponsoren, Kontakt, weitere Admins (identisch mit erweiterung4.sql)
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

-- ═══════════════════════════════════════════════════════════════════
-- Erweiterung 6: Konto löschen, Pointen melden (identisch mit erweiterung6.sql)
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

-- ═════════ Erweiterung 7: Kurzlinks für Bildschirme ═════════

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

-- ═════════ Erweiterung 8: Quiz, Live-Duell, Gruppen ═════════

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

-- ═════════ Erweiterung 9: Bestenliste „Neu“ ═════════
create or replace function public.get_ranking(p_device uuid, p_range text, p_category text default null,
                                              p_limit int default 30, p_offset int default 0)
returns table (id bigint, body text, category_slug text, author_name text, created_at timestamptz,
               up_count int, down_count int, score double precision, is_own boolean, my_vote smallint)
language sql stable security definer set search_path = public as $$
  select f.id, f.body, f.category_slug, f.author_name, f.created_at, f.up_count, f.down_count, f.score,
         (f.author_device = p_device or f.author_user = auth.uid()) is true, v.value
  from public.joke_feed f
  left join public.votes v on v.joke_id = f.id and v.device_id = p_device
  where f.status = 'visible'
    and (p_category is null or f.category_slug = p_category)
    and case p_range
          when 'new'  then f.created_at > now() - interval '6 hours'
          when 'day'  then f.created_at > now() - interval '24 hours'
          when 'week' then f.created_at > now() - interval '7 days'
          else f.up_count + f.down_count >= 20
        end
  order by case when p_range = 'new' then f.created_at end desc nulls last,
           f.score desc, f.up_count + f.down_count desc, f.created_at desc
  limit least(greatest(p_limit, 1), 100) offset greatest(p_offset, 0)
$$;

-- ═════════ Erweiterung 12: anonyme Besucherzählung ═════════
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

-- ═════════ Erweiterung 13: Bildschirm-Option Motivationssprüche ═════════
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
  where k in ('f', 'dreh', 'bg', 'ac', 'card', 'k', 'n', 's', 't', 'live', 'g', 'mot') and v is not null and v <> '';
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

-- ═════════ Erweiterung 14: Wortfilter repariert und ergänzt ═════════
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

-- Ergänzungen (vorhandene Wörter bleiben, Doppelte werden übersprungen)
insert into public.banned_words (word)
select unnest(array[
  -- vom Admin gewünscht
  'nazi*', 'hitler', 'adolf',
  -- Beleidigungen
  'hure*', 'wichser*', 'wixer', 'wixxer', 'fotze*', 'missgeburt*', 'spacko*', 'spacken', 'schwanzlutscher',
  -- abwertend gegen Gruppen
  'schwuchtel*', 'tunte*', 'transe', 'kanacke*', 'nigger*', 'nigga*', 'bimbo*', 'schlitzauge*', 'kümmeltürk*',
  'kameltreiber*', 'polacke*', 'judenschwein*', 'mongoloid*', 'krüppel*',
  -- NS-Bezug und Gewalt
  'untermensch*', 'endlösung', 'hakenkreuz*', 'auschwitz*', 'vergewaltig*', 'kinderficker*', 'kinderschänder*', 'pädo*'
]) on conflict do nothing;

grant execute on function public.admin_set_words(text, text[]) to anon, authenticated;

-- ═════════ Erweiterung 15: Admin-Dashboard, Protokoll, Nutzer-Details ═════════
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

-- ───────────────────────── Zum Schluss ─────────────────────────
-- Admin-Schlüssel für die Moderation (mind. 12 Zeichen, gut merken!).
-- Ersetze den Text, markiere NUR diese Zeile und führe sie aus:
--
-- select public.set_admin_key('hier-dein-geheimer-schluessel');
