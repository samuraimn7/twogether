-- Twogether — week status for the check-in lobby.
-- Lets each partner see WHO has checked in this week (a boolean per partner),
-- WITHOUT exposing any answers. Answers themselves stay gated by 0004 until both
-- have submitted. SECURITY DEFINER so it can read both partners' existence, but it
-- only ever returns booleans and only for the caller's own couple.
create or replace function public.week_status(wk text)
returns table(partner_index int, submitted boolean)
language sql security definer set search_path = public as $$
  select m.partner_index,
         exists(
           select 1 from public.checkins c
           where c.couple_id = m.couple_id
             and c.iso_week = wk
             and c.partner_index = m.partner_index
         )
    from public.couple_members m
   where m.couple_id = (
     select couple_id from public.couple_members where user_id = auth.uid()
   );
$$;
grant execute on function public.week_status(text) to authenticated;
