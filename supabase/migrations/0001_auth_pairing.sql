-- Twogether — auth + pairing + Row-Level Security
-- Run this in the Supabase SQL editor (Dashboard → SQL → New query → Run),
-- or via `supabase db push` if you use the CLI.
--
-- This REPLACES the old name-derived `couple_id` model with real per-user
-- identity. Run ONCE.

-- ── Preserve existing data ────────────────────────────────────────────────
-- Move the old name-keyed tables aside (renamed to *_legacy) so NOTHING is
-- deleted. Old check-ins remain queryable in couples_legacy / checkins_legacy
-- and can be back-filled into the new schema later if desired.
alter table if exists public.couples  rename to couples_legacy;
alter table if exists public.checkins rename to checkins_legacy;

-- ── Tables ────────────────────────────────────────────────────────────────

create table if not exists public.couples (
  id          uuid primary key default gen_random_uuid(),
  invite_code text unique not null,
  locked      boolean not null default false,         -- true once 2 partners joined
  created_by  uuid not null references auth.users(id) on delete cascade,
  created_at  timestamptz not null default now()
);

create table if not exists public.couple_members (
  couple_id     uuid not null references public.couples(id) on delete cascade,
  user_id       uuid not null references auth.users(id) on delete cascade,
  partner_index int  not null check (partner_index in (0,1)),
  display_name  text,
  joined_at     timestamptz not null default now(),
  primary key (couple_id, user_id),
  unique (couple_id, partner_index)
);
-- one user can belong to exactly one couple
create unique index if not exists couple_members_one_per_user
  on public.couple_members(user_id);

create table if not exists public.checkins (
  id            uuid primary key default gen_random_uuid(),
  couple_id     uuid not null references public.couples(id) on delete cascade,
  iso_week      text not null,
  partner_index int  not null check (partner_index in (0,1)),
  user_id       uuid not null references auth.users(id) on delete cascade,
  answers       jsonb not null default '{}'::jsonb,
  submitted_at  timestamptz not null default now(),
  unique (couple_id, iso_week, partner_index)
);

-- ── Row-Level Security ────────────────────────────────────────────────────

alter table public.couples         enable row level security;
alter table public.couple_members  enable row level security;
alter table public.checkins        enable row level security;

-- membership check used by every policy
create or replace function public.is_member(c uuid)
returns boolean language sql security definer set search_path = public as $$
  select exists (
    select 1 from public.couple_members m
    where m.couple_id = c and m.user_id = auth.uid()
  );
$$;

create policy "couples_read"  on public.couples
  for select using (public.is_member(id));

create policy "members_read"  on public.couple_members
  for select using (public.is_member(couple_id));

create policy "checkins_read" on public.checkins
  for select using (public.is_member(couple_id));

create policy "checkins_insert" on public.checkins
  for insert with check (
    public.is_member(couple_id)
    and user_id = auth.uid()
    and partner_index = (
      select partner_index from public.couple_members
      where couple_id = checkins.couple_id and user_id = auth.uid()
    )
  );

create policy "checkins_update" on public.checkins
  for update using (public.is_member(couple_id) and user_id = auth.uid())
  with check (user_id = auth.uid());

-- ── Pairing RPCs (SECURITY DEFINER so they can lock/guard safely) ──────────

-- Create a couple; caller becomes partner 0. Returns the new couple row.
create or replace function public.create_couple(p_name text)
returns public.couples language plpgsql security definer set search_path = public as $$
declare c public.couples; code text;
begin
  if exists (select 1 from public.couple_members where user_id = auth.uid()) then
    raise exception 'already_in_couple';
  end if;
  -- 6-char invite code; retry on the (rare) collision
  loop
    code := upper(substr(replace(gen_random_uuid()::text,'-',''),1,6));
    exit when not exists (select 1 from public.couples where invite_code = code);
  end loop;
  insert into public.couples(invite_code, created_by) values (code, auth.uid())
    returning * into c;
  insert into public.couple_members(couple_id, user_id, partner_index, display_name)
    values (c.id, auth.uid(), 0, p_name);
  return c;
end; $$;

-- Join a couple by invite code; caller becomes partner 1 and the couple locks.
create or replace function public.join_couple(p_code text, p_name text)
returns public.couples language plpgsql security definer set search_path = public as $$
declare c public.couples; cnt int;
begin
  if exists (select 1 from public.couple_members where user_id = auth.uid()) then
    raise exception 'already_in_couple';
  end if;
  select * into c from public.couples where invite_code = upper(trim(p_code));
  if c.id is null then raise exception 'invalid_code'; end if;
  if c.locked    then raise exception 'couple_locked'; end if;
  select count(*) into cnt from public.couple_members where couple_id = c.id;
  if cnt >= 2 then raise exception 'couple_full'; end if;
  insert into public.couple_members(couple_id, user_id, partner_index, display_name)
    values (c.id, auth.uid(), 1, p_name);
  update public.couples set locked = true where id = c.id returning * into c;
  return c;
end; $$;

grant execute on function public.create_couple(text)         to authenticated;
grant execute on function public.join_couple(text, text)     to authenticated;
