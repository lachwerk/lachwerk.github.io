-- ═══════════════════════════════════════════════════════════════════
-- Lachwerk – Erweiterung 16: Besucherzählung genauer, Bewerter einheitlich gezählt
-- Mehrfach ausführen ist unschädlich.
-- ═══════════════════════════════════════════════════════════════════

create or replace function public.track_view(p_route text, p_source text default null, p_device text default null) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  d      date := (now() at time zone 'Europe/Berlin')::date;
  hdr    json := nullif(current_setting('request.headers', true), '')::json;
  ip     text := coalesce(trim(split_part(hdr ->> 'x-forwarded-for', ',', 1)), '');
  net    text;
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
  -- Handys wechseln ihre IPv6-Adresse oft (Datenschutz-Erweiterung). Damit ein Handy nicht mehrfach
  -- zählt, wird bei IPv6 nur der Netz-Teil (/64) verwendet, bei IPv4 die volle Adresse.
  begin
    net := case when position(':' in ip) > 0 then host(network(set_masklen(ip::inet, 64))) else ip end;
  exception when others then net := ip;
  end;
  h := encode(digest(net || '|' || ua || '|' || salt, 'sha256'), 'hex');

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
  v as (select (x.created_at at time zone 'Europe/Berlin')::date as d, count(*) as n from public.votes x where x.created_at >= t30 group by 1),
  dv as (select (z.created_at at time zone 'Europe/Berlin')::date as d, count(distinct z.dev) as dev from (
           select x.device_id as dev, x.created_at from public.votes x where x.created_at >= t30
           union all select x.device_id, x.created_at from public.duel_votes x where x.created_at >= t30
           union all select x.device_id, x.created_at from public.reactions x where x.created_at >= t30) z group by 1),
  j as (select (x.created_at at time zone 'Europe/Berlin')::date as d, count(*) as n
        from public.jokes x where x.author_user is not null and x.created_at >= t30 and x.created_at <= now() group by 1),
  s as (select (x.created_at at time zone 'Europe/Berlin')::date as d, count(*) as n from public.profiles x where x.created_at >= t30 group by 1),
  rp as (select (x.created_at at time zone 'Europe/Berlin')::date as d, count(*) as n from public.reports x where x.created_at >= t30 group by 1)
  select json_build_object(
    'days', (select json_agg(json_build_object(
                'day', days.d, 'visitors', coalesce(vd.uniques, 0), 'views', coalesce(vd.views, 0),
                'voters', coalesce(dv.dev, 0), 'votes', coalesce(v.n, 0), 'jokes', coalesce(j.n, 0),
                'signups', coalesce(s.n, 0), 'reports', coalesce(rp.n, 0)) order by days.d)
             from days left join public.visit_daily vd on vd.day = days.d left join v on v.d = days.d left join dv on dv.d = days.d
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
