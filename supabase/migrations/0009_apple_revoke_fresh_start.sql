-- Twogether — Sign in with Apple token revocation + fresh start for the remaining
-- partner. Run after 0008. Idempotent — safe to run more than once.

-- 1) Apple refresh tokens, kept so the account can be revoked with Apple on deletion
--    (Apple's account-deletion requirement for Sign in with Apple). Write-only from the
--    client via save_apple_token(); no read policy, so only the service role (the
--    revoke-apple Edge Function) can ever read a token back.
create table if not exists public.apple_tokens (
  user_id       uuid primary key references auth.users(id) on delete cascade,
  refresh_token text not null,
  updated_at    timestamptz not null default now()
);
alter table public.apple_tokens enable row level security;

create or replace function public.save_apple_token(p_token text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or coalesce(p_token,'') = '' then return; end if;
  insert into public.apple_tokens(user_id, refresh_token, updated_at)
    values (auth.uid(), p_token, now())
  on conflict (user_id) do update set refresh_token = excluded.refresh_token, updated_at = now();
end; $$;

-- 2) A space whose partner deleted their account is "ended": the remaining partner
--    keeps reading their archive but can't check in, and may start fresh.
alter table public.couples add column if not exists ended boolean not null default false;

create or replace function public.delete_my_account()
returns void language plpgsql security definer set search_path = public, auth as $$
declare me uuid := auth.uid(); c uuid; other uuid;
begin
  if me is null then raise exception 'not_signed_in'; end if;
  select couple_id into c from public.couple_members where user_id = me;
  if c is not null then
    select user_id into other from public.couple_members where couple_id = c and user_id <> me;
    if other is not null then
      update public.couples set created_by = other, ended = true where id = c;
    end if;
  end if;
  perform set_config('twogether.account_deletion', me::text, true);
  delete from auth.users where id = me;   -- cascades: membership, my check-ins, draft, apple token
end; $$;

-- 3) Remaining partner starts fresh: deletes the ended space (their membership,
--    their answers, their draft) so they can pair again. Only allowed once ended.
create or replace function public.leave_ended_couple()
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); c uuid;
begin
  select m.couple_id into c from public.couple_members m
    join public.couples k on k.id = m.couple_id
   where m.user_id = me and k.ended;
  if c is null then raise exception 'not_ended'; end if;
  perform set_config('twogether.account_deletion', me::text, true);
  delete from public.couples where id = c;
end; $$;

revoke all on function public.save_apple_token(text)  from public, anon;
revoke all on function public.delete_my_account()     from public, anon;
revoke all on function public.leave_ended_couple()    from public, anon;
grant execute on function public.save_apple_token(text) to authenticated;
grant execute on function public.delete_my_account()    to authenticated;
grant execute on function public.leave_ended_couple()   to authenticated;
