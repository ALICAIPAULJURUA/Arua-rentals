# Stage 7 — Rollback Plan (Proposed Scripts)

**Status:** Documentation only. Do not execute rollback SQL without explicit approval, a captured pre-deploy snapshot, and a maintenance decision.  
**Date:** 2026-11-25

This rollback plan covers the two proposed Stage 7 deployment scripts:

1. [proposed_stage7_listing_image_rpc_and_storage.sql](c:/Users/User/Documents/PROGRAMMING%20PROJECTS/Arua-rentals/supabase/manual/proposed_stage7_listing_image_rpc_and_storage.sql)
2. [proposed_stage7_listing_video_storage.sql](c:/Users/User/Documents/PROGRAMMING%20PROJECTS/Arua-rentals/supabase/manual/proposed_stage7_listing_video_storage.sql)

## Global rollback preconditions

Before applying either proposed script, capture a read-only snapshot:

```sql
-- Functions
select n.nspname, p.proname, pg_get_function_identity_arguments(p.oid) as args,
       pg_get_functiondef(p.oid) as def
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where (n.nspname='public' and p.proname in ('replace_listing_images','update_listing_with_images'))
   or (n.nspname='private' and p.proname in ('is_app_admin','protect_listing_owner_fields'));

-- Buckets
select id, name, public, file_size_limit, allowed_mime_types
from storage.buckets where id in ('listing-images','listing-videos','avatars');

-- Policies
select schemaname, tablename, policyname, permissive, roles, cmd, qual, with_check
from pg_policies
where (schemaname='storage' and tablename='objects')
   or (schemaname='public' and tablename='listing_images')
order by schemaname, tablename, policyname;

-- Grants
select has_schema_privilege('authenticated','private','USAGE') as auth_private_usage,
       has_schema_privilege('anon','private','USAGE') as anon_private_usage;
```

Store the snapshot outside production edits. Rollback should restore the **previous deployed state**, not an assumed state.

## 1. Rollback — `proposed_stage7_listing_image_rpc_and_storage.sql`

### Objects changed by script

- `storage.buckets` `listing-images` limits/MIME types.
- `private` schema USAGE grant to authenticated.
- `private.is_app_admin()` EXECUTE grants.
- `public.replace_listing_images(uuid,jsonb)` created/replaced.
- `public.update_listing_with_images(uuid,jsonb,jsonb)` created/replaced.
- Named `storage.objects` listing_images_* policies dropped/recreated.
- Named `public.listing_images` admin policies dropped/recreated.

### Rollback strategy

| Object | Rollback action | Risk / note |
|---|---|---|
| `public.replace_listing_images` | `DROP FUNCTION IF EXISTS public.replace_listing_images(uuid,jsonb);` if it did not exist before (confirmed missing). | Restores missing-function state; Flutter create-with-images and image replacement will fail again. |
| `public.update_listing_with_images` | `DROP FUNCTION IF EXISTS public.update_listing_with_images(uuid,jsonb,jsonb);` if it did not exist before (confirmed missing). | Restores missing-function state; listing edits will fail again. |
| `listing-images` bucket limits/MIME | Restore previous values from snapshot. Confirmed prior state was NULL/NULL. | Reopens previously confirmed limit gap. |
| `private.is_app_admin()` grants | Restore previous grants from snapshot. | Only if changed from pre-deploy state. |
| `private` schema usage | Restore previous grant state from snapshot. | Avoid revoking if other dependencies rely on it. |
| Named storage.objects policies | Drop policies created by script and recreate exact prior policy SQL from snapshot. | Must use prior definitions; do not guess. |
| Named public.listing_images admin policies | Drop policies created by script if they did not exist before. | Restore prior table access model. |

### Example rollback SQL (ONLY if pre-deploy snapshot confirms these were prior states)

```sql
-- DO NOT RUN WITHOUT APPROVAL / SNAPSHOT CONFIRMATION
begin;

-- Confirmed missing before Stage 7 proposal in deployed environment:
drop function if exists public.replace_listing_images(uuid, jsonb);
drop function if exists public.update_listing_with_images(uuid, jsonb, jsonb);

-- Confirmed NULL limits before Stage 7 proposal:
update storage.buckets
set file_size_limit = null,
    allowed_mime_types = null
where id = 'listing-images';

-- Recreate prior policies from snapshot here.
-- Example names only; use exact prior qual/with_check/roles/cmd from snapshot.
-- drop policy if exists listing_images_public_read on storage.objects;
-- create policy listing_images_public_read ...

commit;
```

### Post-rollback verification

```sql
select proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname in ('replace_listing_images','update_listing_with_images');

select id, public, file_size_limit, allowed_mime_types
from storage.buckets where id='listing-images';

select policyname, cmd, roles from pg_policies
where schemaname='storage' and tablename='objects'
  and policyname like 'listing_images_%'
order by policyname;
```

### Rollback impact

- **Expected regression:** listing image metadata RPC calls will fail again if functions removed.
- **Security regression:** restoring NULL bucket limits and prior public-read policy reintroduces confirmed gaps.

## 2. Rollback — `proposed_stage7_listing_video_storage.sql`

### Objects changed by script

- `storage.buckets` `listing-videos` inserted/updated.
- Named `storage.objects` listing_videos_* policies dropped/recreated.

### Rollback strategy

| Object | Rollback action | Risk / note |
|---|---|---|
| `listing-videos` bucket | If bucket did not exist before (confirmed), remove policies and delete bucket only after confirming no required objects/data remain. If objects exist, preserve bucket and disable app paths instead. | **Destructive if bucket/objects removed**. Prefer disable over delete. |
| listing_videos_* policies | Drop policies created by script. | Only meaningful if bucket retained/removed per decision. |

### Example rollback SQL (ONLY if bucket was confirmed missing and no retained objects are needed)

```sql
-- DO NOT RUN WITHOUT APPROVAL / SNAPSHOT CONFIRMATION
begin;

drop policy if exists listing_videos_public_read on storage.objects;
drop policy if exists listing_videos_owner_read on storage.objects;
drop policy if exists listing_videos_admin_read on storage.objects;
drop policy if exists listing_videos_owner_insert on storage.objects;
drop policy if exists listing_videos_admin_insert on storage.objects;
drop policy if exists listing_videos_owner_update on storage.objects;
drop policy if exists listing_videos_admin_update on storage.objects;
drop policy if exists listing_videos_owner_delete on storage.objects;
drop policy if exists listing_videos_admin_delete on storage.objects;

-- DANGEROUS: only if bucket confirmed empty/unneeded.
-- delete from storage.objects where bucket_id='listing-videos';
-- delete from storage.buckets where id='listing-videos';

commit;
```

### Preferred non-destructive rollback

If video uploads occurred after deployment, **do not delete bucket/objects** during rollback. Instead:

1. Disable video upload UI/feature flag in app (code change, separate approved task).
2. Preserve bucket and objects.
3. Revoke/adjust policies only with an approved replacement policy set.

### Post-rollback verification

```sql
select id, public, file_size_limit, allowed_mime_types
from storage.buckets where id='listing-videos';

select policyname, cmd, roles from pg_policies
where schemaname='storage' and tablename='objects'
  and policyname like 'listing_videos_%'
order by policyname;
```

### Rollback impact

- **Expected regression:** video upload/playback will fail again if bucket removed or policies revoked without replacement.
- **Data risk:** deleting bucket/objects is irreversible without backups.

## 3. Non-deployment items (no rollback script required now)

- `secure_listing_insert_fields.sql` — not in primary deployment; if separately applied, rollback by restoring prior trigger/function from snapshot.
- `seed_listing_options.sql` — not run; if ever applied, restore affected rows from pre-seed snapshot/export.
- `super_admin_role_access.sql` — **DO NOT APPLY**. Rollback would be high-risk and requires full authz snapshot.