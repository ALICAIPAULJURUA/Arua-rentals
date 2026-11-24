# Media Upload Implementation

## Overview
Listing media uploads are implemented with a private-bucket, signed-URL flow for Supabase Storage. The Flutter client validates and previews files, uploads binaries directly to Supabase Storage object endpoints using the authenticated user session, persists metadata through the existing listing APIs/RPCs, and resolves private media to signed URLs for display/playback.

No production Supabase configuration, buckets, tables, policies, or SQL were changed or executed as part of this implementation. Hosted write/upload tests were not run.

## Supported formats and limits

### Images
- Formats: JPG/JPEG, PNG, WebP
- Maximum count: 8 images per listing (existing/public URLs + hidden retained storage images + newly selected images)
- Maximum size: 6 MiB per image (preserved)
- Client validation: file extension allowlist, magic-byte signature checks, extension/signature match, count, and size
- Storage path convention: `<auth.uid>/<listing.id>/<generated filename>` where generated filename is unique (`<microseconds>_<random>_<index>.<ext>`)

### Videos
- Formats: MP4, WebM
- Maximum count: 1 video per listing
- Maximum size: 50 MiB per video (client and prepared storage policy)
- Client validation: file extension allowlist, magic-byte signature checks, extension/signature match, count, and size
- Storage path convention: `<auth.uid>/<listing.id>/<generated filename>` (same unique filename pattern)
- MOV: not currently supported by the implemented validator/picker/playback path. The picker and validator accept MP4/WebM only; adding MOV would require confirmed cross-platform playback support and aligned Storage MIME/type policy.

## Storage buckets and policies

### Existing image bucket
- Bucket: `listing-images` (private)
- Signed URLs: required for viewing private storage-backed images
- Ownership/path enforcement and server-side size/MIME limits are defined in existing/manual SQL (`supabase/manual/secure_listing_image_owner_paths.sql`) and must remain in place.

### Required video bucket (prepared locally, not applied)
- Prepared script: `supabase/manual/secure_listing_video_storage.sql`
- Bucket: `listing-videos` (private)
- Prepared limits: 50 MiB, allowed MIME types `video/mp4`, `video/webm`
- Prepared policies mirror image ownership model:
  - object paths must be `<owner_uid>/<listing_id>/<file>`
  - read access for approved listing videos (for signed URL resolution), listing owners, and admins, only when `public.listings.video_url` matches the object path
  - insert/update/delete for listing owners and admins only when the listing exists and path owner/listing match
- Do not make `listing-videos` public. Do not expose `service_role`.

## Database schema

### Current schema used
- `public.listings.video_url` (`text`, nullable): stores either an external video URL (legacy/input path handling) or, for private uploaded videos, the storage object path in `listing-videos`.
- `public.listing_images`: stores image metadata (`image_url`, `storage_path`, `display_order`) and remains the source for image ownership/path-safe persistence via existing RPCs.
- `public.replace_listing_images(...)` and `public.update_listing_with_images(...)`: existing image metadata/listing update path; no new RPCs or columns were introduced for videos.

### Schema changes prepared
- No database schema migration is required for the current implementation because private uploaded video paths are persisted in the existing `public.listings.video_url` column and resolved to signed URLs at read time.
- If production requires separate video metadata, thumbnails, transcoding state, or stricter DB-level checks for `video_url` storage paths, prepare and review SQL locally before any deployment.

## Upload and retrieval workflow

### Selection and client validation
- Listing form provides `Add images` and `Add video` actions (file picker on supported platforms). On web, a drag-and-drop hint is shown; picker-based selection remains the reliable cross-platform path.
- Selected images show thumbnails, filename/size context, per-image upload progress during save, reorder, and remove controls.
- Selected videos show a local preview, filename, size, upload progress, and cancel/remove controls.
- Unsupported formats, extension/signature mismatches, oversized files, and count violations are rejected before upload.

### Save lifecycle
1. User selects/edits media and submits the listing form.
2. Client validates form fields and normalizes external image/video inputs as applicable.
3. Listing row is created first when needed so a stable listing ID and ownership context exist for storage-path policy checks.
4. New image files upload to private `listing-images` under `<auth.uid>/<listing.id>/<generated filename>`.
5. New video file (if selected) uploads to private `listing-videos` under the same owner/listing path convention.
6. Listing image metadata is persisted through existing repository/RPC flow; listing `video_url` is updated to the uploaded video storage path or cleared when removed.
7. On metadata persistence failure, only files uploaded during that operation are cleaned up.
8. After successful persistence, removed/replaced old storage images/videos are deleted best-effort; failures are reported without deleting existing retained media.
9. Listing reads resolve storage-backed image/video paths to signed URLs for display/playback.

### Failure handling and retries
- Uploads are direct binary requests to Supabase Storage with progress callbacks and per-item start/progress reporting.
- Video uploads can be canceled via cancel token; canceled/failed uploads attempt cleanup of the exact attempted path.
- If a create succeeds but media upload/persistence fails, the form keeps the created listing context and selected files so the user can retry without creating duplicates.
- Edit operations do not delete existing retained media merely because the edit/upload fails.

## Playback and viewing
- Listing detail resolves and displays image galleries as before.
- Listing detail displays/playbacks resolved signed video URLs using `video_player` (`ListingVideoPlayer`) when `videoUrl` is present.
- Signed URL resolution is performed by `SupabaseListingsRepository` for approved listings, owners, and admins (with 3600s TTL and batching where applicable).

## Platform limitations
- Verified automated coverage in this environment is mocked/unit/integration-style and Chrome startup/render verification; no real hosted Supabase uploads were performed.
- Local video preview relies on `video_player` platform support and, on web, browser blob/media support for MP4/WebM.
- MOV is not supported by current picker/validator. Web browser codec/container support for MOV is inconsistent; keep MP4/WebM unless end-to-end playback is verified on target platforms.
- Drag-and-drop file selection is not implemented as a native web drop zone in this pass; the UI provides clear add actions and a web hint, with file-picker selection as the supported path.
- Flutter app build/startup currently depends on a local Dart-defines file (e.g. `supabase.local.json`) for Supabase initialization.

## Deployment steps (manual review required)
1. Review and apply `supabase/manual/secure_listing_image_owner_paths.sql` if not already applied/verified for the target environment.
2. Review and apply `supabase/manual/secure_listing_video_storage.sql` in a non-production/staging environment first, then production only after explicit approval.
3. Verify `listing-images` and `listing-videos` buckets are private with expected MIME/size limits.
4. Verify Storage RLS policies for both buckets and ensure no permissive conflicting policies remain.
5. Verify authenticated users can upload only to their own `<uid>/<listing-id>/...` paths for listings they own/admin-manage.
6. Verify signed URL generation and playback for approved listings, owners, and admins.
7. Run focused tests, full tests, and analyzer in CI/build environment.
8. Perform manual QA on Chrome/Web and Android with real non-production Supabase Storage before production rollout.

## Outstanding production configuration
- Create/configure `listing-videos` bucket and apply prepared policies in target Supabase project.
- Confirm whether approved-listing viewers require storage object SELECT access for signed URL generation in the deployed Supabase/Auth configuration; adjust policies only through reviewed SQL if needed.
- Confirm desired video formats/size limits for production (especially if MOV support is required).
- Perform manual hosted upload/playback/delete verification with real storage objects and signed URL expiry/refresh behavior.
- Consider adding server-side/database constraints or metadata structures if future requirements include video transcoding, thumbnails, multiple videos, or richer moderation metadata.
