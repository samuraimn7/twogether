-- Twogether — bring legacy (name-keyed) history into the new account schema.
-- Run after 0001 + 0002. Idempotent and non-destructive: it only READS the
-- preserved couples_legacy / checkins_legacy tables and inserts into the new
-- checkins (skipping anything already there). Old tables are never modified.
--
-- A signed-in, paired user calls claim_legacy_history(): it rebuilds their old
-- couple_id from the two partners' names (the same rule the old app used), then
-- copies THIS user's old check-ins into the new couple under their account.

create or replace function public.claim_legacy_history()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_couple    uuid;
  v_my_idx    int;
  v_my_name   text;
  v_names     text[];
  v_legacy_id text;
  v_name0     text;
  v_name1     text;
  v_old_idx   int;
  v_count     int := 0;
  v_norm      text;
begin
  -- nothing to do if the legacy tables don't exist (a brand-new project)
  if to_regclass('public.couples_legacy') is null
     or to_regclass('public.checkins_legacy') is null then
    return 0;
  end if;

  select couple_id, partner_index, display_name
    into v_couple, v_my_idx, v_my_name
    from public.couple_members where user_id = auth.uid();
  if v_couple is null then return 0; end if;

  -- both names are needed to reconstruct the old couple_id
  select array_agg(display_name order by partner_index)
    into v_names from public.couple_members where couple_id = v_couple;
  if coalesce(array_length(v_names,1),0) <> 2 then return 0; end if;

  -- old couple_id = the two normalized names (lowercase, no spaces), sorted, joined by '_'
  v_legacy_id := (
    select string_agg(n, '_' order by n) from (
      select regexp_replace(lower(x), '\s+', '', 'g') as n from unnest(v_names) as x
    ) z
  );

  select name0, name1 into v_name0, v_name1
    from public.couples_legacy where couple_id = v_legacy_id;
  if v_name0 is null and v_name1 is null then return 0; end if;

  -- which old slot is me? match my name to name0 / name1
  v_norm := regexp_replace(lower(v_my_name), '\s+', '', 'g');
  if v_norm = regexp_replace(lower(coalesce(v_name0,'')), '\s+', '', 'g') then
    v_old_idx := 0;
  elsif v_norm = regexp_replace(lower(coalesce(v_name1,'')), '\s+', '', 'g') then
    v_old_idx := 1;
  else
    return 0; -- name matches neither side; skip rather than mis-attribute
  end if;

  insert into public.checkins (couple_id, iso_week, partner_index, user_id, answers, submitted_at)
  select v_couple, c.iso_week, v_my_idx, auth.uid(), c.answers::jsonb, coalesce(c.submitted_at, now())
    from public.checkins_legacy c
   where c.couple_id = v_legacy_id
     and c.partner_index = v_old_idx
  on conflict (couple_id, iso_week, partner_index) do nothing;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

grant execute on function public.claim_legacy_history() to authenticated;
