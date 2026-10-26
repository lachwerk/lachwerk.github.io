-- ═══════════════════════════════════════════════════════════════════
-- Lachwerk – Erweiterung 13: Bildschirm-Kurzlinks merken sich auch die Option „Motivationssprüche“ (mot)
-- Mehrfach ausführen ist unschädlich.
-- ═══════════════════════════════════════════════════════════════════
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
