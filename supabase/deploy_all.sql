-- Twogether — run this whole file once in the Supabase SQL editor.
-- (Concatenation of migrations 0001–0004; source of truth is supabase/migrations/.)


-- ===== 0001_auth_pairing.sql =====
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

-- ===== 0002_pairing_immutable.sql =====
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

-- ===== 0003_backfill_legacy.sql =====
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

-- ===== 0004_private_until_reveal.sql =====
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
