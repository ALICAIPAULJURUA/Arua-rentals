-- Prepared Stage 5 storage configuration for manual review and explicit approval.
-- Do not apply to production automatically. This script only provisions the
-- private listing-videos bucket and its Storage object policies. It does not
-- change database schema, listing RPCs, or any existing image configuration.
--
-- The app stores private uploaded video storage paths in public.listings.video_url
-- using the existing path convention: <auth.uid>/<listing.id>/<generated filename>.
-- Signed URLs are generated client-side for viewing; do not make this bucket public.

begin;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'listing-videos',
  'listing-videos',
  false,
  52428800,
  array['video/mp4', 'video/webm']::text[]
)
on conflict (id) do update
set
  public = false,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists listing_videos_public_read on storage.objects;
create policy listing_videos_public_read
  on storage.objects for select
  to anon, authenticated
  using (
    bucket_id = 'listing-videos'
    and exists (
      select 1
      from public.listings l
      where l.id::text = (storage.foldername(storage.objects.name))[2]
        and l.owner_id::text = (storage.foldername(storage.objects.name))[1]
        and l.status = 'approved'
        and l.video_url = storage.objects.name
    )
  );

drop policy if exists listing_videos_owner_read on storage.objects;
create policy listing_videos_owner_read
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'listing-videos'
    and (storage.foldername(storage.objects.name))[1] =
      (select auth.uid())::text
    and exists (
      select 1
      from public.listings l
      where l.id::text = (storage.foldername(storage.objects.name))[2]
        and l.owner_id = (select auth.uid())
        and l.owner_id::text = (storage.foldername(storage.objects.name))[1]
        and l.video_url = storage.objects.name
    )
  );

drop policy if exists listing_videos_admin_read on storage.objects;
create policy listing_videos_admin_read
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'listing-videos'
    and (select private.is_app_admin())
    and exists (
      select 1
      from public.listings l
      where l.id::text = (storage.foldername(storage.objects.name))[2]
        and l.owner_id::text = (storage.foldername(storage.objects.name))[1]
        and l.video_url = storage.objects.name
    )
  );

drop policy if exists listing_videos_owner_insert on storage.objects;
create policy listing_videos_owner_insert
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'listing-videos'
    and (storage.foldername(storage.objects.name))[1] =
      (select auth.uid())::text
    and exists (
      select 1
      from public.listings l
      where l.id::text = (storage.foldername(storage.objects.name))[2]
        and l.owner_id = (select auth.uid())
        and l.owner_id::text = (storage.foldername(storage.objects.name))[1]
    )
  );

drop policy if exists listing_videos_admin_insert on storage.objects;
create policy listing_videos_admin_insert
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'listing-videos'
    and (select private.is_app_admin())
    and exists (
      select 1
      from public.listings l
      where l.id::text = (storage.foldername(storage.objects.name))[2]
        and l.owner_id::text = (storage.foldername(storage.objects.name))[1]
    )
  );

drop policy if exists listing_videos_owner_update on storage.objects;
create policy listing_videos_owner_update
  on storage.objects for update
  to authenticated
  using (
    bucket_id = 'listing-videos'
    and (storage.foldername(storage.objects.name))[1] =
      (select auth.uid())::text
    and exists (
      select 1
      from public.listings l
      where l.id::text = (storage.foldername(storage.objects.name))[2]
        and l.owner_id = (select auth.uid())
        and l.owner_id::text = (storage.foldername(storage.objects.name))[1]
    )
  )
  with check (
    bucket_id = 'listing-videos'
    and (storage.foldername(storage.objects.name))[1] =
      (select auth.uid())::text
    and exists (
      select 1
      from public.listings l
      where l.id::text = (storage.foldername(storage.objects.name))[2]
        and l.owner_id = (select auth.uid())
        and l.owner_id::text = (storage.foldername(storage.objects.name))[1]
    )
  );

drop policy if exists listing_videos_admin_update on storage.objects;
create policy listing_videos_admin_update
  on storage.objects for update
  to authenticated
  using (
    bucket_id = 'listing-videos'
    and (select private.is_app_admin())
    and exists (
      select 1
      from public.listings l
      where l.id::text = (storage.foldername(storage.objects.name))[2]
        and l.owner_id::text = (storage.foldername(storage.objects.name))[1]
    )
  )
  with check (
    bucket_id = 'listing-videos'
    and (select private.is_app_admin())
    and exists (
      select 1
      from public.listings l
      where l.id::text = (storage.foldername(storage.objects.name))[2]
        and l.owner_id::text = (storage.foldername(storage.objects.name))[1]
    )
  );

drop policy if exists listing_videos_owner_delete on storage.objects;
create policy listing_videos_owner_delete
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'listing-videos'
    and (storage.foldername(storage.objects.name))[1] =
      (select auth.uid())::text
    and exists (
      select 1
      from public.listings l
      where l.id::text = (storage.foldername(storage.objects.name))[2]
        and l.owner_id = (select auth.uid())
        and l.owner_id::text = (storage.foldername(storage.objects.name))[1]
    )
  );

drop policy if exists listing_videos_admin_delete on storage.objects;
create policy listing_videos_admin_delete
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'listing-videos'
    and (select private.is_app_admin())
    and exists (
      select 1
      from public.listings l
      where l.id::text = (storage.foldername(storage.objects.name))[2]
        and l.owner_id::text = (storage.foldername(storage.objects.name))[1]
    )
  );

commit;

-- Read-only verification after manual review/apply:
select id, name, public, file_size_limit, allowed_mime_types
from storage.buckets
where id = 'listing-videos';

select policyname, roles, cmd, qual, with_check
from pg_policies
where schemaname = 'storage'
  and tablename = 'objects'
  and policyname like 'listing_videos_%'
order by policyname;
