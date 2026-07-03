-- Twogether — private photo storage for check-ins (self-contained: creates the
-- bucket AND its policies). Idempotent — safe to run more than once.
-- Photos live at path:  {couple_id}/{iso_week}/{partner_index}/{file}
-- so the first folder segment is the couple_id.

-- 1) the private bucket
insert into storage.buckets (id, name, public)
values ('checkin-photos', 'checkin-photos', false)
on conflict (id) do nothing;

-- 2) only a couple's two members can read/write photos in their own folder
drop policy if exists "checkin_photos_read" on storage.objects;
create policy "checkin_photos_read" on storage.objects
  for select to authenticated using (
    bucket_id = 'checkin-photos'
    and (storage.foldername(name))[1] = (
      select couple_id::text from public.couple_members where user_id = auth.uid()));

drop policy if exists "checkin_photos_write" on storage.objects;
create policy "checkin_photos_write" on storage.objects
  for insert to authenticated with check (
    bucket_id = 'checkin-photos'
    and (storage.foldername(name))[1] = (
      select couple_id::text from public.couple_members where user_id = auth.uid()));

drop policy if exists "checkin_photos_delete" on storage.objects;
create policy "checkin_photos_delete" on storage.objects
  for delete to authenticated using (
    bucket_id = 'checkin-photos'
    and (storage.foldername(name))[1] = (
      select couple_id::text from public.couple_members where user_id = auth.uid()));
