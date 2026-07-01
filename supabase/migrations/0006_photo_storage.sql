-- Twogether — private photo storage for check-ins.
-- PREREQUISITE: in the dashboard, create a Storage bucket named "checkin-photos"
-- with "Public" OFF (private). Then run this to lock it down so only a couple's
-- two members can read/write photos in their own folder.
--
-- Photos are stored at path:  {couple_id}/{iso_week}/{partner_index}/{file}
-- so the first folder segment is the couple_id.

create policy "checkin_photos_read" on storage.objects
  for select to authenticated using (
    bucket_id = 'checkin-photos'
    and (storage.foldername(name))[1] = (
      select couple_id::text from public.couple_members where user_id = auth.uid()));

create policy "checkin_photos_write" on storage.objects
  for insert to authenticated with check (
    bucket_id = 'checkin-photos'
    and (storage.foldername(name))[1] = (
      select couple_id::text from public.couple_members where user_id = auth.uid()));

create policy "checkin_photos_delete" on storage.objects
  for delete to authenticated using (
    bucket_id = 'checkin-photos'
    and (storage.foldername(name))[1] = (
      select couple_id::text from public.couple_members where user_id = auth.uid()));
