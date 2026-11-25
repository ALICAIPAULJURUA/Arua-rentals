# Stage 7 — Deployment-Safe Supabase SQL Proposal

**Status:** Proposal only. No SQL executed. No production connection/modification. No hosted writes/uploads. No bucket/policy/function creation. No edits to existing manual SQL files or Flutter code.  
**Repository:** `ALICAIPAULJURUA/Arua-rentals`  
**Branch:** `main`  
**Date:** 2026-11-25

## Inputs

- [STAGE_6_SQL_DEPLOYMENT_SAFETY_REVIEW.md](c:/Users/User/Documents/PROGRAMMING%20PROJECTS/Arua-rentals/docs/supabase-audit/STAGE_6_SQL_DEPLOYMENT_SAFETY_REVIEW.md)
- [PRODUCTION_COMPATIBILITY_AUDIT.md](c:/Users/User/Documents/PROGRAMMING%20PROJECTS/Arua-rentals/PRODUCTION_COMPATIBILITY_AUDIT.md)
- Existing manual SQL: [secure_listing_image_owner_paths.sql](c:/Users/User/Documents/PROGRAMMING%20PROJECTS/Arua-rentals/supabase/manual/secure_listing_image_owner_paths.sql), [secure_listing_video_storage.sql](c:/Users/User/Documents/PROGRAMMING%20PROJECTS/Arua-rentals/supabase/manual/secure_listing_video_storage.sql), [secure_listing_insert_fields.sql](c:/Users/User/Documents/PROGRAMMING%20PROJECTS/Arua-rentals/supabase/manual/secure_listing_insert_fields.sql), [seed_listing_options.sql](c:/Users/User/Documents/PROGRAMMING%20PROJECTS/Arua-rentals/supabase/manual/seed_listing_options.sql), [super_admin_role_access.sql](c:/Users/User/Documents/PROGRAMMING%20PROJECTS/Arua-rentals/supabase/manual/super_admin_role_access.sql)
- Migration baseline: [20261118000000_initial_arua_schema.sql](c:/Users/User/Documents/PROGRAMMING%20PROJECTS/Arua-rentals/supabase/migrations/20261118000000_initial_arua_schema.sql)

## Confirmed deployed findings (user-supplied; not re-verified)

1. `public.replace_listing_images` missing in all schemas.
2. `public.update_listing_with_images` missing in all schemas.
3. `listing-videos` bucket missing.
4. `listing-images` and `avatars` buckets exist and are private.
5. Both existing buckets have NULL file-size and MIME-type restrictions.
6. Current listing image public-read policy does not verify exact object path against `listing_images.storage_path`.
7. `avatars_public_read` permits anonymous SELECT access to objects in `avatars`.
8. No separate services table; properties and services use `public.listings`.
9. Existing production RLS, Storage policies, triggers and functions inspected in earlier audit queries.

**Boundary:** Any statement not in the confirmed list above or directly observed in repo files is labeled **Repository-only assumption** or **NOT VERIFIED**.

## Executive summary

| Deliverable | Purpose | Risk | Required for listing save restore? |
|---|---|---|---|
| [proposed_stage7_listing_image_rpc_and_storage.sql](c:/Users/User/Documents/PROGRAMMING%20PROJECTS/Arua-rentals/supabase/manual/proposed_stage7_listing_image_rpc_and_storage.sql) | Create missing image RPCs; harden listing-images bucket limits/MIME; replace named storage/table policies. | **REVIEW REQUIRED** | **Yes** (RPCs) / **Yes** (public-read path fix) |
| [proposed_stage7_listing_video_storage.sql](c:/Users/User/Documents/PROGRAMMING%20PROJECTS/Arua-rentals/supabase/manual/proposed_stage7_listing_video_storage.sql) | Create private `listing-videos` bucket and narrow policies. | **REVIEW REQUIRED** | **Yes** for video uploads/playback |
| [stage7_category_area_comparison.sql](c:/Users/User/Documents/PROGRAMMING%20PROJECTS/Arua-rentals/docs/supabase-audit/stage7_category_area_comparison.sql) | Read-only comparison of deployed categories/areas vs expected slugs/names. | **SAFE** (read-only) | Diagnostic only |
| [STAGE_7_ROLLBACK_PLAN.md](c:/Users/User/Documents/PROGRAMMING%20PROJECTS/Arua-rentals/docs/supabase-audit/STAGE_7_ROLLBACK_PLAN.md) | Rollback procedures for proposed deployment scripts. | N/A | Required before apply |
| `secure_listing_insert_fields.sql` (existing, not primary) | INSERT protection trigger. | **REVIEW REQUIRED** | **No, not primary**; separate decision |
| `super_admin_role_access.sql` (existing) | Super-admin model. | **HIGH RISK / NOT REQUIRED** | **No** — do not apply |

## Task 1 — Image RPC remediation

### Proposed file
[proposed_stage7_listing_image_rpc_and_storage.sql](c:/Users/User/Documents/PROGRAMMING%20PROJECTS/Arua-rentals/supabase/manual/proposed_stage7_listing_image_rpc_and_storage.sql)

### Functions prepared

| Function | Signature | Flutter call match | Status |
|---|---|---|---|
| `public.replace_listing_images` | `(p_listing_id uuid, p_images jsonb)` | Matches `SupabaseListingsRepository._replaceImages` / `create` call: `{'p_listing_id': listingId, 'p_images': images}` | **Match** |
| `public.update_listing_with_images` | `(p_listing_id uuid, p_listing_data jsonb, p_images jsonb)` | Matches `SupabaseListingsRepository.update` call: `{'p_listing_id': listing.id, 'p_listing_data': data, 'p_images': _imageMetadata(updated)}` | **Match** |

Evidence: [supabase_listings_repository.dart](c:/Users/User/Documents/PROGRAMMING%20PROJECTS/Arua-rentals/lib/features/listings/data/supabase_listings_repository.dart) `update:263-275`, `_replaceImages:416-433`.

### Requirement assessment

| Requirement | Proposed behavior | Classification |
|---|---|---|
| Match exact Flutter arg names/types | `p_listing_id uuid, p_images jsonb` and `p_listing_id uuid, p_listing_data jsonb, p_images jsonb`. | SAFE |
| Validate authenticated ownership or authorized admin | Both require `auth.uid()`; ownership checked against `public.listings.owner_id`; admin via `private.is_app_admin()`. | SAFE |
| Validate image storage paths against listing owner and listing ID | `storage_path` regex `^<listing_owner_id>/<p_listing_id>/[^/]+$`; `listing_owner_id` read from DB listing row. | SAFE |
| Verify referenced storage objects exist in `listing-images` | `replace_listing_images` checks `storage.objects` for every non-null `storage_path` after insert; raises if missing. | SAFE |
| Validate external image URLs | Requires exactly one of `image_url`/`storage_path`; external URL must be http/https, <=2048 chars, no spaces. No domain allowlist. | REVIEW REQUIRED |
| Preserve display_order | Inserts `display_order` from input JSON; caller provides ordered metadata. No dedupe/contiguity enforcement. | REVIEW REQUIRED (minor) |
| Atomic replacement | Plpgsql function runs in caller transaction; delete+insert+existence check rollback on exception. `update_listing_with_images` updates listing then performs image replacement in same function. | SAFE |
| Secure `search_path` | `SET search_path = ''`; schema-qualified object references. | SAFE |
| Appropriate SECURITY INVOKER/DEFINER | `SECURITY INVOKER` for both RPCs so RLS/triggers remain enforced. | SAFE |
| Restrict EXECUTE grants | REVOKE ALL from public/anon; GRANT EXECUTE to authenticated. | SAFE |
| Do not weaken listing/image RLS | INVOKER means listing/listing_images RLS and triggers apply. Script adds named admin table policies but does not drop existing owner/public policies. | REVIEW REQUIRED (verify no permissive conflict) |

### Exact objects changed

| Object | Action | Notes |
|---|---|---|
| `storage.buckets` (`listing-images`) | UPDATE `file_size_limit`, `allowed_mime_types` | Only where `public=false`; guard raises otherwise. |
| schema `private` | GRANT USAGE to authenticated | Prereq for `private.is_app_admin()` calls in policies/RPCs. |
| `private.is_app_admin()` | REVOKE EXECUTE from public/anon; GRANT to authenticated | Repo migration already granted authenticated; confirm deployed definition first. |
| `public.replace_listing_images(uuid,jsonb)` | CREATE OR REPLACE | Confirmed missing in deployed. |
| `public.update_listing_with_images(uuid,jsonb,jsonb)` | CREATE OR REPLACE | Confirmed missing in deployed. |
| 9 `storage.objects` policies (listing_images_*) | DROP IF EXISTS + CREATE | See Task 2. |
| 4 `public.listing_images` admin policies | DROP IF EXISTS + CREATE | Additive named admin policies. |

### Existing objects replaced

- Confirmed missing RPCs: created, not replaced.
- Confirmed `listing-images` NULL limits: updated.
- Confirmed `listing_images_public_read` storage policy: replaced.
- Other same-name listing_images storage/table policies: replaced if present (**NOT VERIFIED** exact deployed definitions). Different-name permissive policies remain.

### Preconditions

1. `listing-images` bucket exists and is private (confirmed).
2. `private.is_app_admin()` exists and is compatible (repo assumption; verify deployed).
3. `public.listings`, `public.listing_images`, `storage.objects`, `storage.foldername` exist.
4. Export/audit all existing `storage.objects` and `public.listing_images` policies before apply.
5. Maintenance window / approval for policy replacement.

### Security assumptions

- Invoker model is correct because app uses authenticated user JWT; RLS must remain authoritative.
- `private.is_app_admin()` is trustworthy and not executable by anon/public.
- No other permissive policy grants broader listing-images access.
- External URL validation is syntactic, not content/domain reputation validation.

### Post-deployment verification queries

```sql
select id, public, file_size_limit, allowed_mime_types
from storage.buckets where id='listing-images';

select n.nspname, p.proname, pg_get_function_identity_arguments(p.oid) as args,
       p.prosecdef, p.proconfig,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') as auth_exec,
       has_function_privilege('anon', p.oid, 'EXECUTE') as anon_exec
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname in ('replace_listing_images','update_listing_with_images')
order by p.proname;

select policyname, roles, cmd, qual, with_check
from pg_policies
where schemaname='storage' and tablename='objects'
  and (policyname like 'listing_images_%' or qual ilike '%listing-images%' or coalesce(with_check,'') ilike '%listing-images%')
order by policyname;

select policyname, roles, cmd, qual, with_check
from pg_policies
where schemaname='public' and tablename='listing_images'
order by policyname;
```

## Task 2 — Image Storage policies

### Production policies supplied

Existing production policies include: `listing_images_owner_delete`, `listing_images_owner_insert`, `listing_images_owner_update`, `listing_images_public_read`.

### Proposed replacement assessment

| Production policy | Proposed action | Justification | Unnecessary replacement risk |
|---|---|---|---|
| `listing_images_public_read` | **Replace** | Confirmed deployed policy does not verify exact `listing_images.storage_path`. Proposed policy requires `li.storage_path = storage.objects.name` and approved listing. | Low; replacement required by confirmed finding. |
| `listing_images_owner_insert` | **Replace** (proposed) | Migration baseline allowed folder-owner insert without listing existence/ownership check. Proposed adds listing existence + owner match. If deployed already has equivalent checks, replacement may be unnecessary but harmless. | **REVIEW REQUIRED** — compare deployed definition before apply. |
| `listing_images_owner_update` | **Replace** (proposed) | Same rationale as insert; adds listing ownership check. | **REVIEW REQUIRED**. |
| `listing_images_owner_delete` | **Replace** (proposed) | Same rationale; adds listing ownership check. | **REVIEW REQUIRED**. |

### Exact path verification

The proposed public-read policy includes:

```sql
and exists (
  select 1
  from public.listings l
  join public.listing_images li on li.listing_id = l.id
  where l.id::text = (storage.foldername(storage.objects.name))[2]
    and l.owner_id::text = (storage.foldername(storage.objects.name))[1]
    and l.status = 'approved'
    and li.storage_path = storage.objects.name
)
```

This satisfies the confirmed requirement to verify the exact referenced `listing_images.storage_path`.

### Broader access through another policy

**Not fully verifiable from repo-only inspection.** The script drops/recreates only named policies. Any other permissive `storage.objects` policy (different name) could still grant read/write access. Pre-deployment audit must run:

```sql
select policyname, permissive, roles, cmd, qual, with_check
from pg_policies
where schemaname='storage' and tablename='objects'
order by policyname;
```

Classification: **REVIEW REQUIRED**.

## Task 3 — Video Storage policies

### Proposed file
[proposed_stage7_listing_video_storage.sql](c:/Users/User/Documents/PROGRAMMING%20PROJECTS/Arua-rentals/supabase/manual/proposed_stage7_listing_video_storage.sql)

### Requirements

| Requirement | Proposed behavior | Classification |
|---|---|---|
| Private bucket | `public=false`, on conflict forces private. | SAFE |
| 50 MiB limit | `file_size_limit=52428800`. | SAFE |
| MP4 and WebM MIME types | `video/mp4, video/webm`. Matches `ListingMediaValidator` allowed extensions/MIME signatures. | SAFE |
| Match exact Flutter upload path | App uses `<ownerId>/<listingId>/<microseconds>_<random>_0.<ext>` via `SupabaseMediaUploader._newPath` / `uploadPickedVideo`; policies check folder[1]=owner, folder[2]=listing. | SAFE |
| Restrict upload/delete to authorized owners/admins | Owner insert/update/delete require auth.uid folder match + listing owned by uid; admin variants require `private.is_app_admin()` + listing/folder match. | SAFE |
| Public reads only for videos referenced by approved listings | `listing_videos_public_read` requires approved listing and `l.video_url = storage.objects.name`. | SAFE |

### Upload-before-metadata-update sequence analysis

**Source-code finding (verified):**

1. [listing_form_screen.dart](c:/Users/User/Documents/PROGRAMMING%20PROJECTS/Arua-rentals/lib/features/listings/presentation/listing_form_screen.dart) `_save`: creates listing first if new (`repository.create`), then uploads picked images (`uploader.uploadPickedImages`), then uploads picked video (`uploader.uploadPickedVideo`) returning `UploadedListingVideo.storagePath`, then builds `completeListing` with `videoStoragePath/clearVideo`, then persists via `repository.update(completeListing)`. No signed URL is generated for the newly uploaded video before metadata update.
2. [media_uploader.dart](c:/Users/User/Documents/PROGRAMMING%20PROJECTS/Arua-rentals/lib/features/listings/data/media_uploader.dart) `uploadPickedVideo` returns storage path/upload result; it does not create signed URLs.
3. [supabase_listings_repository.dart](c:/Users/User/Documents/PROGRAMMING%20PROJECTS/Arua-rentals/lib/features/listings/data/supabase_listings_repository.dart) `_resolveListingMediaUrls` creates signed URLs only during listing read/display.

**Determination:** Current app flow can complete upload-before-metadata-update without requiring a signed URL for an unreferenced object. **No signed URL read is required by current code path.**

**Residual risk:** future UI changes, manual checks, or admin tools may need to read/preview an uploaded-but-unreferenced object. A strict `video_url = storage.objects.name` owner-read policy would block that.

**Proposed mitigation:** `listing_videos_owner_read` is narrowly scoped to authenticated owner + folder[1]=auth.uid + listing exists and owner_id=auth.uid. This allows owner to read their own listing folder objects, including newly uploaded unreferenced object, but does **not** allow public/other-user access. Admin read is similarly scoped to admin + listing folder. Public read remains strict exact-reference + approved.

**Classification:** REVIEW REQUIRED (intentional narrow owner-read tradeoff; safer than broad public read, less strict than reference-only owner read).

## Task 4 — Listing insert protection (`secure_listing_insert_fields.sql`)

**Recommendation: separate decision; do not include in primary deployment.**

### Findings

| Concern | Evidence | Assessment |
|---|---|---|
| NULL profile behavior | INSERT branch does `select p.is_verified into new.owner_verified from public.profiles p where p.id = new.owner_id;` if no profile row, `owner_verified` becomes NULL. | **REVIEW REQUIRED**. `public.listings.owner_verified` is `boolean not null default false` in migration; setting NULL would violate NOT NULL. |
| Invalid `owner_verified` assignment | If profile missing, NULL assignment can cause insert failure. | Potential availability regression for edge cases; security effect is fail-closed (insert fails), not privilege escalation. |
| Behavior change | Trigger becomes BEFORE INSERT OR UPDATE and normalizes protected fields on non-admin insert. | Acceptable for intended model but should be validated with owner/admin/service-role flows. |
| Not required for confirmed blockers | Confirmed blockers are missing RPCs, missing video bucket, image limits/path policy. | **NOT REQUIRED** in primary deployment. |

### Recommendation

- Keep [secure_listing_insert_fields.sql](c:/Users/User/Documents/PROGRAMMING%20PROJECTS/Arua-rentals/supabase/manual/secure_listing_insert_fields.sql) unchanged.
- Before any apply, patch proposal in a **new** SQL file only if approved: set `new.owner_verified := coalesce(<profile.is_verified>, false);` or raise clear exception when profile missing. Do not apply current file as-is without that decision.
- Validate with: normal landlord/provider insert, admin insert, service-role migration/import insert, and missing-profile edge case.

## Task 5 — Categories and areas

### Deliverable
Read-only comparison SQL: [stage7_category_area_comparison.sql](c:/Users/User/Documents/PROGRAMMING%20PROJECTS/Arua-rentals/docs/supabase-audit/stage7_category_area_comparison.sql)

### Assessment

| Check | Finding | Classification |
|---|---|---|
| Seed script run safety | `seed_listing_options.sql` uses `ON CONFLICT (slug) DO UPDATE` setting name/is_active/sort_order. No delete, no ID change. Rerunning overwrites curated values for matching slugs. | REVIEW REQUIRED |
| Existing FK impact | `listings.category_id` and `listings.area_id` are UUID FKs; script does not change IDs. | SAFE |
| App expected names | App resolves by `name` equality in `SupabaseListingsRepository._resolveOptionId`; seed names match app defaults in `AppConfigRepository`. | SAFE (repo assumption) |
| Overwrite risk | Matching slugs get name/is_active/sort_order overwritten. | REVIEW REQUIRED |

**Do not run seed script or overwrite existing records.** Run comparison SQL first, review missing slugs/name mismatches/extra deployed rows, then prepare targeted insert/update only if approved.

## Task 6 — Avatar access finding

**Existing confirmed finding:** `avatars_public_read` permits anonymous SELECT access to objects in the `avatars` bucket.

### Security implications

| Implication | Severity | Explanation |
|---|---|---|
| Anonymous object enumeration/read | **HIGH RISK** | Any anon/authenticated client can read objects in `avatars` bucket given object names/URLs, depending on Supabase storage behavior; policy as written allows SELECT where `bucket_id='avatars'`. |
| Privacy exposure | **HIGH RISK** | If avatars are intended to be user-private or restricted, current policy exposes them publicly. |
| Unintended content scraping | REVIEW REQUIRED | Public readable avatars can be scraped if object paths are guessable/discoverable. |
| Change risk | REVIEW REQUIRED | Tightening policy before confirming intended visibility may break profile image rendering where public avatars are expected. |

**Recommendation:** Do not change `avatars_public_read` in Stage 7. Create a separate approved decision: intended avatar visibility (public by design vs authenticated/owner-only), then propose least-privilege policy. Record as unresolved high-risk finding.

## Proposed execution order (after explicit approval)

1. Run read-only preflight: current policies/functions/bucket limits/categories/areas/avatars.
2. Apply `proposed_stage7_listing_image_rpc_and_storage.sql`.
3. Apply `proposed_stage7_listing_video_storage.sql`.
4. Run post-deploy read-only verification queries.
5. Run hosted smoke tests only with explicit approval: property create+image, service create+image+video, edit/replace/remove, playback, RLS negative checks.
6. Separately decide on `secure_listing_insert_fields.sql` (after NULL-profile patch decision), category/area targeted fixes, and avatar visibility remediation.
7. Do **not** apply `super_admin_role_access.sql`.

## Final classification summary

| Item | Classification |
|---|---|
| Image RPC creation + arg match + invoker/search_path/grants | REVIEW REQUIRED (ready for review; SAFE design intent) |
| Image public-read exact storage_path check | REVIEW REQUIRED (required fix) |
| Image owner insert/update/delete replacement | REVIEW REQUIRED (compare deployed defs first) |
| Video bucket/policies | REVIEW REQUIRED (required for confirmed missing bucket) |
| Video owner folder-read narrow scope | REVIEW REQUIRED (intentional tradeoff) |
| Listing insert trigger script | REVIEW REQUIRED / NOT PRIMARY — possible NULL-profile NOT NULL failure |
| Category/area seed overwrite | REVIEW REQUIRED — do not run blindly |
| Avatar anonymous read | HIGH RISK unresolved; no change proposed now |
| Super-admin script | HIGH RISK / NOT REQUIRED |