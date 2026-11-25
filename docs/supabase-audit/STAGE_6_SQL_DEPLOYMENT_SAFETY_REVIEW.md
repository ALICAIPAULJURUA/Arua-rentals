# Stage 6 — Supabase SQL Deployment Safety Review

**Scope:** Read-only security and deployment-safety review of manual Supabase SQL scripts.  
**Repository:** `ALICAIPAULJURUA/Arua-rentals`  
**Branch:** `main`  
**Audit date:** 2026-11-25  
**Status:** Inspection only. No SQL executed. No Supabase modified. No application code/SQL files edited. No hosted writes/uploads.

## Inputs reviewed

| Input | Type | Evidence |
|---|---|---|
| [supabase/manual/secure_listing_image_owner_paths.sql](c:/Users/User/Documents/PROGRAMMING%20PROJECTS/Arua-rentals/supabase/manual/secure_listing_image_owner_paths.sql) | Repository SQL | Full file read. |
| [supabase/manual/secure_listing_video_storage.sql](c:/Users/User/Documents/PROGRAMMING%20PROJECTS/Arua-rentals/supabase/manual/secure_listing_video_storage.sql) | Repository SQL | Full file read. |
| [supabase/manual/secure_listing_insert_fields.sql](c:/Users/User/Documents/PROGRAMMING%20PROJECTS/Arua-rentals/supabase/manual/secure_listing_insert_fields.sql) | Repository SQL | Full file read. |
| [supabase/manual/seed_listing_options.sql](c:/Users/User/Documents/PROGRAMMING%20PROJECTS/Arua-rentals/supabase/manual/seed_listing_options.sql) | Repository SQL | Full file read. |
| [supabase/manual/super_admin_role_access.sql](c:/Users/User/Documents/PROGRAMMING%20PROJECTS/Arua-rentals/supabase/manual/super_admin_role_access.sql) | Repository SQL | Full file read. |
| [supabase/migrations/20261118000000_initial_arua_schema.sql](c:/Users/User/Documents/PROGRAMMING%20PROJECTS/Arua-rentals/supabase/migrations/20261118000000_initial_arua_schema.sql) | Repository baseline migration | Targeted sections read (functions, triggers, RLS policies, buckets, storage policies). |
| [PRODUCTION_COMPATIBILITY_AUDIT.md](c:/Users/User/Documents/PROGRAMMING%20PROJECTS/Arua-rentals/PRODUCTION_COMPATIBILITY_AUDIT.md) | Prior repo audit | Used for app dependency context; deployment state in that report was not verified. |

## Confirmed deployed findings (user-supplied; not re-verified by this review)

These are treated as **confirmed deployed state** for this review:

1. `public.replace_listing_images` does not exist in any schema.
2. `public.update_listing_with_images` does not exist in any schema.
3. `listing-videos` bucket does not exist.
4. `listing-images` and `avatars` buckets exist and are private.
5. Both existing buckets have NULL file-size and MIME-type restrictions.
6. The current listing image public-read policy does not verify the exact object path against `listing_images.storage_path`.
7. The avatars public-read policy permits anonymous SELECT access to objects in the avatars bucket.
8. There is no separate services table; properties and services use `public.listings`.
9. Existing production RLS, Storage policies, triggers and functions have been inspected in earlier audit queries (details not fully included here; this review flags where that matters).

**Repository-only assumptions** below are explicitly labeled and must not be treated as deployed fact.

## 1. Executive summary

| Script | Primary purpose | Classification | Deployment relevance |
|---|---|---|---|
| `secure_listing_image_owner_paths.sql` | Create missing image RPCs, harden listing-images bucket limits/policies, add admin listing_images policies. | **REVIEW REQUIRED** | **Required** to restore image metadata save/display hardening; addresses confirmed missing RPCs and confirmed listing-images policy/limit gaps. |
| `secure_listing_video_storage.sql` | Create private `listing-videos` bucket and storage policies. | **REVIEW REQUIRED** | **Required** for video upload/playback; addresses confirmed missing bucket. |
| `secure_listing_insert_fields.sql` | Extend owner-field protection trigger to INSERT and normalize protected defaults. | **REVIEW REQUIRED** | Useful hardening; not the primary blocker for missing RPCs/video bucket but addresses insert-protection gap. |
| `seed_listing_options.sql` | Idempotent upsert of categories/areas by slug. | **REVIEW REQUIRED** | Required only if deployed categories/areas are missing/misaligned; can overwrite names/active/sort_order for matching slugs. |
| `super_admin_role_access.sql` | Introduce super-admin role/model and move categories/areas management to super-admin only. | **HIGH RISK / NOT REQUIRED** for listing submission restore | Behavior-changing security/admin model change; do not auto-apply. |

**Overall:** No script should be applied blindly. The two highest-value scripts for the confirmed submission blockers are the image RPC script and video bucket script, but both require pre-deployment checks for conflicting existing policies, prerequisite functions/privileges, and post-deployment verification. `super_admin_role_access.sql` is not required to restore property/service save/upload flows and carries regression risk.

## 2. Findings by SQL file

### 2.1 `supabase/manual/secure_listing_image_owner_paths.sql`

**Classification:** **REVIEW REQUIRED** (addresses confirmed blockers; contains broad policy replacement and privilege assumptions).

#### What it does

- Wraps changes in `begin; ... commit;`.
- Guards: raises if `listing-images` bucket missing or `public is distinct from false`.
- Updates `storage.buckets` for `listing-images`: `file_size_limit=6291456`, `allowed_mime_types=['image/jpeg','image/png','image/webp']`, only where `public is false`.
- Grants `USAGE` on schema `private` to `authenticated`; revokes/grants execute on `private.is_app_admin()` to `authenticated` only.
- Creates/replaces `public.replace_listing_images(uuid,jsonb)` — `SECURITY INVOKER`, `SET search_path = ''`.
- Creates/replaces `public.update_listing_with_images(uuid,jsonb,jsonb)` — `SECURITY INVOKER`, `SET search_path = ''`.
- Revokes all execute on both RPCs from `public, anon`; grants execute to `authenticated`.
- Drops and recreates `storage.objects` policies for `listing-images`: public/owner/admin read, owner/admin insert/update/delete (9 policies).
- Drops and recreates `public.listing_images` admin policies: select/insert/update/delete (4 policies).
- Ends with read-only verification SELECTs (after commit inside script file; these are read-only).

#### Exact objects affected

| Object type | Name | Action |
|---|---|---|
| Bucket config | `storage.buckets` row `id='listing-images'` | UPDATE limits/MIME types (conditional). |
| Schema privilege | `private` | `GRANT USAGE TO authenticated`. |
| Function privilege | `private.is_app_admin()` | REVOKE from public/anon, GRANT to authenticated. |
| Function | `public.replace_listing_images(uuid,jsonb)` | CREATE OR REPLACE. |
| Function | `public.update_listing_with_images(uuid,jsonb,jsonb)` | CREATE OR REPLACE. |
| Function privileges | both public RPCs | REVOKE ALL from public/anon, GRANT EXECUTE to authenticated. |
| Storage RLS policies | `listing_images_public_read`, `listing_images_owner_read`, `listing_images_admin_read`, `listing_images_owner_insert`, `listing_images_admin_insert`, `listing_images_owner_update`, `listing_images_admin_update`, `listing_images_owner_delete`, `listing_images_admin_delete` on `storage.objects` | DROP IF EXISTS + CREATE. |
| Table RLS policies | `listing_images_admin_select/insert/update/delete` on `public.listing_images` | DROP IF EXISTS + CREATE. |

#### Existing production objects this would replace/modify

| Existing object | Confirmed deployed? | Effect |
|---|---|---|
| `public.replace_listing_images` | **Confirmed missing** | Would be created. |
| `public.update_listing_with_images` | **Confirmed missing** | Would be created. |
| `listing-images` bucket limits | **Confirmed NULL size/MIME** | Would be set to 6 MiB and JPEG/PNG/WebP. |
| `listing_images_public_read` on `storage.objects` | **Confirmed exists and does not verify exact `listing_images.storage_path`** | Would be replaced with path-verifying policy. |
| Other `listing-images` storage policies / listing_images admin policies | **Not confirmed by user details**; repo migration defines owner insert/update/delete and owner-manage listing_images policies. | Same-name policies replaced; different-name permissive policies remain and can still grant access. |
| `private.is_app_admin()` privileges | **Not confirmed deployed**; migration defines it. | Privileges reset to authenticated-only. |

#### Security/function review

| Check | Finding | Evidence | Classification |
|---|---|---|---|
| Argument match to Flutter | **Match.** Repo calls `replace_listing_images(p_listing_id, p_images)` and `update_listing_with_images(p_listing_id, p_listing_data, p_images)`. | [supabase_listings_repository.dart](c:/Users/User/Documents/PROGRAMMING%20PROJECTS/Arua-rentals/lib/features/listings/data/supabase_listings_repository.dart) `update`/`_replaceImages`; SQL function signatures. | SAFE |
| Listing ownership validation | **Yes.** `replace_listing_images` selects listing by id and requires `owner_id = auth.uid() or private.is_app_admin()`. `update_listing_with_images` locks listing row, requires owner or admin. | SQL `replace_listing_images`, `update_listing_with_images`. | SAFE |
| Storage path validation | **Yes.** `storage_path` must match `^<listing_owner_id>/<p_listing_id>/[^/]+$`; `listing_owner_id` comes from DB listing row. | `replace_listing_images` path regex check. | SAFE |
| Prevent attaching another user's files | **Strongly mitigated.** Path must be bound to listing owner/listing id; function checks storage object exists in `listing-images`; storage policies also check folder/listing ownership. Remaining risk: any other permissive storage policies with different names. | SQL path check + object existence check; script header warning. | REVIEW REQUIRED |
| External image URLs | **Constrained.** URL allowed only when `storage_path` is null and vice versa; URL must be http/https, <=2048 chars, no spaces. Does not enforce allowlisted domains/content type. | `replace_listing_images` image validation. | REVIEW REQUIRED |
| Transactions/partial changes | **Function-internal atomicity good.** Plpgsql function runs in caller transaction; exceptions rollback function work. Script is wrapped in begin/commit. No explicit savepoints. | SQL structure. | SAFE |
| SECURITY DEFINER/INVOKER | **INVOKER** for both RPCs. Appropriate because RLS/triggers on `public.listings` and `public.listing_images` remain enforced. | `security invoker` in both functions. | SAFE |
| EXECUTE grants | **Restricted.** REVOKE ALL from public/anon, GRANT to authenticated. | SQL grant/revoke statements. | SAFE |
| search_path | **Secure.** `set search_path = ''` and objects schema-qualified. | Both function defs. | SAFE |
| display_order preservation | **Yes, by input.** Inserts `image.display_order` from JSON array; no reordering. Does not dedupe or enforce contiguous sequence. | `replace_listing_images` insert/select. | REVIEW REQUIRED (minor) |
| Prerequisite dependency | Requires `private.is_app_admin()` and schema `private`; also assumes `public.listings`, `public.listing_images`, `storage.objects`, `storage.foldername` exist. | SQL calls `private.is_app_admin()`, reads tables. | REVIEW REQUIRED |
| Policy conflict risk | Drops/recreates only named policies. Any other permissive policies on `storage.objects` or `public.listing_images` can still allow access. | Script header and drop/create pattern. | **HIGH RISK** if unknown permissive policies exist |

#### Destructive/broad/potentially unsafe statements

| Statement / pattern | Risk | Why |
|---|---|---|
| `drop policy if exists ...` for 13 policies | Broad policy replacement | Removes existing same-name policies before recreating; safe only if replacement intended. |
| `update storage.buckets ... file_size_limit/allowed_mime_types` | Config change | Fixes confirmed NULL limits; could reject previously accepted object uploads if out-of-policy objects exist/future clients differ. |
| `revoke/grant execute on private.is_app_admin()` | Privilege change | Could break other callers if they depend on different grants; migration already grants authenticated. |
| No drop of unknown permissive policies | Security gap, not destructive | Can leave unintended access open. |

### 2.2 `supabase/manual/secure_listing_video_storage.sql`

**Classification:** **REVIEW REQUIRED** (needed for confirmed missing bucket; policy model has a read-gap tradeoff).

#### What it does

- Wraps in `begin; ... commit;`.
- `INSERT INTO storage.buckets ... ON CONFLICT (id) DO UPDATE` for `listing-videos`, private, 50MB, `['video/mp4','video/webm']`.
- Drops/creates 9 `storage.objects` policies for listing-videos: public/owner/admin read, owner/admin insert/update/delete.
- Read-only verification SELECTs after commit.

#### Exact objects affected

| Object type | Name | Action |
|---|---|---|
| Bucket | `storage.buckets` `listing-videos` | INSERT or UPDATE on conflict. |
| Storage policies | `listing_videos_public_read`, `listing_videos_owner_read`, `listing_videos_admin_read`, `listing_videos_owner_insert`, `listing_videos_admin_insert`, `listing_videos_owner_update`, `listing_videos_admin_update`, `listing_videos_owner_delete`, `listing_videos_admin_delete` | DROP IF EXISTS + CREATE. |

#### Existing production objects replaced/modified

| Existing object | Confirmed deployed? | Effect |
|---|---|---|
| `listing-videos` bucket | **Confirmed missing** | Would be created. |
| `listing_videos_*` policies | Unknown/not confirmed | Same-name policies would be replaced if present. |

#### Security/storage review

| Check | Finding | Evidence | Classification |
|---|---|---|---|
| Bucket ID/privacy | `listing-videos`, `public=false`. | bucket insert. | SAFE |
| Size/MIME limits | 52428800 bytes (50 MiB), `video/mp4, video/webm`. Matches app validator. | bucket insert; [media_uploader.dart](c:/Users/User/Documents/PROGRAMMING%20PROJECTS/Arua-rentals/lib/features/listings/data/media_uploader.dart) `ListingMediaValidator`. | SAFE |
| Path convention match | Uses `(storage.foldername(name))[1]=owner_id` and `[2]=listing_id`; app uploads `<ownerId>/<listingId>/<generated>_0.<ext>`. | SQL policies; `SupabaseMediaUploader._newPath`. | SAFE |
| Public read exact object path | **Yes.** Requires approved listing and `l.video_url = storage.objects.name`. | `listing_videos_public_read`. | SAFE |
| Owner/admin read exact object path | **Yes, but strict.** Requires `l.video_url = storage.objects.name`. A newly uploaded replacement video before listing metadata update may not be readable by owner/admin through this policy until `listings.video_url` points to it. Signed URL generation by owner/admin for newly uploaded object may fail depending on client flow. | owner/admin read policies; app flow uploads then calls update RPC. | REVIEW REQUIRED |
| Approved visibility | Public read requires `l.status='approved'`. | `listing_videos_public_read`. | SAFE |
| Admin access | Uses `private.is_app_admin()` and listing ownership/folder checks. | admin policies. | REVIEW REQUIRED (depends on `private.is_app_admin()` deployed/compatible) |
| Conflict with existing production policies | No confirmed listing-videos bucket exists. If unexpected same-name/different-name policies exist, review needed. | Confirmed missing bucket. | SAFE / REVIEW REQUIRED |
| Signed URL retrieval | Works for authorized users when object is the current referenced `video_url` and policy conditions hold. Not for unreferenced uploaded objects. | policy conditions; Supabase signed URL respects storage RLS. | REVIEW REQUIRED |

#### Destructive/broad/potentially unsafe statements

| Statement | Risk | Why |
|---|---|---|
| `on conflict (id) do update ...` | Config overwrite | Would reset existing bucket config if bucket already exists in another env. |
| `drop policy if exists ...` | Policy replacement | Replaces same-name policies. |

### 2.3 `supabase/manual/secure_listing_insert_fields.sql`

**Classification:** **REVIEW REQUIRED** (good hardening; behavior change on insert).

#### What it does

- `grant usage on schema private to authenticated;`
- Replaces `private.protect_listing_owner_fields()` as `SECURITY INVOKER`, `set search_path = ''`.
- Adds `tg_op = 'INSERT'` handling: if caller not admin, forces `status='pending'`, `rejection_reason=null`, `rating_avg=0`, `rating_count=0`, `is_featured=false`, sets `owner_verified` from `public.profiles.is_verified` by `owner_id`.
- Preserves UPDATE behavior: blocks owner changes to ownership/moderation/aggregate/featured fields and non-pending status; nulls `rejection_reason` on owner update when changed.
- Drops/recreates trigger `listings_protect_owner_fields` as `BEFORE INSERT OR UPDATE`.

#### Exact objects affected

| Object type | Name | Action |
|---|---|---|
| Schema privilege | `private` | GRANT USAGE to authenticated. |
| Function | `private.protect_listing_owner_fields()` | CREATE OR REPLACE. |
| Trigger | `public.listings.listings_protect_owner_fields` | DROP IF EXISTS + CREATE (`BEFORE INSERT OR UPDATE`). |

#### Existing production objects replaced/modified

| Existing object | Repo baseline | Confirmed deployed? | Effect |
|---|---|---|---|
| `private.protect_listing_owner_fields()` | Migration defines UPDATE-only trigger/function. | Not confirmed; production inspected earlier by user. | Replaced; INSERT behavior added. |
| `listings_protect_owner_fields` trigger | Migration: BEFORE UPDATE only. | Not confirmed. | Replaced with BEFORE INSERT OR UPDATE. |

#### Review

| Check | Finding | Evidence | Classification |
|---|---|---|---|
| Extends trigger safely for updates | **Mostly yes.** Update path keeps existing owner protections. Admin bypass via `private.is_app_admin()` preserved. | function UPDATE branch. | SAFE |
| Break listing creation? | **Possible behavior change.** For non-admin inserts, it forces status/pending defaults and overwrites `owner_verified` from profile. This matches intended security model and current app owner-create behavior (app sends pending). If any trusted flow inserts non-pending/admin-like rows without admin claim, it will be normalized. | INSERT branch. | REVIEW REQUIRED |
| Admin behavior | Admin bypasses normalization/protection (`coalesce(private.is_app_admin(), false)` returns new). | function top. | SAFE |
| Owner verified lookup | Sets `owner_verified` from profile; if profile missing, `select ... into` gives no row and `owner_verified` becomes NULL. This could surprise callers but insert RLS/FK constraints may still apply. | INSERT branch. | REVIEW REQUIRED |
| Security invoker/search_path | `SECURITY INVOKER`, `SET search_path = ''` - good. | function def. | SAFE |
| Prerequisite | Needs `private.is_app_admin()`, `public.profiles.is_verified`, `public.listings` columns. | SQL body. | REVIEW REQUIRED |

#### Destructive/broad/potentially unsafe statements

| Statement | Risk | Why |
|---|---|---|
| `drop trigger if exists listings_protect_owner_fields ...` | Behavior replacement | Removes trigger before recreating; recreated immediately after. |
| INSERT normalization | Data-shape enforcement | Can change insert outcomes for non-admin callers relying on previous behavior. |

### 2.4 `supabase/manual/seed_listing_options.sql`

**Classification:** **REVIEW REQUIRED** (idempotent by slug, but overwrites matching rows).

#### What it does

- Inserts 4 categories and 11 areas.
- `ON CONFLICT (slug) DO UPDATE SET name=excluded.name, is_active=excluded.is_active, sort_order=excluded.sort_order`.

#### Exact objects affected

| Object type | Name | Action |
|---|---|---|
| Table rows | `public.categories` slugs: `rentals, plumbing, electrical, cleaning` | INSERT/UPDATE by slug conflict. |
| Table rows | `public.areas` slugs: `arua-city, arua-hill, ayivu, awindiri, ediofe, mvara, oli, odravu, pajulu, river-oli, senior-quarters` | INSERT/UPDATE by slug conflict. |

#### Existing production objects/data affected

| Object/data | Confirmed deployed? | Effect |
|---|---|---|
| `categories`/`areas` rows with same slugs | Not confirmed. | Names/is_active/sort_order overwritten to seed values. |
| Rows with different slugs | Not confirmed. | Not modified/deleted. |
| `listings.category_id` / `listings.area_id` FKs | Schema-level in migration; deployed not confirmed. | **No FK change**; IDs not changed by this script. Existing listings remain linked by UUID FK. |

#### Review

| Check | Finding | Evidence | Classification |
|---|---|---|---|
| Safe to run more than once? | **Mostly yes.** Idempotent on slug conflict; no deletes. Re-running resets name/active/sort_order for those slugs. | `ON CONFLICT (slug) DO UPDATE`. | REVIEW REQUIRED |
| Updates/overwrites existing records? | **Yes, for matching slugs.** Overwrites `name`, `is_active`, `sort_order`. Does not touch `id`. | upsert SET clause. | REVIEW REQUIRED |
| Existing listing FKs affected? | **No direct FK break.** Script does not update IDs or delete rows. | SQL only inserts/upserts by slug. | SAFE |
| App expected names match? | **Source-code compatible.** App resolves category/area by `name` equality (`_resolveOptionId` uses `.eq('name', name)`), and UI config defaults contain these names. Seed names match defaults/casing used in app. | [supabase_listings_repository.dart](c:/Users/User/Documents/PROGRAMMING%20PROJECTS/Arua-rentals/lib/features/listings/data/supabase_listings_repository.dart) `_resolveOptionId`; [app_config.dart](c:/Users/User/Documents/PROGRAMMING%20PROJECTS/Arua-rentals/lib/core/config/app_config.dart) defaults. | SAFE |
| Completeness risk | Seeds only 4 categories / 11 areas. If production has additional active categories/areas, this script leaves them but may not add missing expected ones outside this set. | values list. | REVIEW REQUIRED |

#### Destructive/broad/potentially unsafe statements

- No DELETE/TRUNCATE/DROP. Main risk is **overwriting curated names/active flags/sort order** for matching slugs.

### 2.5 `supabase/manual/super_admin_role_access.sql`

**Classification:** **HIGH RISK** and **NOT REQUIRED** for restoring listing submission workflow.

#### What it does (major changes)

- Alters `public.profiles`: adds `role_before_admin`; changes role check to include `super_admin`; adds `role_before_admin` check.
- Creates/replaces `private.is_super_admin()` (`SECURITY DEFINER`, `STABLE`, `search_path=''`), requiring JWT `app_metadata.super_admin=true`, profile role `super_admin`, active account.
- Replaces `private.is_app_admin()` to allow admin with `app_metadata.admin` or super_admin with `app_metadata.super_admin`, both requiring active profile role match.
- Replaces `private.protect_profile_fields()` with stricter super-admin/admin rules and special handling for super-admin demotion/self-provisioning.
- Replaces categories/areas admin management policies: drops `categories_admin_manage`/`areas_admin_manage`, creates `*_super_admin_manage` requiring `private.is_super_admin()`.
- Grants schema/function execute privileges; runs `notify pgrst, 'reload schema'`; includes verification SELECTs.

#### Exact objects affected

| Object type | Name | Action |
|---|---|---|
| Table/constraints | `public.profiles` (`role_before_admin`, `profiles_role_check`, `profiles_role_before_admin_check`) | ALTER/ADD/DROP/ADD constraints. |
| Functions | `private.is_super_admin()`, `private.is_app_admin()`, `private.protect_profile_fields()` | CREATE OR REPLACE. |
| Privileges | schema `private`, `is_app_admin`, `is_super_admin` | REVOKE/GRANT. |
| RLS policies | `categories_admin_manage`, `areas_admin_manage` dropped; `categories_super_admin_manage`, `areas_super_admin_manage` created | Policy replacement. |
| PostgREST | schema reload notify | Operational side effect. |

#### Existing production objects replaced/modified

| Existing object | Repo baseline | Confirmed deployed? | Risk |
|---|---|---|---|
| `private.is_app_admin()` | Migration: JWT app_metadata.admin only. | Not confirmed. | **HIGH RISK**: all policies/functions depending on admin semantics change. |
| `private.protect_profile_fields()` | Migration simpler protection. | Not confirmed. | **HIGH RISK**: profile updates/admin workflows may break. |
| `categories_admin_manage`, `areas_admin_manage` | Migration/admin-manage policies exist. | Not confirmed. | **HIGH RISK**: ordinary admins lose category/area management unless super_admin. |
| `profiles.role` constraint | Migration allows tenant/landlord/provider/admin. | Not confirmed. | **REVIEW REQUIRED**: schema migration needed consistently across app/provisioning. |

#### Regression/security risks

| Risk | Why | Classification |
|---|---|---|
| Admin lockout for categories/areas | Moves category/area management from admin to super_admin only. | **HIGH RISK** |
| Admin function semantic change | `is_app_admin()` now requires profile row active role + matching JWT claim; super_admin also accepted. Any code/provisioning assuming old behavior may fail. | **HIGH RISK** |
| Profile protection regression | `protect_profile_fields` becomes much stricter; may block legitimate admin operations or require trusted provisioning paths not yet deployed. | **HIGH RISK** |
| Super-admin demotion path | Demotion requires postgres/service_role; accidental misconfiguration could strand privileged access. | **HIGH RISK** |
| Not required for listing save | Confirmed listing blockers are missing RPCs/video bucket/policy limits; none require super-admin model change. | **NOT REQUIRED** |
| Dependency/order | Should only be considered after baseline admin functions/policies and app role model are verified compatible. | REVIEW REQUIRED |

## 3. Cross-cutting deployment findings

### 3.1 Confirmed deployed gaps mapped to scripts

| Confirmed deployed finding | Relevant script | Coverage | Classification |
|---|---|---|---|
| `public.replace_listing_images` missing | `secure_listing_image_owner_paths.sql` | Creates function + grants. | REVIEW REQUIRED |
| `public.update_listing_with_images` missing | `secure_listing_image_owner_paths.sql` | Creates function + grants. | REVIEW REQUIRED |
| `listing-videos` bucket missing | `secure_listing_video_storage.sql` | Creates bucket + policies. | REVIEW REQUIRED |
| `listing-images` and `avatars` private but NULL size/MIME | `secure_listing_image_owner_paths.sql` fixes listing-images only | **Avatars not addressed.** | REVIEW REQUIRED |
| Listing image public-read policy does not verify exact object path against `listing_images.storage_path` | `secure_listing_image_owner_paths.sql` | Replaces `listing_images_public_read` with exact `li.storage_path = storage.objects.name` check. | SAFE fix intent / REVIEW REQUIRED deployment |
| Avatars public-read policy allows anonymous SELECT | None of reviewed scripts | **Unresolved security finding.** | **HIGH RISK** (pre-existing; outside these scripts) |
| No separate services table; properties/services use `public.listings` | All listing scripts consistent | No script creates service table. | SAFE |

### 3.2 Potentially unsafe/broad SQL patterns

| File | Statement/pattern | Risk |
|---|---|---|
| `secure_listing_image_owner_paths.sql` | `DROP POLICY IF EXISTS ...` on 13 named policies; `REVOKE/GRANT` on `private.is_app_admin`; bucket limit update | Replaces access model; same-name only. |
| `secure_listing_video_storage.sql` | Bucket upsert + 9 policy drops/creates | Overwrites same-name config/policies. |
| `secure_listing_insert_fields.sql` | Replaces trigger/function | Behavior change on insert. |
| `seed_listing_options.sql` | `ON CONFLICT ... DO UPDATE` | Overwrites curated fields for matching slugs. |
| `super_admin_role_access.sql` | Constraint changes, function replacements, admin policy replacement, schema reload | Broad authz/admin model change. |

## 4. Missing prerequisites and dependencies

| Dependency | Needed by | Status |
|---|---|---|
| `private.is_app_admin()` exists and has intended semantics | image RPC script, video policies, insert trigger, super-admin script replacement | **Repo migration defines it; deployed compatibility not confirmed.** |
| `storage.foldername()` available | storage policies in image/video scripts and existing migration policies | **Repo assumption / Supabase standard; not re-verified.** |
| `public.listings`, `public.listing_images`, `public.profiles` columns as expected | all listing scripts | **Repo schema suggests yes; deployed not confirmed.** |
| `listing-images` bucket exists and private | image script guard requires it | **Confirmed exists and private.** |
| No conflicting permissive storage/listing_images policies with different names | image/video scripts | **Not confirmed; script warns.** |
| Categories/areas unique slug constraint | seed script `ON CONFLICT (slug)` | **Repo schema assumption; verify before apply.** |
| Super-admin JWT claims/profile provisioning workflow | `super_admin_role_access.sql` | **Not confirmed; HIGH RISK if missing.** |

## 5. Recommended execution order (if approved)

> No execution performed. Order below is a safety recommendation only; each step requires explicit approval, pre-checks, and post-checks.

1. **Preflight audit snapshot (read-only):** export current function defs, grants, RLS policies, bucket settings, trigger defs, categories/areas rows. Confirm no unexpected permissive policies.
2. **`secure_listing_image_owner_paths.sql`** — first for confirmed missing RPCs and listing-images limit/path-policy gap. Do not apply until conflicting policies reviewed.
3. **`secure_listing_video_storage.sql`** — after image script/prereqs confirmed; resolves confirmed missing `listing-videos` bucket.
4. **`secure_listing_insert_fields.sql`** — after confirming insert behavior acceptable for all clients/admin flows.
5. **`seed_listing_options.sql`** — only after comparing deployed categories/areas to seed slugs/names; decide whether overwriting `is_active/sort_order/name` is acceptable.
6. **`super_admin_role_access.sql`** — **separate decision track, not part of listing-save restore**. Only after full admin/super-admin provisioning, app compatibility, and rollback plan.

**Do not run:** `super_admin_role_access.sql` automatically or as part of submission-fix deployment.

## 6. Post-deployment verification queries

Run only after explicit approval and after applying the relevant script(s). All queries below are read-only.

```sql
-- Functions/grants
select n.nspname, p.proname, pg_get_function_identity_arguments(p.oid) as args,
       p.prosecdef as security_definer, p.proconfig as config,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') as auth_exec,
       has_function_privilege('anon', p.oid, 'EXECUTE') as anon_exec
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where (n.nspname='public' and p.proname in ('replace_listing_images','update_listing_with_images'))
   or (n.nspname='private' and p.proname in ('is_app_admin','is_super_admin','protect_listing_owner_fields','protect_profile_fields'))
order by n.nspname,p.proname,args;

-- Buckets
select id, public, file_size_limit, allowed_mime_types
from storage.buckets
where id in ('listing-images','listing-videos','avatars')
order by id;

-- Storage policies (look for unexpected permissive policies)
select policyname, roles, cmd, qual, with_check
from pg_policies
where schemaname='storage' and tablename='objects'
order by policyname;

-- Listing image table policies
select policyname, roles, cmd, qual, with_check
from pg_policies
where schemaname='public' and tablename='listing_images'
order by policyname;

-- Trigger/function
select tgname, pg_get_triggerdef(t.oid)
from pg_trigger t join pg_class c on c.oid=t.tgrelid
join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relname='listings' and not t.tgisinternal;

-- Seed rows
select id, name, slug, is_active, sort_order from public.categories order by sort_order, name;
select id, name, slug, is_active, sort_order from public.areas order by sort_order, name;

-- Privileges sanity
select has_schema_privilege('authenticated','private','USAGE') as auth_private_usage,
       has_schema_privilege('anon','private','USAGE') as anon_private_usage;
```

**App-level post-deploy checks (approval required before hosted writes):** authenticated landlord/provider create property with image; create service with image+video; edit listing and replace/remove media; verify signed URL playback; confirm non-owner cannot modify; confirm public/anon cannot read unapproved/private media.

## 7. Final risk classification summary

| Proposed change | File | Classification | Rationale |
|---|---|---|---|
| Create `replace_listing_images` / `update_listing_with_images` RPCs | `secure_listing_image_owner_paths.sql` | **REVIEW REQUIRED** | Fixes confirmed missing RPCs; signatures match app; invoker/search_path/grants look good; depends on `private.is_app_admin` and policy environment. |
| Harden `listing-images` bucket limits/MIME | `secure_listing_image_owner_paths.sql` | **SAFE** | Fixes confirmed NULL limits; values match app validator. |
| Replace listing-images storage policies with exact path checks | `secure_listing_image_owner_paths.sql` | **REVIEW REQUIRED** | Fixes confirmed path-verification gap; same-name replacement only; other permissive policies may remain. |
| Add listing_images admin table policies | `secure_listing_image_owner_paths.sql` | **REVIEW REQUIRED** | Useful for admin moderation; verify intended admin scope. |
| Create `listing-videos` bucket/policies | `secure_listing_video_storage.sql` | **REVIEW REQUIRED** | Fixes confirmed missing bucket; owner/admin read requires current `video_url` reference — verify signed-URL flow. |
| Extend owner-field trigger to INSERT | `secure_listing_insert_fields.sql` | **REVIEW REQUIRED** | Improves insert protection; behavior change for non-admin inserts; verify profile-missing edge case. |
| Seed categories/areas by slug upsert | `seed_listing_options.sql` | **REVIEW REQUIRED** | Idempotent by slug; overwrites name/is_active/sort_order for matching slugs. |
| Super-admin role/access model | `super_admin_role_access.sql` | **HIGH RISK / NOT REQUIRED** | Broad authz/admin regression risk; not needed for listing submission restore. |
| Avatars anonymous public-read policy | None (pre-existing confirmed finding) | **HIGH RISK** unresolved | Not addressed by reviewed scripts; requires separate approved remediation. |