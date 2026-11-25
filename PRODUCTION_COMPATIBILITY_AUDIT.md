# PRODUCTION_COMPATIBILITY_AUDIT.md

**Scope:** Read-only source-code and repository-SQL audit for Arua Rentals Flutter/Supabase listing submission flows.  
**Repository:** `ALICAIPAULJURUA/Arua-rentals`  
**Branch:** `main`  
**Audited commit/worktree:** `cb4f970` (local worktree inspected read-only; unrelated uncommitted files present and untouched)  
**Date:** 2026-11-25  
**Method:** Static inspection of Flutter/Dart source, Supabase migrations/manual SQL, and repo config. No SQL executed, no Supabase modified, no files uploaded, no records created, no hosted writes performed.

## Evidence boundary

| Type | Status |
|---|---|
| Source-code findings | **Verified from repository files** (file + function cited per finding). |
| Local migration/manual SQL findings | **Verified from repository SQL files**. |
| Deployed Supabase schema/RPC/bucket/policy/data state | **NOT VERIFIED** — no Supabase CLI/project link/MCP/read access used; no hosted inspection performed. |
| Production save-button failure reproduction | **NOT REPRODUCED**. Causes below are source-code/configuration hypotheses or deployment mismatches, not confirmed production incidents. |

## 1. Exact table and column dependencies

### 1.1 Tables used by submission/display flows

| Table | Used by | Source |
|---|---|---|
| `public.profiles` | Create reads owner profile (`full_name, phone, role, is_verified`) before insert; create also depends on role/is_verified semantics. | `lib/features/listings/data/supabase_listings_repository.dart` — `create` (reads `.from('profiles').select('full_name, phone, role, is_verified')`). |
| `public.listings` | Create inserts listing row; update/delete/status read/write listing row; all listing queries select from listings. | `supabase_listings_repository.dart` — `create`, `update`, `delete`, `setStatus`, `getById`, `_getPage`; model `Listing.fromSupabaseRow`. |
| `public.listing_images` | Image metadata persisted via RPCs; selected/read through listings relation `listing_images(...)`; signed URL resolution uses `storage_path`. | `supabase_listings_repository.dart` — `_selection`, `_replaceImages`, `_imageMetadata`, `_resolveListingMediaUrls`; `Listing.fromSupabaseRow`. |
| `public.categories` | Category name resolved to active category id on create/update; app config loads categories. | `supabase_listings_repository.dart` — `_requireOptionId/_resolveOptionId`; `app_config.dart` — `fetch`, `saveCategories`. |
| `public.areas` | Area name resolved to active area id on create/update; app config loads areas. | `supabase_listings_repository.dart` — `_requireOptionId/_resolveOptionId`; `app_config.dart` — `fetch`, `saveAreas`. |
| `storage.buckets` / `storage.objects` | Media upload/delete/signed URL generation through Supabase Storage API; policies/scripts target these. | `media_uploader.dart` — `uploadPickedImages`, `uploadPickedVideo`, `deleteImages/deleteVideo`, `_upload`; `supabase_listings_repository.dart` — `_resolveListingMediaUrls`. |

### 1.2 `public.listings` columns referenced by Flutter

| Column | Read/Write | Notes | Source |
|---|---:|---|---|
| `id` | R/W | Create can send requested id; insert selects id; queries filter by id. | `supabase_listings_repository.dart` — `create`, `getById`, `update`, `delete`; model `id`. |
| `owner_id` | R/W | Set from effective owner (current user, or admin-selected owner). | `create`, `_toSupabaseRow`. |
| `owner_name` | R/W | Taken from profile `full_name` (not trusted client name). | `create`, `_toSupabaseRow`. |
| `owner_phone` | R/W | Create prefers profile phone, falls back to submitted listing phone; update sends submitted phone. | `create`, `update`, `_toSupabaseRow`. |
| `type` | R/W | `property`/`service`. | `ListingType`, `_toSupabaseRow`, `fromSupabaseRow`. |
| `category_id` | R/W | Resolved by category name lookup in `categories`. | `create/update/_requireOptionId`, `_toSupabaseRow`. |
| `area_id` | R/W | Resolved by area name lookup in `areas`. | `create/update/_requireOptionId`, `_toSupabaseRow`. |
| `title` | R/W | Trimmed. | `_toSupabaseRow`. |
| `title_lower` | R/W | `title.trim().toLowerCase()`. | `_toSupabaseRow`. |
| `description` | R/W | Trimmed. | `_toSupabaseRow`. |
| `price_ugx` | R/W | `int`. | model + `_toSupabaseRow`. |
| `price_unit` | R/W | `month/job/hour/fixed`. | `ListingPriceUnit`, `_toSupabaseRow`. |
| `address` | R/W | Passed through (form currently keeps oldListing.address). | `_toSupabaseRow`. |
| `latitude`,`longitude` | R/W | From `geo`. | `_toSupabaseRow`, `fromSupabaseRow`. |
| `bedrooms`,`bathrooms` | R/W | Property-only in form; model allows nullable. | form `_save`, `_toSupabaseRow`. |
| `amenities` | R/W | `text[]`/list of strings. | `_toSupabaseRow`, `fromSupabaseRow`. |
| `thumbnail_url` | R/W | Set to null when first image is storage-backed or no external URL; else first external URL. | `_toSupabaseRow`. |
| `video_url` | R/W | **Stores storage path or external URL**. For uploaded videos, code writes `videoStoragePath`; for existing external video URL fallback also possible. | `_toSupabaseRow`, form save, model. |
| `status` | R/W | Create defaults pending (admin can create approved); owner update forces pending. | `create`, `update`, `_toSupabaseRow`. |
| `rejection_reason` | R/W | Admin-protected; non-admin update nulls it. | `update`, `_toSupabaseRow`. |
| `rating_avg`,`rating_count`,`is_featured`,`owner_verified` | R/W conditional | Included only when `includeProtectedFields` (admin path). | `_toSupabaseRow`. |
| `search_prefixes` | R/W | Generated client-side by `generateListingSearchKeywords`. | `create`, `update`, `_toSupabaseRow`. |
| `created_at`,`updated_at` | R/read | `created_at` removed from update payload; read for cursors/display. | `update` (`..remove('created_at')`), `fromSupabaseRow`. |

### 1.3 `public.listing_images` columns referenced

| Column | Read/Write | Source |
|---|---:|---|
| `listing_id` | W (RPC) | `replace_listing_images` RPC inserts with `p_listing_id`. Manual SQL/RPC. |
| `image_url` | R/W | Selected in `_selection`; sent as `image_url` in image metadata when no storage path. | `_selection`, `_imageMetadata`, `fromSupabaseRow`. |
| `storage_path` | R/W | Sent as `storage_path` for uploaded/storage images; used for signed URL resolution and delete decisions. | `_imageMetadata`, `_resolveListingMediaUrls`, form save. |
| `display_order` | R/W | Sent as index; read/sorted. | `_imageMetadata`, `fromSupabaseRow`. |

### 1.4 `profiles` columns referenced

| Column | Use | Source |
|---|---|---|
| `full_name` | Required owner name for create. | `create` — `select('full_name, phone, role, is_verified')`, `_requiredString`. |
| `phone` | Preferred owner phone; fallback to submitted listing phone. | `create`. |
| `role` | Non-admin create requires `landlord` or `provider`. | `create`. |
| `is_verified` | Used for owner_verified/listing metadata. | `create`. |

## 2. Exact RPC dependencies

| RPC | Args (as called) | Called by | Purpose | Repo SQL source | Initial migration present? |
|---|---|---|---|---|---|
| `replace_listing_images` | `p_listing_id: String`, `p_images: List<Map<String,dynamic>>` | `SupabaseListingsRepository._replaceImages` -> used by `create` when images exist | Replace listing image metadata atomically/with storage-path validation. | [supabase/manual/secure_listing_image_owner_paths.sql](c:/Users/User/Documents/PROGRAMMING%20PROJECTS/Arua-rentals/supabase/manual/secure_listing_image_owner_paths.sql) | **No** (not found in [20261118000000_initial_arua_schema.sql](c:/Users/User/Documents/PROGRAMMING%20PROJECTS/Arua-rentals/supabase/migrations/20261118000000_initial_arua_schema.sql)). |
| `update_listing_with_images` | `p_listing_id: String`, `p_listing_data: Map<String,dynamic>`, `p_images: List<Map<String,dynamic>>` | `SupabaseListingsRepository.update` | Update listing + replace image metadata in one RPC. | [secure_listing_image_owner_paths.sql](c:/Users/User/Documents/PROGRAMMING%20PROJECTS/Arua-rentals/supabase/manual/secure_listing_image_owner_paths.sql) | **No**. |
| `review_listing` | `p_listing_id`, `p_status`, `p_rejection_reason` | `SupabaseListingsRepository.setStatus` (admin moderation, not create/save form) | Approve/reject listing. | Initial migration defines public/private `review_listing`. | **Yes**. |

**Source-code finding:** Create path does not call `update_listing_with_images`; it inserts into `listings` and conditionally calls `replace_listing_images`. Update path always calls `update_listing_with_images` (even when only listing fields/video metadata changed?) — see flow details.

## 3. Exact Storage bucket dependencies

| Bucket | Used by | Operations | Path convention | Limits in code | Source |
|---|---|---|---|---|---|
| `listing-images` | Image upload/delete/signed URL refresh | upload via Storage REST POST to `/object/listing-images/<path>`; delete via `storage.from('listing-images').remove`; signed URLs via `createSignedUrlsResult`. | `<ownerId>/<listingId>/<microseconds>_<random>_<index>.<ext>` | 8 images/listing; 6 MiB/image; JPG/JPEG/PNG/WebP by signature+extension. | `lib/features/listings/data/media_uploader.dart` — `ListingMediaValidator`, `SupabaseMediaUploader.uploadPickedImages/deleteImages/_newPath/_upload`; `supabase_listings_repository.dart` — `_resolveListingMediaUrls`. |
| `listing-videos` | Video upload/delete/signed URL refresh | upload POST, delete remove, signed URLs. | `<ownerId>/<listingId>/<microseconds>_<random>_0.<ext>` | 50 MiB; MP4/WebM by signature+extension. MOV rejected client-side. | `media_uploader.dart` — `uploadPickedVideo/deleteVideo`; `supabase_listings_repository.dart` — `_resolveListingMediaUrls`. |

**Manual SQL expectation:** [secure_listing_image_owner_paths.sql](c:/Users/User/Documents/PROGRAMMING%20PROJECTS/Arua-rentals/supabase/manual/secure_listing_image_owner_paths.sql) requires existing private `listing-images` bucket, sets 6MiB + image MIME types, creates strict storage policies and RPCs. [secure_listing_video_storage.sql](c:/Users/User/Documents/PROGRAMMING%20PROJECTS/Arua-rentals/supabase/manual/secure_listing_video_storage.sql) creates private `listing-videos` with 50MB mp4/webm and policies. Initial migration creates `listing-images` and `avatars` only; no `listing-videos`.

## 4. Property submission flow

**Source:** `lib/features/listings/presentation/listing_form_screen.dart` — `_save(bool isAdmin)`, `_pickImages`, `_pickVideo`; `SupabaseListingsRepository.create/update`; `SupabaseMediaUploader`.

1. **Form validation**: `_formKey.currentState!.validate()`; phone normalized with `normalizeUgandanPhone`; invalid phone shows SnackBar and returns. `_save`.
2. **Image URL normalization**: `uploader.uploadImages(...)` validates/normalizes external image URL lines (no network upload; URL validation only). `_save`.
3. **Build draft listing**: computes retained external/storage image refs from old listing, enforces max 8 total including selected images. Builds `Listing` with `status: ListingStatus.pending`, `ratingAvg/Count` preserved from old or 0, `ownerVerified/isFeatured` preserved from old or false, `video_url/videoStoragePath` carried from old listing. `_save`.
4. **Create-before-media-upload**: if not editing (`!_isEditing`), calls `repository.create(workingListing, ownerId: isAdmin ? _ownerIdController.text.trim() : null)`. On success stores `_currentListing`. This ensures listing ID exists before picked media upload paths are generated. `_save`.
5. **Picked image upload**: uploads selected picked images via `uploader.uploadPickedImages(..., listingId: workingListing.id, ownerId: workingListing.ownerId)`. Progress tracked per image. `_save`.
6. **Picked video upload**: if selected video, sets cancel token/progress, uploads via `uploadPickedVideo`. `_save`.
7. **Compose final listing**: merges uploaded image storage paths (`imageUrls` empty string, `imageStoragePaths` set), sets `videoStoragePath`/`clearVideo` as needed. `_save`.
8. **Persist metadata**: computes `needsUpdate = oldListing != null || hasNewMedia`; if needed calls `repository.update(completeListing)`. On update failure, attempts cleanup of newly uploaded images/video and rethrows. `_save`.
9. **Cleanup replaced old media**: best-effort delete removed old image paths and replaced old video path; warnings shown but save considered successful. `_save`.
10. **Success UX**: SnackBar `ListingCopy.updated/created`, `context.pop(true)`. Errors: `AppException` and `FormatException` shown; generic catch shows connection/save message. `_save`.

**Property-specific fields:** bedrooms/bathrooms parsed only when `_type == ListingType.property` (`_save`); UI shows bedrooms/bathrooms inputs conditionally. Category/area/type/priceUnit selected from config.

## 5. Service submission flow

**Source-code finding (verified):** No separate service form/model/repository. `ListingType` includes `service` (`listing.dart` — `enum ListingType { property, service }`). `ListingFormScreen` handles both types (`_type`, type selector, same `_save`). `SupabaseListingsRepository` writes same `public.listings` table and same RPCs. No `lib/**service*form*`/`*service*repository*` submission path found by inspection.

| Aspect | Service behavior | Source |
|---|---|---|
| Table | `public.listings` (same as property) | `SupabaseListingsRepository.create/update/_selection`. |
| Payload type | `type='service'` | `_toSupabaseRow`, `ListingType.service`. |
| Price units | form allows month/job/hour/fixed as selected; DB check allows same set for all listing types. | `_toSupabaseRow`; migration listings check `price_unit in ('month','job','hour','fixed')`. |
| Property-only fields | bedrooms/bathrooms null for service. | form `_save` sets null when not property. |
| Media flow | identical to property. | form `_save`, media uploader, repo. |

## 6. Image upload and metadata flow

1. **Selection/validation (client):** picker allows jpg/jpeg/png/webp; `ListingMediaValidator.imageFormat` checks size <= 6MiB, detects signature, and enforces extension/signature match. Max 8 total. `listing_form_screen.dart` — `_pickImages`; `media_uploader.dart` — `ListingMediaValidator.imageFormat/maxImages/maxImageBytes`.
2. **Upload target/auth:** `SupabaseMediaUploader._requireUploadTarget` requires signed-in user, valid UUID listingId, ownerId matching user or admin app_metadata, valid session/access token, apikey header. `media_uploader.dart`.
3. **Upload:** direct Storage REST POST to `.../object/listing-images/<owner>/<listing>/<generated>.<ext>` with `Authorization: Bearer <access token>`, `apikey`, `x-upsert:false`, `Cache-Control:max-age=3600`. Progress callback reported. `media_uploader.dart` — `_upload`.
4. **Upload failure cleanup:** on Dio/storage failure, attempts `storage.from(bucket).remove(uploadedPaths)`; failure throws `AppException`. `media_uploader.dart` — `uploadPickedImages`, `_cleanupAfterFailure`.
5. **Metadata persistence:**
   - Create: after insert, `_replaceImages` called only when image metadata non-empty; RPC `replace_listing_images(p_listing_id, p_images)`. On failure, create best-effort deletes inserted listing row and rethrows. `supabase_listings_repository.dart` — `create`, `_replaceImages`, `_imageMetadata`.
   - Edit/save needing update: `update_listing_with_images` RPC receives `p_listing_data` and `p_images`. `update`.
6. **Metadata shape:** each image `{image_url: null|string, storage_path: null|string, display_order: index}`. Storage-backed image gets `image_url=null`, `storage_path=<path>`. External URL gets `image_url=url`, `storage_path=null`. `_imageMetadata`.
7. **Retrieval/display:** `getById/_getPage` select `listing_images(image_url, storage_path, display_order)`. `_resolveListingMediaUrls` batches `createSignedUrlsResult` from `listing-images` for readable storage paths, sets `image_url` to signed URL in-memory, leaves `video_url`/image access null when user not allowed. Detail screen renders `listing.imageUrls`. `supabase_listings_repository.dart`, `listing_detail_screen.dart`.

## 7. Video upload and metadata flow

1. **Selection/validation:** picker allows mp4/webm; validator checks <=50MiB, detects MP4 ftyp/WebM EBML signature, rejects MOV and extension mismatch. `listing_form_screen.dart` — `_pickVideo`; `media_uploader.dart` — `ListingMediaValidator.videoFormat`.
2. **Upload:** after listing exists, `uploadPickedVideo` uploads to `listing-videos` with same auth/path rules; supports cancel token and progress. `media_uploader.dart`.
3. **Persistence:** no separate `listing_videos` table. Video stored as listing `video_url` column containing storage path (or cleared). Form sets `videoStoragePath`/`clearVideo`, then persists through `repository.update(completeListing)` which calls `update_listing_with_images`. `_toSupabaseRow` writes `'video_url': listing.videoStoragePath ?? listing.videoUrl`. `listing_form_screen.dart` — `_save`; `supabase_listings_repository.dart` — `_toSupabaseRow`, `update`.
4. **Replacement/removal:** removing/replacing existing video sets flags; after successful metadata save, old video storage object deleted best-effort with warning. `_save`.
5. **Retrieval/playback:** `_resolveListingMediaUrls` detects 3-part UUID/UUID/filename path in `video_url`, moves it to `video_storage_path`, resolves signed URL from `listing-videos`, sets `video_url` to signed URL for display. Detail screen renders `ListingVideoPlayer` when `videoUrl` non-empty. `supabase_listings_repository.dart` — `_isListingVideoPath`, `_resolveListingMediaUrls`; `listing_detail_screen.dart`; `listing_video_player.dart`.

## 8. Potential RLS failures (source-code/configuration analysis; NOT VERIFIED in production)

| Potential failure | Why it can fail | Evidence |
|---|---|---|
| Listing insert denied | Owner insert RLS requires `owner_id = auth.uid()`, `status='pending'`, profile role `landlord/provider`. Tenant/missing profile/role mismatch will fail. | Migration `listings_owner_insert`; repo `create` checks profile role before insert but DB still enforces. |
| Category/area FK/lookup failure | Repo resolves active category/area IDs by name; missing/inactive seed rows cause `FormatException`/AppException before or during insert. | `supabase_listings_repository.dart` — `_resolveOptionId/_requireOptionId`; seed script exists separately. |
| Image/video storage upload denied | Storage policies require auth, matching owner folder, and listing ownership checks; missing bucket/policies will fail. | `media_uploader.dart` upload path; initial migration listing-images policies weaker/different than manual; video bucket absent from initial migration. |
| Metadata RPC denied/missing | `replace_listing_images` / `update_listing_with_images` are SECURITY INVOKER; if not deployed or privileges/policies wrong, create/update fails. | Repo calls RPCs; manual SQL defines them; migration lacks them. |
| Signed URL/readback denied | Detail/owner/admin reads require appropriate listing read RLS and storage select policies for private objects. | `_resolveListingMediaUrls` checks canReadStorageImages; storage policies in manual scripts. |
| Protected-field trigger rejection | Owner updates cannot change ownership/moderation/aggregate/featured fields; insert trigger behavior differs between migration and secure_listing_insert_fields. | migration `protect_listing_owner_fields` (UPDATE only); [secure_listing_insert_fields.sql](c:/Users/User/Documents/PROGRAMMING%20PROJECTS/Arua-rentals/supabase/manual/secure_listing_insert_fields.sql) adds INSERT handling. |

## 9. Missing database objects (repo-expected vs initial migration; deployment NOT VERIFIED)

| Object | Expected by app/manual | Present in initial migration? | Risk |
|---|---|---:|---|
| `public.replace_listing_images(uuid,jsonb)` | Yes | No | **High** - create with storage images / metadata replacement fails. |
| `public.update_listing_with_images(uuid,jsonb,jsonb)` | Yes | No | **High** - any update persisted through repo.update fails. |
| `storage.buckets` row `listing-videos` | Yes | No | **High** for video uploads. |
| listing-videos storage.objects policies | Yes | No | **High** for video upload/read/delete. |
| Stricter listing-images bucket limits/policies/RPC coupling | Yes (manual) | Partial/weaker | **Medium/High** depending on deployed state. |
| `protect_listing_owner_fields` INSERT handling | Yes (manual) | No, UPDATE-only in migration | **Medium** - insert defaults/protected-field enforcement may differ. |
| Seeded categories/areas expected by UI names | Yes | No seed rows in migration | **High** for create/edit if empty. |
| `public.review_listing` | Yes (admin moderation) | Yes | Low for submission flow. |

## 10. Mismatches between local migrations and deployed requirements

| Mismatch | Local migration/manual state | App expectation | Impact |
|---|---|---|---|
| Image metadata RPCs absent in migration | Only in `secure_listing_image_owner_paths.sql` | Repo.create calls `replace_listing_images`; repo.update calls `update_listing_with_images`. | Create/update can fail with missing function/config error. |
| Video bucket absent in migration | Only in `secure_listing_video_storage.sql` | Uploader uploads to `listing-videos`; repo resolves signed URLs from it. | Video upload/display fails if not provisioned. |
| Listing-images policies differ | Migration has simpler folder/approved checks; manual script has stricter object-reference checks + admin policies + bucket limits. | Uploader and signed URL access assume private bucket and listing ownership/reference semantics. | Access denied or overly permissive behavior depending on which applied. |
| Insert trigger differs | Migration `protect_listing_owner_fields` BEFORE UPDATE only; manual script adds BEFORE INSERT OR UPDATE and defaults. | App/RLS expects pending/default-protected inserts. | Protected fields/defaults may be inconsistently enforced on insert if manual script not applied. |
| Categories/areas not seeded in migration | Seed file is manual. | `AppConfigRepository` falls back to defaults only when DB returns empty rows; repo requires selected active names resolve to IDs. | Save blocked if categories/areas missing/misnamed/inactive. |
| `super_admin_role_access.sql` changes admin semantics | Manual, behavior-changing. | Current app has admin/super-admin aware logic in places; applying script changes categories/areas management and role checks. | Potential admin/config regressions if applied without review. |

## 11. Likely causes of Save button failures

**Not reproduced in production.** Ranked by likelihood from source/config inspection:

1. **Missing deployed RPCs (`replace_listing_images`, `update_listing_with_images`) — High.** App create uses `replace_listing_images`; update uses `update_listing_with_images`. Initial migration does not define them. Missing RPC yields PostgREST/Postgres function-missing error; repo now maps to config message. Sources: `supabase_listings_repository.dart` — `create/_replaceImages/update/_mapDatabaseError`; `secure_listing_image_owner_paths.sql`; migration grep.
2. **Missing/inactive categories or areas seed data — High.** Create/update resolves selected category/area name to active ID and throws if unavailable. Sources: `_requireOptionId/_resolveOptionId`; `app_config.dart`; `seed_listing_options.sql`.
3. **Profile/role/phone constraints — Medium/High.** Non-admin create requires profile role landlord/provider and owner name; missing profile/role/phone can block save. Recent fix falls back to submitted listing phone, but profile must still exist and role must be allowed. Sources: `create`.
4. **Storage bucket/policy missing or mismatched (`listing-images`, `listing-videos`) — Medium/High for media saves.** Uploads use private buckets and signed URLs. Video bucket absent from initial migration; image policies differ. Sources: `media_uploader.dart`; manual storage SQLs; migration.
5. **RLS/trigger rejection on insert/update — Medium.** Owner insert must be pending + landlord/provider; owner update forced pending and protected-field trigger may reject payload. Deployment-specific. Sources: migration RLS/trigger; `secure_listing_insert_fields.sql`; repo `_toSupabaseRow`.
6. **Generic client/network/storage failures surfaced as generic message — Medium UX cause.** Form catches generic exceptions and shows "Unable to save..." which can mask root cause in UI; actual exception not logged to remote telemetry here. Source: `listing_form_screen.dart` — `_save` catch blocks.
7. **Video metadata path dependence on `listings.video_url` overloading — Low/Medium.** Code stores storage path in `video_url` and infers by path pattern; this matches current schema but is brittle if external URL/path conventions change. Source: `_toSupabaseRow`, `_resolveListingMediaUrls`, `_isListingVideoPath`.

## 12. Prioritized corrective-action plan

| Priority | Action | Why | Verification | Approval |
|---:|---|---|---|---|
| P0 | **Read-only deployed audit**: confirm RPCs, buckets, policies, triggers, seed data in target Supabase. | Deployment state is NOT VERIFIED; highest-risk missing objects are RPCs/bucket/seeds. | Run [docs/supabase-audit/](c:/Users/User/Documents/PROGRAMMING%20PROJECTS/Arua-rentals/docs/supabase-audit/) scripts in SQL Editor; capture all result sets. | No production change; safe. |
| P0 | **Apply/review `secure_listing_image_owner_paths.sql`** in controlled env after audit. | Provides required RPCs and hardened image storage/policies. | Script verification queries + app create/update with image metadata. | **Explicit approval required before production apply**. |
| P0 | **Apply/review `secure_listing_video_storage.sql`** after audit. | Creates missing `listing-videos` bucket/policies. | Bucket/policy verification + video upload/playback test. | **Explicit approval required**. |
| P1 | **Apply/review `secure_listing_insert_fields.sql`**. | Adds INSERT handling to owner-field protection trigger. | Trigger definition check + insert behavior test. | **Explicit approval required**. |
| P1 | **Apply/review `seed_listing_options.sql`** if categories/areas missing/misaligned. | Prevents category/area resolution failures. | Category/area select + create form options + save. | **Explicit approval required** (idempotent but production data). |
| P1 | **Hosted end-to-end verification** for property and service create/edit with image+video. | Confirms real RLS/storage/RPC behavior. | Authenticated landlord/provider tests; capture pass/fail evidence. | **Explicit approval required for any hosted writes**. |
| P2 | **Improve observability/error mapping** (non-prod code change). | Generic save catch hides root cause. | Unit/widget tests for error surfacing; no sensitive logging. | Code review only. |
| P2 | **Review `super_admin_role_access.sql` separately**. | Behavior-changing; not required for basic listing save, may affect admin/category management. | Role/policy regression tests in staging. | **Explicit product/security approval required**. |

## Findings index (source file + function)

| Finding | File | Function/Area |
|---|---|---|
| Shared property/service save flow | `lib/features/listings/presentation/listing_form_screen.dart` | `_save`, type handling; `ListingType` in `listing.dart` |
| Create-before-media-upload, update-after-media, cleanup on failure | `listing_form_screen.dart` | `_save` |
| Generic save error surfaced to user (no silent swallow) | `listing_form_screen.dart` | `_save` catch `AppException/FormatException/catch` |
| Profile role/phone resolution and insert | `lib/features/listings/data/supabase_listings_repository.dart` | `create` |
| Create rollback only on image metadata replacement failure | `supabase_listings_repository.dart` | `create` (`_replaceImages` try/catch delete) |
| Update uses `update_listing_with_images` RPC | `supabase_listings_repository.dart` | `update` |
| Image metadata shape and replace RPC | `supabase_listings_repository.dart` | `_imageMetadata`, `_replaceImages` |
| Video metadata stored in `listings.video_url` | `supabase_listings_repository.dart` | `_toSupabaseRow`, `_resolveListingMediaUrls`, `_isListingVideoPath` |
| Missing RPC mapping | `supabase_listings_repository.dart` | `_mapDatabaseError` |
| Storage bucket IDs/path/auth/cleanup | `lib/features/listings/data/media_uploader.dart` | `SupabaseMediaUploader` constants, `uploadPickedImages`, `uploadPickedVideo`, `_requireUploadTarget`, `_upload`, `_cleanupAfterFailure`, `deleteImages/deleteVideo` |
| Client media validation limits | `media_uploader.dart` | `ListingMediaValidator` |
| Signed URL resolution for private media | `supabase_listings_repository.dart` | `_resolveListingMediaUrls` |
| Detail screen playback/display | `lib/features/listings/presentation/listing_detail_screen.dart` | video section uses `ListingVideoPlayer(videoUrl: listing.videoUrl)` |
| Video player | `lib/features/listings/presentation/listing_video_player.dart` | `ListingVideoPlayer`, `_initialize` |
| Category/area dependency | `supabase_listings_repository.dart` | `_resolveOptionId/_requireOptionId`; `app_config.dart` — `fetch` |
| Required RPCs missing from initial migration | `supabase/migrations/20261118000000_initial_arua_schema.sql` vs `supabase/manual/secure_listing_image_owner_paths.sql` | migration grep; manual script function defs |
| Video bucket missing from initial migration | `20261118000000_initial_arua_schema.sql` vs `secure_listing_video_storage.sql` | storage bucket sections |
| Insert trigger gap | `20261118000000_initial_arua_schema.sql` vs `secure_listing_insert_fields.sql` | `protect_listing_owner_fields` |

## Appendix A — Exact submission payloads (source-code verified)

### A1. Property/service create (`SupabaseListingsRepository.create`)

**Preconditions / lookups:**
- `user = _client.auth.currentUser`; throws if null.
- `isAdmin = user.appMetadata.admin == true || super_admin == true`.
- `requestedOwnerId = (ownerId ?? listing.ownerId).trim()`; if admin and requestedOwnerId present it must be UUID, else `listing.ownerId` becomes `user.id`.
- `effectiveOwnerId = isAdmin ? (requestedOwnerId or user.id) : user.id`.
- Profile read: `from('profiles').select('full_name, phone, role, is_verified').eq('id', effectiveOwnerId).maybeSingle()`.
- Non-admin requires profile.role in {`landlord`,`provider`}.
- `categoryId = _requireOptionId('categories', listing.category)`; `areaId = _requireOptionId('areas', listing.area)`.

**Insert table:** `public.listings`  
**Insert payload:** `_toSupabaseRow(... includeProtectedFields: isAdmin)` plus optional `id` if `listing.id` is UUID.

`_toSupabaseRow` keys:
```json
{
  "owner_id": "<effectiveOwnerId>",
  "owner_name": "<profile.full_name required>",
  "owner_phone": "<profile.phone or submitted listing.ownerPhone or throws>",
  "type": "property|service",
  "category_id": "<resolved UUID>",
  "area_id": "<resolved UUID>",
  "title": "<trimmed>",
  "title_lower": "<trimmed lowercase>",
  "description": "<trimmed>",
  "price_ugx": <int>,
  "price_unit": "month|job|hour|fixed",
  "address": <string|null>,
  "latitude": <double|null>,
  "longitude": <double|null>,
  "bedrooms": <int|null>,
  "bathrooms": <int|null>,
  "amenities": [<string>...],
  "thumbnail_url": <string|null>,
  "video_url": "<videoStoragePath or videoUrl or null>",
  "status": "pending|approved",
  "rejection_reason": <string|null>,
  "search_prefixes": [<string>...],
  // only when includeProtectedFields/isAdmin:
  "rating_avg": <number>,
  "rating_count": <int>,
  "is_featured": <bool>,
  "owner_verified": <bool>
}
```

**Post-insert image metadata (only when listing has images):** RPC `replace_listing_images`
```json
{
  "p_listing_id": "<inserted listing id>",
  "p_images": [
    {"image_url": null|"<url>", "storage_path": null|"<path>", "display_order": 0}
  ]
}
```

### A2. Property/service update (`SupabaseListingsRepository.update`)

**Preconditions:** listing.id required; existing row loaded; user must be owner or admin. Category/area resolved by name.

**RPC:** `update_listing_with_images`
```json
{
  "p_listing_id": "<listing.id>",
  "p_listing_data": {
    // same keys as _toSupabaseRow(includeProtectedFields: isAdmin)
    // then created_at removed
    // if non-admin: rejection_reason forced null, status forced pending
  },
  "p_images": [
    {"image_url": null|"<url>", "storage_path": null|"<path>", "display_order": 0}
  ]
}
```

**Notable behavior:** `update` always calls RPC (not conditional on image changes) and returns constructed `updated` object without re-reading the DB row.

### A3. Media upload (Storage REST)

**Endpoint:** `POST <supabase.url>/storage/v1/object/<bucket>/<ownerId>/<listingId>/<microseconds>_<random>_<index>.<ext>`  
**Headers:** `Authorization: Bearer <current session access token>`, `apikey: <anon/public key>`, `x-upsert: false`, `Content-Type: <mime>`, `Cache-Control: max-age=3600`  
**Buckets:** `listing-images`, `listing-videos`.  
**Client-side validation before upload:** images jpg/jpeg/png/webp, <=6MiB, magic bytes match extension; videos mp4/webm, <=50MiB, magic bytes match extension.  
**Cleanup:** on upload failure, uploader attempts `storage.from(bucket).remove([path...])`; on metadata save failure after upload, form attempts delete of newly uploaded media.

## Appendix B — Verification status

| Item | Status | Evidence |
|---|---|---|
| Source-code audit completed | **PASS** | Repository files inspected; report cites files/functions. |
| Production/deployed Supabase compatibility | **NOT VERIFIED / BLOCKED** | No deployed DB/storage/policy/RPC inspection executed. |
| Save-button failure reproduced in production | **NOT REPRODUCED** | Read-only audit only. |
| Hosted property/service end-to-end submission | **NOT TESTED** | No hosted writes performed. |
