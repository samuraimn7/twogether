-- Twogether — enforce reveal privacy at the data layer.
-- Rule: before the reveal, a partner can NOT write, override, or read your entry.
--   • write / override  → already blocked (checkins_insert forces partner_index =
--     your own slot + user_id = you; checkins_update requires user_id = you).
--   • read              → tightened here: you may read your partner's answers for a
--     week ONLY after you've submitted your own for that same week (i.e. once it
--     would reveal). Your own answers you can always read.

-- Helper (SECURITY DEFINER so it doesn't recurse through checkins' own RLS).
create or replace function public.i_submitted(c uuid, wk text)
returns boolean language sql security definer set search_path = public as $$
  select exists (
    select 1 from public.checkins
    where couple_id = c and iso_week = wk and user_id = auth.uid()
  );
$$;
grant execute on function public.i_submitted(uuid, text) to authenticated;

drop policy if exists "checkins_read" on public.checkins;
create policy "checkins_read" on public.checkins
  for select using (
    public.is_member(couple_id)
    and (
      user_id = auth.uid()                          -- always read your own
      or public.i_submitted(couple_id, iso_week)    -- partner's: only after you've submitted this week
    )
  );
