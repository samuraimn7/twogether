-- Twogether — in-app account deletion (App Store guideline 5.1.1(v)) + editable
-- display name (so Sign in with Apple never has to ask for one). Run after 0007.
-- Idempotent — safe to run more than once.
--
-- What deleting an account removes: the user's auth account, their membership,
-- their own check-in answers and their draft (all via the existing ON DELETE CASCADE
-- foreign keys to auth.users). The PARTNER'S own answers are kept; if the deleted
-- user created the space, ownership moves to the partner first so the cascade on
-- couples.created_by can't wipe the partner's history. Photos are removed from
-- Storage by the client before it calls delete_my_account().

-- 1) Pairing stays permanent, but the display name may change.
create or replace function public.block_member_update()
returns trigger language plpgsql as $$
begin
  if new.couple_id     is distinct from old.couple_id
  or new.user_id       is distinct from old.user_id
  or new.partner_index is distinct from old.partner_index then
    raise exception 'pairing is permanent and cannot be changed';
  end if;
  return new;
end; $$;

-- 2) Membership still can't be removed — except as part of that user's own
--    account deletion (flag set, transaction-local, by delete_my_account below;
--    clients have no way to set it themselves).
create or replace function public.block_member_delete()
returns trigger language plpgsql as $$
begin
  if current_setting('twogether.account_deletion', true) = old.user_id::text then
    return old;
  end if;
  raise exception 'pairing is permanent and cannot be removed';
end; $$;

-- 3) Set my display name (optional — blank falls back to "Partner 1/2" in the app).
create or replace function public.set_my_name(p_name text)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.couple_members
     set display_name = nullif(left(trim(coalesce(p_name,'')), 60), '')
   where user_id = auth.uid();
end; $$;

-- 4) Permanently delete the caller's account.
create or replace function public.delete_my_account()
returns void language plpgsql security definer set search_path = public, auth as $$
declare me uuid := auth.uid(); c uuid; other uuid;
begin
  if me is null then raise exception 'not_signed_in'; end if;
  select couple_id into c from public.couple_members where user_id = me;
  if c is not null then
    select user_id into other from public.couple_members where couple_id = c and user_id <> me;
    if other is not null then
      update public.couples set created_by = other where id = c and created_by = me;
    end if;
  end if;
  perform set_config('twogether.account_deletion', me::text, true);
  delete from auth.users where id = me;   -- cascades: membership, my check-ins, my draft
end; $$;

revoke all on function public.set_my_name(text)    from public, anon;
revoke all on function public.delete_my_account()  from public, anon;
grant execute on function public.set_my_name(text)   to authenticated;
grant execute on function public.delete_my_account() to authenticated;
