-- PROPOSED Stage 7 remediation — DO NOT APPLY WITHOUT EXPLICIT APPROVAL.
-- Purpose: provision private listing-videos bucket and narrowly scoped storage policies.
--
-- Confirmed deployed gap addressed (user-supplied, not re-verified here):
--   - listing-videos bucket does not exist.
--
-- Preconditions (verify read-only before apply):
--   1. public.listings exists with id, owner_id, status, video_url columns.
--   2. private.is_app_admin() exists and reflects intended admin semantics.
--   3. storage.foldername(text) exists.
--   4. Review existing storage.objects policies for conflicting/permissive names.
--   5. Confirm app upload path convention remains <owner_id>/<listing_id>/<filename>.
--
-- Existing production objects expected to be replaced/modified by this script:
--   - storage.buckets: insert/update listing-videos (confirmed missing; on conflict updates config).
--   - storage.objects policies named listing_videos_* below: dropped/recreated.
--
-- Security assumptions:
--   - Bucket remains private; file_size_limit 50 MiB; MIME video/mp4, video/webm.
--   - Public read is allowed only for objects whose exact name equals listings.video_url
--     for an approved listing in the matching owner/listing folder.
--   - Owner/admin insert/update/delete require matching listing ownership/folder.
--   - Owner folder-read is narrowly scoped to authenticated owner + listing they own;
--     it allows reading unreferenced objects in their own listing folder to avoid
--     upload-before-metadata-update signed URL deadlocks. It does NOT grant cross-user access.
--   - Any permissive same-table policy not named here may still grant access.
--
-- Rollback: see docs/supabase-audit/STAGE_7_ROLLBACK_PLAN.md (video script section).

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

-- Public can read only the exact video object referenced by an approved listing.
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

-- Narrow owner read: allows owner to read objects in their own listing folder,
-- including a newly uploaded object before listings.video_url metadata is updated.
-- This is limited to authenticated owner, matching folder owner, and an owned listing row.
drop policy if exists listing_videos_owner_read on storage.objects;
create policy listing_videos_owner_read
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'listing-videos'
    and (storage.foldername(storage.objects.name))[1] = (select auth.uid())::text
    and exists (
      select 1
      from public.listings l
      where l.id::text = (storage.foldername(storage.objects.name))[2]
        and l.owner_id = (select auth.uid())
        and l.owner_id::text = (storage.foldername(storage.objects.name))[1]
    )
  );

-- Narrow admin read for moderation/support; scoped to listing folder objects.
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
    )
  );

drop policy if exists listing_videos_owner_insert on storage.objects;
create policy listing_videos_owner_insert
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'listing-videos'
    and (storage.foldername(storage.objects.name))[1] = (select auth.uid())::text
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
    and (storage.foldername(storage.objects.name))[1] = (select auth.uid())::text
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
    and (storage.foldername(storage.objects.name))[1] = (select auth.uid())::text
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
    and (storage.foldername(storage.objects.name))[1] = (select auth.uid())::text
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

-- Post-deployment verification (read-only):
-- select id, public, file_size_limit, allowed_mime_types
-- from storage.buckets where id='listing-videos';
-- select policyname, roles, cmd, qual, with_check
-- from pg_policies
-- where schemaname='storage' and tablename='objects' and policyname like 'listing_videos_%'
-- order by policyname;