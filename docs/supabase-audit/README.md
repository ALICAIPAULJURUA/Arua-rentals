# Supabase Read-Only Deployment Audit Pack

This directory contains **read-only** SQL audit scripts for manually verifying the deployed Supabase project against the Arua Rentals application requirements (as of commit `cb4f970`, Phase 1 inspection).

## Safety / scope

- **Read-only only:** all scripts use `SELECT`, catalog views (`information_schema`, `pg_catalog`, `pg_policies`, `pg_trigger`, `pg_proc`, etc.), and Supabase metadata tables such as `storage.buckets`.
- **No writes:** scripts contain no `CREATE`, `ALTER`, `DROP`, `INSERT`, `UPDATE`, `DELETE`, `TRUNCATE`, `GRANT`, `REVOKE`, `COMMENT`, `DO` write blocks, or storage mutations.
- **No production changes by this agent:** these scripts were prepared locally; they were **not executed** against production.
- **No secrets/PII:** do not paste `supabase.local.json`, service-role keys, access tokens, or personal user records into tickets/chat logs. The seed audit queries categories/areas only; other audits use metadata/catalogs and do not select user PII.

## Files

| File | Purpose |
|---|---|
| `01_database_audit.sql` | Tables/columns, PKs/FKs, functions/signatures, required RPCs (`replace_listing_images`, `update_listing_with_images`), function security mode and execute privileges, triggers (especially listings insert/update protection). |
| `02_rls_policy_audit.sql` | RLS enabled/forced status, policies for `profiles`, `listings`, `listing_images`, `categories`, `areas`, `role_requests`; required policy presence; duplicate/overlapping permissive policy warnings; listings owner insert/update/public-select sanity checks. |
| `03_storage_audit.sql` | `storage.buckets` config for `listing-images`, `listing-videos`, `avatars`; all `storage.objects` policies; expected listing image/video policies; ownership/media-reference validation heuristics; folder-name-only heuristic; overlapping permissive storage policies. |
| `04_seed_data_audit.sql` | Categories/areas counts, active/inactive rows, duplicate slugs/names, expected seed records, missing category/area FK signals. No seed inserts/updates. |
| `05_security_audit.sql` | RLS coverage, excessive RPC/function privileges, missing listing INSERT protection, public/anon table access review, private media exposure/storage policy review, overlapping permissive policies, ownership-check signals. |

## How to run in Supabase SQL Editor

1. Open the target Supabase project dashboard.
2. Go to **SQL Editor**.
3. Create a new query.
4. Paste the contents of one audit script (run scripts one at a time for clearer result sets).
5. Click **Run**.
6. Capture results for **every result set** in the script (Supabase SQL Editor shows multiple result tables when a script contains multiple `SELECT` statements). Export CSV/screenshots as needed, but redact any sensitive values if they appear unexpectedly.
7. Repeat for scripts `01` through `05`.

Recommended order: `01` -> `02` -> `03` -> `04` -> `05`.

## What to capture

For each script, capture:

- The full result table for each query/result set.
- The project ref/environment name (do **not** include secrets).
- Date/time and operator.
- Any query errors (e.g., missing relation `storage.buckets` in non-Supabase Postgres would be a limitation; in Supabase it should exist).

Specifically confirm:

- **RPCs:** `public.replace_listing_images(uuid,jsonb)` and `public.update_listing_with_images(uuid,jsonb,jsonb)` exist, are `SECURITY INVOKER` (expected), authenticated can execute, anon/public cannot execute.
- **Triggers:** `listings_protect_owner_fields` exists and its function handles `INSERT` (from `secure_listing_insert_fields.sql`) and protects owner/moderation/aggregate/featured fields.
- **RLS:** enabled on all target tables; listings owner insert requires owner + pending + landlord/provider role; owner update requires owner + pending; public select only approved.
- **Buckets:** `listing-images` private, 6 MiB, `image/jpeg,image/png,image/webp`; `listing-videos` private, 50 MB, `video/mp4,video/webm`.
- **Storage policies:** no unintended public access; public read policies should also validate approved listing and actual object reference (`listing_images.storage_path` or `listings.video_url`), not folder name alone.
- **Seed data:** expected categories/areas exist and are active; no duplicate slugs.

## Status interpretation

| Status | Meaning | Action |
|---|---|---|
| `PASS` | Check matches the repo-expected configuration. | No action for that check; still review related warnings. |
| `FAIL` | Check indicates missing/misconfigured/insecure configuration. | Correct before production reliance. Requires explicit approval before applying fixes. |
| `WARNING` | Potential issue, intentional difference, or heuristic hit requiring manual review. | Inspect the row details and decide. Common for overlapping permissive policies where owner/admin OR is intended. |
| `NOT_VERIFIED` | Cannot be fully verified by this query alone. | Use dashboard/manual review or an additional targeted query. |
| `INFO` / `REVIEW` | Context row for manual inspection. | Review, especially for unexpected permissive policies. |

## Findings requiring corrective action (before production deployment)

Treat as corrective-action required when audit shows:

- Missing required table/column, RPC, trigger, or bucket.
- `replace_listing_images` / `update_listing_with_images` missing, SECURITY DEFINER unexpectedly, or executable by anon/public.
- RLS disabled on sensitive tables.
- Listing owner insert/update policies missing required owner/pending/role checks.
- `protect_listing_owner_fields` missing INSERT handling (risk: client-supplied protected fields/defaults on insert).
- `listing-images` or `listing-videos` bucket missing, public, wrong size limit, or wrong MIME types.
- Storage policies granting public/anon access without approved-listing + referenced-object checks.
- Duplicate/conflicting permissive policies that broaden access beyond intent.
- Missing/inactive expected categories/areas causing listing create/edit failures.

## Known repo/manual script mapping

- `supabase/migrations/20261118000000_initial_arua_schema.sql` — baseline schema/RLS/triggers/buckets.
- `supabase/manual/secure_listing_insert_fields.sql` — INSERT handling for listing owner-field protection trigger.
- `supabase/manual/secure_listing_image_owner_paths.sql` — listing-images limits, stricter storage policies, `replace_listing_images`, `update_listing_with_images`, listing_images admin policies.
- `supabase/manual/secure_listing_video_storage.sql` — private `listing-videos` bucket and storage policies.
- `supabase/manual/seed_listing_options.sql` — idempotent category/area seed upserts.
- `supabase/manual/super_admin_role_access.sql` — behavior-changing super-admin hardening; **do not apply by default** without explicit product/security approval.

## Limitations / dashboard checks

- These scripts inspect database/catalog state visible via SQL. They cannot prove Supabase Dashboard settings outside SQL (Auth provider config, API settings, SMTP, custom domains, Storage CDN settings, etc.).
- `pg_get_functiondef` may be unavailable to insufficient roles; run in SQL Editor as a project owner/admin role.
- Policy text heuristics (`ilike`) can produce false positives/negatives; always review `using_expression`/`with_check_expression`.
- Overlapping permissive policies are reported as `WARNING` because permissive policies OR together; some overlaps are intentional (owner OR admin).
- Actual deployed-state comparison was **not performed** by this agent because no Supabase CLI/project link/MCP access was available. Results must come from manual execution in the target Supabase project.
