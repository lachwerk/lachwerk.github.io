-- ═══════════════════════════════════════════════════════════════════
-- Lachwerk – Erweiterung 9: Bestenliste „Neu“ (Witze der letzten 6 Stunden, neueste zuerst)
-- Setzt die bisherigen Erweiterungen voraus. Mehrfach ausführen ist unschädlich.
-- ═══════════════════════════════════════════════════════════════════
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
