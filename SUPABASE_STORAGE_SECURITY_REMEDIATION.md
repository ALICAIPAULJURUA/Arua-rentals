# Supabase Storage Security Remediation

> **Superseded locally by Stage 4C:** after the user requested “Fix all
> issues,” `supabase/manual/secure_listing_image_owner_paths.sql` was updated
> with stricter metadata validation and the atomic
> `update_listing_with_images` RPC. Use that SQL file and
> [SUPABASE_STORAGE_REMEDIATION_REVIEW.md](./SUPABASE_STORAGE_REMEDIATION_REVIEW.md)
> as the current local proposal. This document remains the historical Stage
> 4B record; it is not the deployment source of truth.

## Scope and status

This is a local remediation proposal for review. No production connection, SQL,
account creation, upload, or hosted write test was performed for this work.
Production status below is based only on the read-only results and findings
previously supplied for this project; those results were not independently
re-fetched in this session.

## 1. Confirmed production findings (as supplied)

- `listing-images` is a private bucket, but its `file_size_limit` and
  `allowed_mime_types` are `NULL`.
- Production Storage INSERT and UPDATE policies require the first object-path
  segment to match the authenticated UID and the second segment to identify a
  listing owned by that UID.
- Production DELETE checks both the UID path segment and listing ownership.
  This stricter production condition must be preserved; the previous local
  remediation was weaker.
- The production SELECT policy checks for an approved listing using the second
  path segment, but does not check the first segment against the listing owner
  and does not require the exact object path to appear in `listing_images`.
- `public.listing_images` has public approved-listing read and owner-only
  management policies; no administrator metadata policy was reported.
- The application has administrator listing-edit screens that use the shared
  listing form. Its repository replaces image metadata when a listing is saved.
  Under owner-only metadata policies, an administrator editing another user's
  listing can be denied while reading, replacing, or deleting its image
  metadata.

These are not a claim that the current production configuration has changed.
The production policies, bucket values, and behavior still require a fresh
read-only verification after any approved deployment.

### Root causes

- **Missing server-side limits:** the local initial migration creates the
  bucket without per-bucket size or MIME restrictions. Client-side checks alone
  cannot enforce those restrictions against direct Storage API requests.
- **Overbroad public reads:** the production read policy uses an approved
  listing-ID match, but does not bind the object path's owner segment or exact
  object name to `listing_images.storage_path`.
- **Administrator image operations denied:** metadata policies check only
  listing ownership, while the admin editor operates on listings owned by
  other users and performs metadata replacement.
- **Upload/sign ordering conflict:** signing used to happen before the exact
  Storage path was stored in `listing_images`; an exact-path SELECT policy
  necessarily rejects that ordering.

## 2. Schema and application behavior inspected locally

The initial migration defines `public.listing_images` with:

- `listing_id`, a foreign key to `public.listings(id)`;
- nullable `image_url` and `storage_path` columns, with a check requiring at
  least one source;
- `display_order`.

The generated Storage path is `<listing-owner-uid>/<listing-id>/<filename>`.
For an approved public image, the proposed policy verifies the listing,
approved status, owner path segment, listing ID path segment, and exact
`listing_images.storage_path` value.

The initial migration's `private.is_app_admin()` checks the trusted
`app_metadata.admin` JWT claim, is stable, and has an empty `search_path`. It
does not use user-editable metadata. The proposal grants only authenticated
users USAGE on `private` and EXECUTE on this boolean helper; it revokes helper
execution from `PUBLIC` and `anon`.

The Flutter upload limit was already 6 MiB, but server enforcement was missing.
The app validates JPG, PNG, and WebP declarations and formats, and sends the
matching MIME type. This is client-side validation; the bucket restriction is
the server-side enforcement. MIME declarations do not constitute deep
validation of file contents.

The upload flow previously requested a signed URL immediately after upload,
before the `listing_images.storage_path` row existed. Supabase's Flutter
`createSignedUrl` reference requires `SELECT` on `storage.objects`. A policy
requiring an exact metadata reference would therefore reject that early
request. The local code now uploads and returns the storage path first; the
listing repository persists metadata before listing retrieval signs URLs.
The form already removes only the uploaded paths if metadata persistence fails.
Repository updates no longer sign URLs as part of the save operation, avoiding
a post-persistence signing failure being mistaken for a failed metadata write.
Subsequent listing reads continue to generate fresh signed URLs.

External image URLs remain unchanged and do not use Storage policies.

### Local SQL script reconciliation

- The initial migration creates the private bucket but does not set per-bucket
  size/MIME limits. Its baseline Storage read policy is broader than the
  proposed exact-path rule. It is an already-used historical migration and is
  not edited in place; apply only a reviewed follow-up remediation.
- The previous `secure_listing_image_owner_paths.sql` version had a weaker
  owner DELETE rule, a different/broader read rule, and set `public = false`
  directly. It has been replaced locally with the proposal below, which keeps
  the bucket private by precondition and does not change unrelated bucket
  fields.
- `secure_listing_insert_fields.sql` grants authenticated USAGE on `private`
  and manages a listings trigger; it defines no Storage policies or bucket
  settings. The proposed Storage script repeats only the minimal helper grants
  required for the new authenticated administrator policies.
- `seed_listing_options.sql` only upserts category and area options; it has no
  Storage policy or bucket statements.
- No other local SQL file defines a duplicate `listing-images` policy. Other
  production policies may still exist and must be checked using the complete
  catalog query before deployment.

## 3. Proposed SQL remediation

The complete, rerunnable SQL proposal is
[secure_listing_image_owner_paths.sql](./supabase/manual/secure_listing_image_owner_paths.sql).
The executable SQL is reproduced in Appendix A. It is **not applied**. It:

1. Fails before changes if the `listing-images` bucket is missing or public.
2. Changes only that bucket's `file_size_limit` and `allowed_mime_types`, leaving
   `public` and all unrelated bucket columns untouched.
3. Replaces only the named listing-image Storage policies. It preserves the
   production owner-and-listing checks for owner DELETE and strengthens owner
   INSERT/UPDATE to check the listing relationship as well.
4. Adds separate least-privilege administrator Storage policies using
   `private.is_app_admin()` and requires the stored path's first segment to
   match the listing's actual owner.
5. Replaces the public read policy with an exact-path, approved-listing check.
   Separate authenticated owner and administrator read policies permit their
   workflows for pending/rejected listings, but still require a real listing,
   legitimate owner path, and exact metadata path.
6. Replaces listing image metadata atomically through an authenticated,
   `SECURITY INVOKER` RPC. It checks access through the caller's RLS context,
   limits image count, and validates Storage paths against the listing owner
   and ID. A failed insert rolls back the preceding delete.
7. Adds administrator SELECT/INSERT/UPDATE/DELETE policies only on
   `public.listing_images`, preserving the existing ordinary owner policy.
8. Prints read-only verification result sets after commit.

The migration does not make the bucket public, modify other buckets, weaken
owner restrictions, or remove unrelated policies. Supabase policies are
permissive by default: any other applicable permissive policy can still grant
access. Review the complete `storage.objects` policy result before applying.

### Why administrator metadata access is included

The current administrator listing form supports editing listings owned by
others and replaces image metadata as part of that workflow. Explicit admin
policies preserve that workflow. The alternative is to disable image viewing
and replacement in administrator edit mode and keep metadata owner-only. The
proposal chooses admin access because the current UI offers image editing;
this increases the impact of a compromised admin account, so the trusted
server-issued claim and the narrowly scoped table/bucket policies are
essential.

Admin uploads use the listing's actual owner as the first path segment. The
Flutter uploader checks the signed-in user's `app_metadata.admin` claim for UX,
but the Storage RLS policies remain authoritative.

## 4. Local application changes

- The uploader enforces the same 6 MiB maximum and allowed MIME formats,
  rejects unsupported MIME declarations and mismatched filename extensions,
  generates unique paths, and records the exact attempted paths for cleanup.
- An administrator may request an upload path for a different listing owner;
  non-admin clients are rejected locally. The server must still authorize it.
- The uploader no longer signs URLs before database metadata exists.
- Listing create/edit persists `storage_path` with a null `image_url`; listing
  reads resolve fresh signed URLs only after metadata is present.
- Image metadata replacement now uses the proposed atomic RPC, so a failed
  replacement cannot leave the old image rows deleted by a prior statement.
- Admin reads of non-approved listing images now attempt URL signing when the
  trusted admin claim is present; RLS must independently allow that operation.
- The hosted integration test source now stores the path rather than expecting
  the uploader to return a signed URL. The hosted suite remains gated and was
  not run.

## 5. Compatibility and risks

- **Uploads:** New uploads remain non-upsert uploads and use the exact
  `<owner>/<listing>/<generated filename>` convention. The policies allow owner
  uploads only for owned listings and administrator uploads only for valid
  listing-owner paths.
- **Image replacement/deletion:** The owner DELETE condition remains
  UID-and-listing scoped. Administrator delete is a separate rule and checks
  the trusted admin claim plus the actual owner/listing path.
- **Approved display:** Anonymous and authenticated reads require an approved
  listing and exact metadata path. `public.listing_images` must continue to
  expose approved image metadata to anonymous users; Storage policy subqueries
  remain subject to that table's RLS.
- **Private signed URLs:** Supabase requires object SELECT permission to create
  signed URLs. The new flow persists metadata before signing. Signed URLs
  remain time-limited (currently one hour); subsequent listing retrieval
  refreshes them. Existing signed URLs cannot be individually revoked by this
  change.
- **Pending/rejected images:** Only the owner and trusted administrator can
  create signed URLs for these rows. Anonymous users cannot.
- **Admin moderation:** Image metadata select/insert/update/delete and Storage
  read/write/delete are permitted to admins only through the trusted helper.
  Missing `private` schema USAGE or helper EXECUTE grants will cause failures;
  the proposal includes the minimum authenticated-only grants.
- **Persistence failure:** The UI tracks uploaded paths and deletes only those
  paths after metadata persistence fails. If the network fails after an upload
  commits but before the response arrives, the uploader also attempts cleanup
  for that exact generated path. Metadata replacement is a single transaction
  in the proposed invoker RPC; a failed replacement rolls back its delete and
  insert together.
- **MIME verification:** The app and bucket enforce declared MIME types and
  size, but do not scan bytes for malware or prove that the payload is a valid
  image. Add a trusted image-processing pipeline if that threat model is
  required.
- **Existing objects:** The stricter read policy will make any unreferenced
  object unreadable to anon and authenticated users. It does not delete such
  objects; inventory and cleanup require separate approval and a safe,
  owner-scoped procedure.
- **Legacy orphan cleanup:** If an owner can no longer read a pending object's
  metadata, the revised owner read policy will not authorize a signed URL for
  it. Existing objects without metadata may need a separately reviewed cleanup
  process.

## 6. Read-only verification queries

Run these individually in the Supabase SQL Editor only after any approved
deployment. They do not modify data or policies.

### Bucket settings

```sql
select id, name, public, file_size_limit, allowed_mime_types
from storage.buckets
where id = 'listing-images';
```

Confirms the bucket remains private and has a 6,291,456-byte limit plus the
three allowed MIME types. A missing row or `public = true` is a failure.

### All Storage object policies

```sql
select policyname, roles, cmd, qual, with_check
from pg_policies
where schemaname = 'storage'
  and tablename = 'objects'
order by policyname;
```

Confirms the deployed policy expressions and reveals other permissive policies
that might broaden access.

### Listing image metadata policies

```sql
select policyname, roles, cmd, qual, with_check
from pg_policies
where schemaname = 'public'
  and tablename = 'listing_images'
order by policyname;
```

Confirms the owner policy remains and the administrator policies are limited
to the image metadata table.

### Required admin-helper privileges

```sql
select
  has_schema_privilege('authenticated', 'private', 'USAGE')
    as authenticated_has_private_usage,
  has_function_privilege(
    'authenticated',
    'private.is_app_admin()',
    'EXECUTE'
  ) as authenticated_can_check_admin,
  has_function_privilege(
    'anon',
    'private.is_app_admin()',
    'EXECUTE'
  ) as anon_can_check_admin;
```

Expected: authenticated has schema usage and helper execution; anon does not
have helper execution.

### Atomic image RPC definition and privileges

```sql
select
  p.oid::regprocedure as function_name,
  p.prosecdef as is_security_definer,
  p.proconfig as function_settings,
  has_function_privilege('authenticated', p.oid, 'EXECUTE')
    as authenticated_can_replace_images,
  has_function_privilege('anon', p.oid, 'EXECUTE')
    as anon_can_replace_images,
  pg_get_functiondef(p.oid) as function_definition
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'replace_listing_images'
  and p.oid = 'public.replace_listing_images(uuid, jsonb)'::regprocedure;
```

Confirms the RPC definition, `SECURITY INVOKER` (`is_security_definer = false`),
empty search path, and authenticated-only EXECUTE permission.

These catalog checks confirm configuration, not effective behavior. RLS
behavior still requires local/emulator tests or explicitly approved hosted
integration tests with dedicated accounts.

## 7. Local test coverage and results

The following mocked tests were added or updated:

- uploader does not request a signed URL before metadata persistence;
- metadata replacement goes through one invoker RPC rather than separate
  delete/insert requests;
- upload path uses the listing owner's UUID for administrator edits;
- non-admin cannot request another owner's path;
- unsupported MIME declarations, mismatched extensions, and oversized images
  are rejected before Storage requests;
- exactly 6 MiB remains within the configured maximum;
- upload failure continues to report and clean up the exact attempted path;
- pending images can be signed by an administrator in repository resolution;
- repository update persists image metadata without prematurely signing it.

**Results:**

- Focused mocked tests: **15 passed** across
  `test/listing_media_uploader_test.dart` and
  `test/supabase_listings_repository_test.dart`.
- Full `flutter test`: **65 passed, 8 hosted tests skipped**. The hosted tests
  were skipped by their environment gate; no requests were sent to Supabase.
- `flutter analyze`: **exit code 1**, reporting 42 informational
  `deprecated_member_use` notices for `package:flutter/material.dart`; no
  errors or warnings were reported. These existing project-wide notices are
  unrelated to the Storage changes.
- The proposed SQL was not executed or parsed against a database. No hosted
  Storage ownership test was run.

## 8. Production changes pending approval

Nothing in this document has been applied to production. Before applying:

1. Re-run the read-only policy and bucket queries above, including the complete
   `storage.objects` policy list.
2. Confirm the trusted helper grants and the existing public
   `listing_images` SELECT policy.
3. Review the administrator image-management decision and the exact SQL file.
4. Apply the script manually only after explicit approval.
5. Re-run all read-only verification queries and later arrange dedicated,
   explicitly approved hosted tests. Do not treat mocked tests as hosted RLS
   verification.

## 9. Remaining uncertainties

- The current production policy definitions and bucket values have not been
  re-read during this task; the statements in Section 1 are from prior supplied
  inspection results.
- Other production `storage.objects` policies may widen access. Their current
  complete list must be reviewed before deployment.
- The current production grants on `private` and `private.is_app_admin()` must
  be confirmed with the verification query.
- No local Supabase database/emulator was used to parse or execute the proposed
  SQL. PostgreSQL syntax and policy behavior still need review against the
  target Supabase environment before approval.
- Hosted owner/admin image upload, signed URL refresh, and cross-owner denial
  tests remain **NOT RUN**.

## Appendix A. Complete proposed SQL

The following is the complete SQL proposal with the same executable statements
as
[secure_listing_image_owner_paths.sql](./supabase/manual/secure_listing_image_owner_paths.sql).
Review the whole script before applying it manually; it has not been executed.

```sql
-- Proposed Stage 4B remediation for manual review and explicit approval.
-- Do not apply until all production storage.objects policies have been reviewed:
-- permissive policies with other names can grant access alongside these rules.
-- This script changes only the listing-images bucket, its object policies,
-- the image replacement RPC and its privileges, and listing_images admin
-- policies.

begin;

do $$
begin
  if not exists (
    select 1
    from storage.buckets
    where id = 'listing-images'
  ) then
    raise exception 'The listing-images Storage bucket does not exist';
  end if;

  if exists (
    select 1
    from storage.buckets
    where id = 'listing-images'
      and public is distinct from false
  ) then
    raise exception 'The listing-images bucket must remain private';
  end if;
end;
$$;

update storage.buckets
set
  file_size_limit = 6291456,
  allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp']::text[]
where id = 'listing-images'
  and public is false;

grant usage on schema private to authenticated;
revoke execute on function private.is_app_admin() from public, anon;
grant execute on function private.is_app_admin() to authenticated;

create or replace function public.replace_listing_images(
  p_listing_id uuid,
  p_images jsonb
)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  listing_owner_id uuid;
begin
  if (select auth.uid()) is null then
    raise exception 'Authentication is required to replace listing images'
      using errcode = '42501';
  end if;

  select l.owner_id
  into listing_owner_id
  from public.listings l
  where l.id = p_listing_id
    and (
      l.owner_id = (select auth.uid())
      or (select private.is_app_admin())
    );

  if listing_owner_id is null then
    raise exception 'The listing is unavailable for image changes'
      using errcode = '42501';
  end if;

  if p_images is null or jsonb_typeof(p_images) is distinct from 'array' then
    raise exception 'Image metadata must be a JSON array'
      using errcode = '22023';
  end if;

  if jsonb_array_length(p_images) > 8 then
    raise exception 'A listing can have at most 8 images'
      using errcode = '22023';
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(p_images) as image(
      image_url text,
      storage_path text,
      display_order integer
    )
    where image.display_order is null
      or image.display_order < 0
      or (image.image_url is null and image.storage_path is null)
      or (
        image.storage_path is not null
        and image.storage_path !~ (
          '^'
          || listing_owner_id::text
          || '/'
          || p_listing_id::text
          || '/[^/]+$'
        )
      )
  ) then
    raise exception 'Image metadata does not match the listing owner and ID'
      using errcode = '22023';
  end if;

  delete from public.listing_images li
  where li.listing_id = p_listing_id;

  insert into public.listing_images (
    listing_id,
    image_url,
    storage_path,
    display_order
  )
  select
    p_listing_id,
    image.image_url,
    image.storage_path,
    image.display_order
  from jsonb_to_recordset(p_images) as image(
    image_url text,
    storage_path text,
    display_order integer
  );
end;
$$;

revoke all on function public.replace_listing_images(uuid, jsonb)
  from public, anon;
grant execute on function public.replace_listing_images(uuid, jsonb)
  to authenticated;

drop policy if exists listing_images_public_read on storage.objects;
create policy listing_images_public_read
  on storage.objects for select
  to anon, authenticated
  using (
    bucket_id = 'listing-images'
    and exists (
      select 1
      from public.listings l
      join public.listing_images li on li.listing_id = l.id
      where l.id::text = (storage.foldername(storage.objects.name))[2]
        and l.owner_id::text = (storage.foldername(storage.objects.name))[1]
        and l.status = 'approved'
        and li.storage_path = storage.objects.name
    )
  );

drop policy if exists listing_images_owner_read on storage.objects;
create policy listing_images_owner_read
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'listing-images'
    and (storage.foldername(storage.objects.name))[1] =
      (select auth.uid())::text
    and exists (
      select 1
      from public.listings l
      join public.listing_images li on li.listing_id = l.id
      where l.id::text = (storage.foldername(storage.objects.name))[2]
        and l.owner_id = (select auth.uid())
        and l.owner_id::text =
          (storage.foldername(storage.objects.name))[1]
        and li.storage_path = storage.objects.name
    )
  );

drop policy if exists listing_images_admin_read on storage.objects;
create policy listing_images_admin_read
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'listing-images'
    and (select private.is_app_admin())
    and exists (
      select 1
      from public.listings l
      join public.listing_images li on li.listing_id = l.id
      where l.id::text = (storage.foldername(storage.objects.name))[2]
        and l.owner_id::text = (storage.foldername(storage.objects.name))[1]
        and li.storage_path = storage.objects.name
    )
  );

drop policy if exists listing_images_owner_insert on storage.objects;
create policy listing_images_owner_insert
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'listing-images'
    and (storage.foldername(storage.objects.name))[1] =
      (select auth.uid())::text
    and exists (
      select 1
      from public.listings l
      where l.id::text = (storage.foldername(storage.objects.name))[2]
        and l.owner_id = (select auth.uid())
        and l.owner_id::text =
          (storage.foldername(storage.objects.name))[1]
    )
  );

drop policy if exists listing_images_admin_insert on storage.objects;
create policy listing_images_admin_insert
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'listing-images'
    and (select private.is_app_admin())
    and exists (
      select 1
      from public.listings l
      where l.id::text = (storage.foldername(storage.objects.name))[2]
        and l.owner_id::text =
          (storage.foldername(storage.objects.name))[1]
    )
  );

drop policy if exists listing_images_owner_update on storage.objects;
create policy listing_images_owner_update
  on storage.objects for update
  to authenticated
  using (
    bucket_id = 'listing-images'
    and (storage.foldername(storage.objects.name))[1] =
      (select auth.uid())::text
    and exists (
      select 1
      from public.listings l
      where l.id::text = (storage.foldername(storage.objects.name))[2]
        and l.owner_id = (select auth.uid())
        and l.owner_id::text =
          (storage.foldername(storage.objects.name))[1]
    )
  )
  with check (
    bucket_id = 'listing-images'
    and (storage.foldername(storage.objects.name))[1] =
      (select auth.uid())::text
    and exists (
      select 1
      from public.listings l
      where l.id::text = (storage.foldername(storage.objects.name))[2]
        and l.owner_id = (select auth.uid())
        and l.owner_id::text =
          (storage.foldername(storage.objects.name))[1]
    )
  );

drop policy if exists listing_images_admin_update on storage.objects;
create policy listing_images_admin_update
  on storage.objects for update
  to authenticated
  using (
    bucket_id = 'listing-images'
    and (select private.is_app_admin())
    and exists (
      select 1
      from public.listings l
      where l.id::text = (storage.foldername(storage.objects.name))[2]
        and l.owner_id::text =
          (storage.foldername(storage.objects.name))[1]
    )
  )
  with check (
    bucket_id = 'listing-images'
    and (select private.is_app_admin())
    and exists (
      select 1
      from public.listings l
      where l.id::text = (storage.foldername(storage.objects.name))[2]
        and l.owner_id::text =
          (storage.foldername(storage.objects.name))[1]
    )
  );

drop policy if exists listing_images_owner_delete on storage.objects;
create policy listing_images_owner_delete
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'listing-images'
    and (storage.foldername(storage.objects.name))[1] =
      (select auth.uid())::text
    and exists (
      select 1
      from public.listings l
      where l.id::text = (storage.foldername(storage.objects.name))[2]
        and l.owner_id = (select auth.uid())
        and l.owner_id::text =
          (storage.foldername(storage.objects.name))[1]
    )
  );

drop policy if exists listing_images_admin_delete on storage.objects;
create policy listing_images_admin_delete
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'listing-images'
    and (select private.is_app_admin())
    and exists (
      select 1
      from public.listings l
      where l.id::text = (storage.foldername(storage.objects.name))[2]
        and l.owner_id::text =
          (storage.foldername(storage.objects.name))[1]
    )
  );

drop policy if exists listing_images_admin_select
  on public.listing_images;
create policy listing_images_admin_select
  on public.listing_images for select
  to authenticated
  using ((select private.is_app_admin()));

drop policy if exists listing_images_admin_insert
  on public.listing_images;
create policy listing_images_admin_insert
  on public.listing_images for insert
  to authenticated
  with check ((select private.is_app_admin()));

drop policy if exists listing_images_admin_update
  on public.listing_images;
create policy listing_images_admin_update
  on public.listing_images for update
  to authenticated
  using ((select private.is_app_admin()))
  with check ((select private.is_app_admin()));

drop policy if exists listing_images_admin_delete
  on public.listing_images;
create policy listing_images_admin_delete
  on public.listing_images for delete
  to authenticated
  using ((select private.is_app_admin()));

commit;

-- Read-only verification: the bucket remains private and has the required
-- server-side limits without changing any other bucket configuration.
select id, name, public, file_size_limit, allowed_mime_types
from storage.buckets
where id = 'listing-images';

-- Include every object policy so additional permissive policies are visible.
select policyname, roles, cmd, qual, with_check
from pg_policies
where schemaname = 'storage'
  and tablename = 'objects'
order by policyname;

select policyname, roles, cmd, qual, with_check
from pg_policies
where schemaname = 'public'
  and tablename = 'listing_images'
order by policyname;

select
  has_schema_privilege('authenticated', 'private', 'USAGE')
    as authenticated_has_private_usage,
  has_function_privilege(
    'authenticated',
    'private.is_app_admin()',
    'EXECUTE'
  ) as authenticated_can_check_admin,
  has_function_privilege(
    'anon',
    'private.is_app_admin()',
    'EXECUTE'
  ) as anon_can_check_admin;

select
  p.oid::regprocedure as function_name,
  p.prosecdef as is_security_definer,
  p.proconfig as function_settings,
  has_function_privilege('authenticated', p.oid, 'EXECUTE')
    as authenticated_can_replace_images,
  has_function_privilege('anon', p.oid, 'EXECUTE')
    as anon_can_replace_images,
  pg_get_functiondef(p.oid) as function_definition
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'replace_listing_images'
  and p.oid = 'public.replace_listing_images(uuid, jsonb)'::regprocedure;
```
