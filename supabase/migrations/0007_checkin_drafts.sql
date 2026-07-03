-- Twogether — cloud-synced in-progress drafts (self-contained). Run after 0006.
-- A draft is an UNSUBMITTED check-in that follows the user across devices. It is
-- deliberately NOT stored in `checkins` (that would trip the reveal/lobby "done"
-- logic and let a partner read it after they submit). Instead it lives here,
-- readable ONLY by its owner — the partner can never see an in-progress draft.
-- One draft per couple+user; overwritten as they type, deleted on submit.

create table if not exists public.checkin_drafts (
  couple_id  uuid not null references public.couples(id) on delete cascade,
  user_id    uuid not null references auth.users(id)   on delete cascade,
  answers    jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  primary key (couple_id, user_id)
);

alter table public.checkin_drafts enable row level security;

-- Owner-only: you can read/write/delete YOUR OWN draft and nobody else's.
drop policy if exists "drafts_select" on public.checkin_drafts;
create policy "drafts_select" on public.checkin_drafts
  for select using (user_id = auth.uid());

drop policy if exists "drafts_insert" on public.checkin_drafts;
create policy "drafts_insert" on public.checkin_drafts
  for insert with check (user_id = auth.uid() and public.is_member(couple_id));

drop policy if exists "drafts_update" on public.checkin_drafts;
create policy "drafts_update" on public.checkin_drafts
  for update using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "drafts_delete" on public.checkin_drafts;
create policy "drafts_delete" on public.checkin_drafts
  for delete using (user_id = auth.uid());
