-- Twogether — make pairing permanent (one account = one partner, for life).
-- Run after 0001. Belt-and-suspenders: RLS already denies client UPDATE/DELETE on
-- couple_members (no such policies exist), and a unique index limits one couple per
-- user. This adds DB-level triggers so membership can NEVER be moved or removed,
-- even by a future bug, a service-role call, or a careless dashboard edit.

-- Block changing a membership row (couple_id / user_id / partner_index are forever).
create or replace function public.block_member_update()
returns trigger language plpgsql as $$
begin
  raise exception 'pairing is permanent and cannot be changed';
end; $$;

drop trigger if exists couple_members_no_update on public.couple_members;
create trigger couple_members_no_update
  before update on public.couple_members
  for each row execute function public.block_member_update();

-- Block removing a membership row (no un-pairing, ever).
create or replace function public.block_member_delete()
returns trigger language plpgsql as $$
begin
  raise exception 'pairing is permanent and cannot be removed';
end; $$;

drop trigger if exists couple_members_no_delete on public.couple_members;
create trigger couple_members_no_delete
  before delete on public.couple_members
  for each row execute function public.block_member_delete();

-- Once a couple is locked (both partners joined) it stays locked forever.
create or replace function public.keep_couple_locked()
returns trigger language plpgsql as $$
begin
  if old.locked and not new.locked then
    raise exception 'a locked couple cannot be unlocked';
  end if;
  return new;
end; $$;

drop trigger if exists couples_stay_locked on public.couples;
create trigger couples_stay_locked
  before update on public.couples
  for each row execute function public.keep_couple_locked();
