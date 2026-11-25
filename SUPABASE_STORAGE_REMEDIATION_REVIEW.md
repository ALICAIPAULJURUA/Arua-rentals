# Stage 4C — Independent Supabase Storage Remediation Review

## 1. Overall assessment

# READY FOR MANUAL REVIEW — NOT READY FOR PRODUCTION

Following the user's "Fix all issues" instruction, the local code and SQL
proposal now include corrections for the review findings. This does not
authorize production changes. The proposal is still **not ready for production**
until the SELECT-only production checks below are run and reviewed:

1. The complete production policy/grant state is unknown; overlapping
   permissive `storage.objects` policies could broaden access.
2. The proposed SQL has not been run against any PostgreSQL instance; its
   deployment behavior remains unverified.

No production connection or SQL was used. No account, upload, or hosted write
test was run. After the review, local code and SQL corrections were made at the
user's explicit request; the production project remains unchanged.

### Findings summary

| # | Severity | File | Lines | Vulnerability | Confidence |
|---|----------|------|-------|---------------|------------|
| 1 | 🟡 MEDIUM | Production state not available | N/A | Unseen permissive policies or grants may broaden access; SELECT-only production inventory remains required | 9/10 |
| 2 | ⚪ LOW | `supabase/manual/secure_listing_image_owner_paths.sql` | 70-160 | Pre-correction proposal accepted ambiguous image sources and arbitrary external URL strings; corrected locally with source and URL validation | 8/10 |
| 3 | ⚪ LOW | `supabase/manual/secure_listing_image_owner_paths.sql` | 70-160 | Pre-correction proposal did not verify Storage object existence; corrected locally with an RLS-scoped existence check after metadata insertion | 8/10 |
| 4 | 🟡 MEDIUM | `lib/features/listings/data/supabase_listings_repository.dart` | 248-270 | Pre-correction listing and metadata writes were separate; corrected locally through a single update RPC transaction | 9/10 |

No Critical or High issue was confirmed. Findings 2-4 are corrected in the
current local proposal. Finding 1 remains an evidence/deployment blocker, not a
claim that an overlapping policy currently exists.

### Review correction: public read bucket filter

An initial review alert alleged that `listing_images_public_read` omitted a
bucket restriction. The current SQL disproves that alert: the policy includes
`bucket_id = 'listing-images'` in its `USING` expression (current file around
line 136). No correction to that clause is required. The rest of the public
read expression also checks approved status, the first path segment against
`listings.owner_id`, the second segment against `listings.id`, and the exact
`listing_images.storage_path` for the same listing.

## 2. Confirmed security strengths

These are local-source findings, not claims about the deployed production
configuration:

- The bucket precondition fails if `listing-images` is missing or public. The
  `UPDATE` changes only that bucket's `file_size_limit` and
  `allowed_mime_types`; it does not change `public` or unrelated bucket
  columns.
- The proposed limit is exactly 6 MiB (6,291,456 bytes), and the MIME array is
  exactly `image/jpeg`, `image/png`, and `image/webp`.
- All proposed object write policies target `authenticated`, not `anon`.
  Owner INSERT, UPDATE, and DELETE require the UID path segment and a listing
  owned by that UID. The owner DELETE rule retains both the UID and listing
  ownership checks reported in production.
- Administrator Storage rules are separate from owner rules, use
  `private.is_app_admin()`, and bind the path's first segment to the listing's
  actual owner. They do not authorize a client merely because it supplies a
  different `owner_id`.
- The public read policy's `EXISTS` joins `public.listings` to
  `public.listing_images` on `listing_id`; it requires approved status and
  exact equality between the object name and that row's `storage_path`.
- Owner and administrator private reads use separate authenticated policies.
  Both require a real listing and exact metadata path; only the owner or
  trusted admin can read non-approved images.
- `private.is_app_admin()` in the original migration reads the signed JWT's
  `app_metadata.admin`, is stable, and has an empty `search_path`. It is not
  declared `SECURITY DEFINER` (so it runs with invoker privileges). The
  migration revokes its EXECUTE privilege from `PUBLIC` and `anon`; the
  proposed SQL grants it to `authenticated` and grants only that role USAGE on
  `private`. Ordinary users cannot set Supabase `app_metadata` through normal
  client profile updates.
- Both metadata and listing-update RPCs are explicitly `SECURITY INVOKER` and
  use an empty `search_path`. The combined update RPC locks and authorizes the
  listing row, applies the allowed listing fields, and invokes the metadata
  replacement in the same transaction.
- Metadata validation now enforces exactly one of URL/path, limits URLs to
  absolute HTTP(S) strings up to 2,048 characters without whitespace, caps the
  image count at eight, and validates path ownership/listing prefixes.
- The metadata RPC checks for every referenced path in
  `storage.objects` after inserting its metadata rows. The exact-path RLS read
  policies permit this check only for the owner, a trusted administrator, or
  a public read of an approved listing. If the object is absent or unreadable,
  the RPC raises and its metadata changes roll back.
- EXECUTE is revoked from `PUBLIC` and `anon`, then granted to
  `authenticated` for both RPCs. Existing table RLS and SQL grants still apply
  to the invoker.
- The code uses the new RPC for metadata replacement, no longer signs a newly
  uploaded object before its metadata exists, and continues signing paths when
  listing data is loaded. Existing external URLs are represented as
  `image_url` rows and do not use Storage signing.
- The uploader tracks the exact generated path before issuing an upload. On
  upload failure it attempts removal of only those attempted paths. The form
  removes only newly uploaded paths if metadata persistence fails, and only
  removes old paths after a successful replacement.

## 3. SQL and RPC findings

### Storage policies

The public-read policy is correctly bucket-scoped; the missing-bucket-filter
alert was a false positive. All of its listed ownership and metadata predicates
are present.

The owner policy predicates are correctly scoped to `listing-images`. The
owner DELETE condition is at least as strict as the supplied production
condition: it checks the first path segment, second path segment, and
`listings.owner_id = auth.uid()`.

The admin Storage policies allow administrators to manage images for any
listing, but only when the path's second segment matches that listing and the
first segment matches its actual owner. This is appropriate only if
administrators are approved to edit image files for every listing they
moderate. The shared administrator form currently replaces image metadata;
the chosen model is therefore consistent with that workflow. If admin image
editing is not intended, restrict the UI and remove the admin Storage
write/delete policies instead.

The script replaces named policies only. It cannot prevent another permissive
policy on `storage.objects` from granting access: PostgreSQL permissive policies
combine with OR semantics. Production must be checked for every policy on
`storage.objects`, not only the names used by this script.

### Administrator metadata policies

The four new policies allow authenticated administrators to SELECT, INSERT,
UPDATE, and DELETE rows in `public.listing_images`. The check is the trusted
helper for every operation. This grants access across all listings, which is
the minimum straightforward scope if administrators can moderate any listing.
It is not limited to a per-listing moderation assignment because no such
assignment model was found in the reviewed source.

The policies do not grant anonymous write access and do not change the existing
owner policy. Effective access still depends on the table's existing grants,
RLS status, and every overlapping policy.

### `replace_listing_images` RPC

**Strengths:** correct `public` schema; `SECURITY INVOKER`; empty search path;
authenticated-only EXECUTE; owner/admin authorization; at most eight entries;
nonnegative order; at least one non-null source; storage path anchored to the
listing owner's UUID and listing UUID; atomic delete-and-insert.

**`SECURITY INVOKER` limitation:** the function does not bypass RLS or table
privileges. Its caller needs sufficient table privileges and must satisfy
`listings` and `listing_images` RLS for both DELETE and INSERT. This is
desirable for this operation, but an absent grant or a policy that hides a
listing will make the RPC fail. It also means the proposed function does not
independently prove that a Storage object exists by bypassing Storage RLS.

**Remaining validation limitations:**

- The SQL URL check is syntactic, not a network safety check. It does not fetch
  URLs or prevent a URL that resolves to a private/internal host; no server-side
  fetching is performed by this app.
- Duplicate `display_order` values are rejected by the table's unique
  constraint and roll back the function. Contiguous ordering is not enforced;
  gaps are accepted.
- The SQL path pattern does not constrain filename characters beyond
  forbidding another slash. The app generates safe filenames, but direct RPC
  callers can use other characters. This is a hardening/data-quality issue,
  not a demonstrated authorization bypass.

**Correction status:** URL/source checks and RLS-scoped Storage object
existence validation have been added to the local SQL. The Storage existence
check intentionally follows metadata insertion inside the same transaction,
allowing the exact-path policies to authorize the query and ensuring the
metadata insertion rolls back if the object is unavailable. No
`SECURITY DEFINER` shortcut was introduced.

### Parent listing update atomicity (corrected locally)

The repository now calls `update_listing_with_images` once for both the
listing-row update and metadata replacement. The `SECURITY INVOKER` RPC locks
the current row, verifies owner/admin access, limits accepted payload columns,
checks the UPDATE row count, updates the listing, and calls the metadata RPC.
Any exception aborts the outer function statement, rolling back both listing
and metadata writes. This is a local SQL/client-flow assessment only; it is not
validated against a live database.

## 4. Flutter compatibility review

- **Metadata call:** `_replaceImages` sends `p_listing_id` and `p_images` to
  `replace_listing_images`. Storage-backed rows send a null `image_url` and
  their path; external URLs send an `image_url` and null path.
- **Edit call:** `update` now sends the listing fields and image array together
  to `update_listing_with_images`; it no longer sends an independent PATCH
  followed by a metadata RPC.
- **Signing order:** the uploader returns storage paths, not signed URLs.
  Repository listing loads resolve signed URLs after metadata is available.
  The one-hour signed URL refresh path remains in the repository.
- **Upload cleanup:** the uploader keeps exact attempted paths, including a
  request whose response may have been lost. The form's failed-save cleanup
  passes only paths returned for that save. It does not perform broad prefix
  deletion.
- **Metadata failure:** the combined update RPC rolls back both the listing
  fields and image metadata if any part fails. The form removes only paths
  newly uploaded for that attempt. Existing image metadata and old Storage
  objects remain in place.
- **Old image retention:** the form maps displayed URLs back to the original
  storage paths and retains hidden paths for images that do not have a
  displayable URL. It removes old Storage objects only after metadata update
  succeeds. No focused widget test was found that exercises the complete edit
  flow with retained, removed, and newly uploaded images; this remains a
  compatibility test gap.
- **External URLs:** their current HTTP(S) client validation and retrieval
  path remain separate from Storage signing. The RPC itself does not repeat
  that validation.
- **Admin:** client-side admin claim handling is UX only. SQL RLS/helper checks
  remain the security boundary. Pending image signing requires both the
  repository's admin claim path and corresponding deployed RLS policies.

## 5. Test evidence and limitations

Previously executed Stage 4B results, as recorded in the remediation report:

- Focused mocked tests: **15 passed**.
- Full `flutter test`: **65 passed, 8 hosted tests skipped** by the
  `RUN_SUPABASE_HOSTED_TESTS` gate.
- `flutter analyze`: **exit code 1**, 42 informational Material deprecation
  notices; no warnings or errors.

After the user authorized local fixes, targeted tests were run again:

- Focused mocked tests: **17 passed** across
  `test/listing_media_uploader_test.dart` and
  `test/supabase_listings_repository_test.dart`.
- Full `flutter test` after these corrections: **67 passed, 8 gated hosted
  tests skipped**. The `RUN_SUPABASE_SMOKE_TEST` flag was not enabled, so the
  connection smoke test returned before initializing Supabase or making a
  request.
- `flutter analyze` after these corrections: **exit code 1**, 42 informational
  `deprecated_member_use` notices for `package:flutter/material.dart`; no
  warnings or errors.
- No local database tests were run. The new SQL object-existence/RLS behavior
  is not covered by HTTP mocks.

Classification:

| Test type | Evidence |
|-----------|----------|
| Mocked local tests | 17 focused tests plus the local full Flutter suite; HTTP and Storage behavior is simulated |
| Local database tests | None; no local Supabase/Postgres instance was used |
| Hosted read-only tests | None executed; the smoke-test body returned early because `RUN_SUPABASE_SMOKE_TEST` was not enabled |
| Hosted write tests | Eight gated cases were skipped; no production writes occurred |
| Manual device tests | None reported or performed |

These tests verify client request shapes and local control flow. They do **not**
prove deployed RLS, bucket limits, RPC ACLs, cross-owner denials, or atomic
rollback against a real PostgreSQL database.

## 6. SELECT-only production verification

No results from the following checks were available to this review. Run them
manually in the Dashboard SQL Editor and share the result sets before any
deployment. Every query below is read-only.

### Bucket configuration (capture all columns and all buckets before deployment)

```sql
select *
from storage.buckets
order by id;
```

Confirms the existing `listing-images` visibility and settings and provides a
before-state for comparison. Compare all bucket rows after deployment to
confirm unrelated buckets did not change.

### Complete Storage policy inventory

```sql
select policyname, permissive, roles, cmd, qual, with_check
from pg_policies
where schemaname = 'storage'
  and tablename = 'objects'
order by policyname;
```

Review every policy, including differently named policies, for `anon`,
`authenticated`, and broad roles. Any other permissive policy can broaden
access.

### Listing table RLS status

```sql
select
  n.nspname as schema_name,
  c.relname as table_name,
  c.relrowsecurity as rls_enabled,
  c.relforcerowsecurity as rls_forced
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where (n.nspname = 'storage' and c.relname = 'objects')
   or (n.nspname = 'public' and c.relname in ('listings', 'listing_images'))
order by n.nspname, c.relname;
```

Confirms RLS enablement and FORCE status for the Storage objects table and the
two public tables used by the policy subqueries/RPC.

### Listing and metadata policies

```sql
select policyname, permissive, roles, cmd, qual, with_check
from pg_policies
where (schemaname = 'public' and tablename in ('listings', 'listing_images'))
   or (schemaname = 'storage' and tablename = 'objects')
order by schemaname, tablename, policyname;
```

Confirms the deployed USING/WITH CHECK expressions and reveals overlaps.

### Table grants

```sql
select grantee, table_schema, table_name, privilege_type, is_grantable
from information_schema.role_table_grants
where (table_schema = 'public'
       and table_name in ('listings', 'listing_images'))
   or (table_schema = 'storage' and table_name = 'objects')
order by table_schema, table_name, grantee, privilege_type;
```

Confirms table-level API privileges. These grants do not replace RLS review.

### Admin helper definition and effective role privileges

```sql
select
  p.oid::regprocedure as function_name,
  p.prosecdef as is_security_definer,
  p.provolatile as volatility,
  p.proconfig as function_settings,
  p.proacl as function_acl,
  pg_get_functiondef(p.oid) as function_definition
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'private'
  and p.proname = 'is_app_admin';
```

```sql
select
  r.rolname,
  has_schema_privilege(r.rolname, 'private', 'USAGE') as private_schema_usage,
  has_function_privilege(
    r.rolname,
    'private.is_app_admin()',
    'EXECUTE'
  ) as can_execute_admin_helper
from pg_roles r
where r.rolname in ('anon', 'authenticated', 'service_role', 'authenticator')
order by r.rolname;
```

Confirms the helper checks a trusted claim, has the expected search path and
security mode, and is not executable by unintended API roles. Review `proacl`
for `PUBLIC` grants as well.

### RPC definition and effective privileges

```sql
select
  p.oid::regprocedure as function_name,
  p.prosecdef as is_security_definer,
  p.provolatile as volatility,
  p.proconfig as function_settings,
  p.proacl as function_acl,
  pg_get_functiondef(p.oid) as function_definition
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('replace_listing_images', 'update_listing_with_images')
order by function_name;
```

```sql
select
  r.rolname,
  has_function_privilege(
    r.rolname,
    'public.replace_listing_images(uuid,jsonb)',
    'EXECUTE'
  ) as can_execute_replace_rpc,
  has_function_privilege(
    r.rolname,
    'public.update_listing_with_images(uuid,jsonb,jsonb)',
    'EXECUTE'
  ) as can_execute_update_rpc
from pg_roles r
where r.rolname in ('anon', 'authenticated', 'service_role', 'authenticator')
order by r.rolname;
```

Confirms the deployed definition, `SECURITY INVOKER`, empty search path, and
role-specific EXECUTE access. Also inspect `proacl` for `PUBLIC`.

### Function ACL entries, including PUBLIC

```sql
select
  p.oid::regprocedure as function_name,
  case when a.grantee = 0 then 'PUBLIC' else gr.rolname end as grantee,
  a.privilege_type,
  a.is_grantable
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
cross join lateral aclexplode(
  coalesce(p.proacl, acldefault('f', p.proowner))
) as a
left join pg_roles gr on gr.oid = a.grantee
where (n.nspname = 'private' and p.proname = 'is_app_admin')
   or (n.nspname = 'public' and p.proname = 'replace_listing_images')
order by function_name, grantee, a.privilege_type;
```

Shows explicit and default EXECUTE grants, including a PUBLIC grantee when
present.

## 7. Corrections and remaining work before deployment

1. The local proposal now includes the `bucket_id` predicate, atomic
   listing-plus-images update, URL/source checks, and RLS-scoped Storage object
   existence validation.
2. Before production deployment, inspect all production policies, RLS flags,
   grants, helper/RPC definitions, and bucket rows using Section 6. If any
   relevant production result differs from the proposal's assumptions, stop
   and revise the SQL.
3. Focused UI coverage for image retention/removal and cleanup after an atomic
   RPC failure remains desirable. Existing repository/uploader mocks verify
   request shape and exact-path cleanup but cannot establish database rollback.
4. Validate the complete SQL against an isolated PostgreSQL/Supabase instance
   if one is available; none was used for this review.

## 8. Deployment sequence and rollback considerations

1. **Do not deploy yet.** Resolve the blockers above and obtain the missing
   read-only production result sets.
2. Save the exact current bucket rows, complete Storage and listing-image
   policies, table grants, helper/RPC definitions, function ACLs, and RLS
   flags. Review any overlapping permissive policy.
3. Validate the corrected script and RPC in an available non-production
   database, if one exists. No new project or production writes are implied by
   this recommendation.
4. Prepare rollback SQL from the captured production state before opening the
   production SQL Editor. Do not reconstruct old policies from memory.
5. After explicit approval, apply the reviewed SQL transactionally. If any
   statement fails before COMMIT, let the transaction roll back. The script's
   read-only queries run after COMMIT, so a failed verification query after
   commit requires the prepared rollback transaction.
6. Run every Section 6 SELECT query and compare it with the saved baseline.
   Stop if any unrelated bucket or policy changed, any unexpected role has
   access, or any policy expression differs from the reviewed version.
7. Do not run hosted write tests until separately approved. When authorized,
   use dedicated accounts and unique test resources, verify exact-path cleanup,
   and report hosted results separately from mocks.
8. For rollback, restore only the exact captured prior values and definitions.
   Do not restore an unsafe broad policy by assumption. Revoke the new RPC
   grant or remove the RPC only after clients no longer call it and its
   dependencies have been checked.

## Appendix A. Superseded Stage 4B SQL snapshot

**Do not apply the SQL block in this historical appendix.** It is the original
Stage 4B version and predates the local fixes described above. The canonical,
complete current SQL (including both RPC definitions) is
[secure_listing_image_owner_paths.sql](./supabase/manual/secure_listing_image_owner_paths.sql).
That file is the only version to review for any future deployment; its
contents have not been executed.

The historical version below is retained only to make the earlier review
auditable; it is not the proposed deployment artifact.

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
