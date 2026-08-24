-- Jeju Connect — Storage bucket for contributed images
--
-- Path convention: media/<auth.uid()>/<uuid>.<ext>
-- The first path segment is the uploader's user id, which is what the insert
-- policy below keys off — a user can only write inside their own folder.
--
-- TRADEOFF: this bucket is public-read. Approved images are served straight
-- from the Storage CDN with no signing round-trip, which is what we want for
-- the map and article pages. The cost is that an image attached to a *pending*
-- or *rejected* submission is fetchable by anyone who knows its exact URL.
-- Paths are UUID-based so they are not enumerable, and the public.media table
-- still hides unapproved rows via RLS, so nothing surfaces in the UI. If you
-- later need pending images to be genuinely unreadable, flip `public` to false
-- here and switch the read paths to createSignedUrl().

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'media',
  'media',
  true,
  5242880, -- 5 MB
  array['image/jpeg', 'image/png', 'image/webp', 'image/avif']
)
on conflict (id) do update
set public             = excluded.public,
    file_size_limit    = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

-- Read: anyone. See the tradeoff note above.
create policy media_objects_select_public
  on storage.objects
  for select
  to anon, authenticated
  using (bucket_id = 'media');

-- Write: authenticated users, only into a folder named for their own user id.
create policy media_objects_insert_own
  on storage.objects
  for insert
  to authenticated
  with check (
    bucket_id = 'media'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy media_objects_update_own
  on storage.objects
  for update
  to authenticated
  using (
    bucket_id = 'media'
    and (storage.foldername(name))[1] = auth.uid()::text
  )
  with check (
    bucket_id = 'media'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy media_objects_delete_own
  on storage.objects
  for delete
  to authenticated
  using (
    bucket_id = 'media'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- Moderators can remove anything in the bucket (spam, illegal imagery).
create policy media_objects_delete_moderator
  on storage.objects
  for delete
  to authenticated
  using (bucket_id = 'media' and public.is_moderator());
