# Supabase Migration Audit

> Historical snapshot only; it predates the implementation below and is not a
> current repository inventory. Since this audit, the Flutter auth/profile,
> listings, favorites, chat, and admin repositories have been migrated to
> Supabase and Firebase app dependencies/configuration have been removed. The
> Firebase source-data import and hosted write verification are still
> incomplete; do not treat Firebase retirement or production data migration as
> complete.

**Audit date:** 2026-11-17
**Scope:** Repository inspection and migration design only. No database was contacted, no SQL migrations were created, and no Firebase code or dependencies were removed.

## Executive summary

The checked-in application has a feature-first Flutter structure using Riverpod, GoRouter, Firestore repositories, and Firestore rules. It already implements email/password authentication, profile/role requests, listing browse and moderation, favorites, and chat. The current working tree also contains uncommitted changes to `lib/main.dart`, `lib/app.dart`, `pubspec.yaml`, and `pubspec.lock`: the app entry points have been replaced with a Supabase “todos” starter, while the feature repositories still use Firebase. This replacement currently breaks analysis and the widget test that expects the original app.

The data model should be migrated from the actual Firestore fields, not just the initial table proposal. In particular, preserve the current listing details and moderation behavior, role-request review metadata, favorite ordering, chat unread behavior, and Arua/category configuration. Ratings and reports are not part of this migration; document them for later development, and inventory any existing legacy rating records before Firebase retirement.

## 1. Current architecture and working-tree state

### Checked-in application architecture

- `lib/main.dart` initializes Firebase and starts `ProviderScope` with `AruaCityFinderApp`.
- `lib/app.dart` creates a `MaterialApp.router` using the shared app theme and `appRouterProvider`.
- `lib/core/router/app_router.dart` defines the GoRouter routes and auth/role redirects.
- Newer code is feature-first under `lib/features/{auth,listings,favorites,chat,admin}/{data,presentation}`. Repositories own Firebase calls; Riverpod providers expose repository and feature state.
- Shared infrastructure lives under `lib/core/` (constants, validation, error mapping, routing, theme, and widgets).
- Older `lib/screens/`, `lib/services/`, and root `lib/models/` code coexist with the feature-first code. The current feature router does not reference those legacy screens. Some legacy screens call other legacy screens/services directly. They should be treated as unclassified legacy until a complete reference check during implementation—not deleted as part of this audit.

### Current uncommitted changes (preserved)

The worktree replaces the checked-in Firebase bootstrap and app widget with a bare Supabase initialization and a Todos demo. The current `lib/app.dart` is missing Flutter/Supabase imports and no longer defines `AruaCityFinderApp`; it also drops `ProviderScope`, GoRouter, the app theme, and all marketplace screens. The current `lib/main.dart` calls `MyApp()` without importing `app.dart` and does not call `WidgetsFlutterBinding.ensureInitialized()` before Supabase initialization.

The migration work must first reconcile this starter-code experiment with the app bootstrap. This report does not modify those files. The Supabase project URL and publishable client key are currently embedded in the uncommitted `main.dart`; a publishable key is intended for client use, but environment-specific configuration should be supplied through build configuration rather than committed source. No service-role key was found in the inspected source.

## 2. Firebase and Supabase dependencies

| Dependency | Current use found | Migration implication |
|---|---|---|
| `cloud_firestore` | Used by auth/profile, listing, favorites, chat, admin, and app-config repositories; also used by legacy services/screens. | Replace at repository/data boundaries. Keep Firebase active until Supabase parity and RLS tests pass. |
| `firebase_auth` | Used by auth state, registration/login/logout/password reset, listing/admin identity, and admin custom-claim checks. | Replace with Supabase Auth and explicitly map Firebase users to new Supabase Auth UUIDs. |
| `firebase_core` | Required by generated Firebase options and existing Firebase plugins; the checked-in `HEAD` bootstrap initializes it, but the current uncommitted `main.dart` does not. | Remove only after all Firebase-backed features and platform configuration are retired. |
| `firebase_storage` | Present in `pubspec.yaml`/lockfile, but no Storage API use was found. | There is no existing Firebase Storage upload flow to port. Current feature uploader validates external URLs. |
| `firebase_app_check` | Dependency only; no initialization/enforcement call found. The checked-in bootstrap has a TODO to enable App Check. | No active App Check behavior to reproduce. |
| `firebase_messaging` | Dependency only; no FCM calls or initialization found. `fcmTokens` is a profile field but there is no active token lifecycle. | Keep available during migration. Retain FCM if push notifications are required; Supabase Realtime is not a push notification service. Verify whether any deployed workflow outside the inspected Flutter code sends FCM. |
| `supabase_flutter` | Added in the uncommitted manifest change and initialized only in the Todos starter. No feature repository currently queries Supabase. | No production Supabase-backed feature is in place yet. |
| Other relevant packages | `flutter_riverpod`, `go_router`, `image_picker`, `flutter_image_compress`, and `cached_network_image` exist. `image_picker` is used in legacy UI; the active feature `MediaUploader` does not use it. | Riverpod/GoRouter can remain. Audit actual media UI usage before choosing the upload integration. |

`firebase.json` configures Firestore rules, indexes, and a Firestore emulator only. `firestore.rules`, `firestore.indexes.json`, Firebase platform configuration, `tools/set_admin.js`, and Firestore rules tests are present. No `storage.rules`, Firebase Functions directory, Supabase migrations, or Supabase RLS tests were found. The root Node test command exists, but its local test dependency is not installed (see validation).

## 3. Existing Firestore schema and workflows

### Collections and document shapes in current feature code

| Firestore path | Current shape / behavior | PostgreSQL treatment |
|---|---|---|
| `users/{uid}` | `name`, `email`, `phone`, `role`, optional `roleRequest`, `photoUrl`, `fcmTokens`, `isVerified`, `createdAt`, `updatedAt`. Roles are `tenant`, `landlord`, `provider`, `admin`. | `profiles.id` references `auth.users.id`. Store the profile fields and keep role changes server-controlled. `roleRequest` should move to `role_requests`, not be duplicated as an independently writable profile field. |
| `role_requests/{uid}` | One request document per user; `uid`, `requestedRole`, `status`, name/email/phone snapshots, timestamps; review records `reviewedBy`, `reviewedAt`, and optional reason/rejection reason. Approval updates request and profile role in one batch. | Separate table with a user FK, requested-role/status checks, reviewer FK, review metadata, and a transaction that updates the request and profile together. |
| `listings/{listingId}` | `ownerId`, owner name/phone snapshots, `type` (`property`/`service`), category, title/titleLower, description, `priceUgx` (integer), `priceUnit` (`month`/`job`/`hour`/`fixed`), area/address/GeoPoint, bedrooms/bathrooms, amenities, image URLs/thumbnail/video URL, `status` (`pending`/`approved`/`rejected`), rejection reason, rating average/count, search keyword prefixes, `isFeatured`, `ownerVerified`, timestamps. | Main `listings` table plus category/area FKs and `listing_images`. Preserve all current behavior/fields unless the product confirms a change. |
| `favorites/{uid}/items/{listingId}` | Listing ID plus copied title, thumbnail URL, UGX price, area, and creation timestamp. Pages newest first; availability is checked against listing approval. | `favorites(user_id, listing_id, created_at)` with a unique user/listing pair. Join the current approved listing for display rather than retaining stale copied fields. |
| `chat_rooms/{roomId}` | Deterministic sorted `uidA_uidB_listingId`; participants, listing ID/title/thumbnail, `lastMessage`, `lastMessageAt`, per-user `unreadCount`, `createdAt`. | `chat_rooms` with listing FK, canonical two participant FKs, a uniqueness constraint on listing plus participant pair, and an inbox index. Preserve summary/unread behavior or replace it with transactionally maintained read receipts. |
| `chat_rooms/{roomId}/messages/{messageId}` | Current feature repository stores `senderId`, `text`, `createdAt`; text only, 1–1000 characters, with paginated/realtime reads. | `chat_messages(room_id, sender_id, message, message_type, created_at)`; add normalized read receipts if needed for per-user unread state. |
| `config/categories`, `config/areas` | `{items: [{id, label, active}], updatedAt}`; feature repository falls back to code defaults and admin UI can save changes. | `categories` and `areas` rows with stable unique key/slug, label/name, description, active flag, and sort order. Export live config before seeding; local defaults are not proof of deployed values. |
| `ratings` | Only used by legacy `RatingService`, which appends target/rater/stars/comment/timestamp records. | Decide whether and how to migrate legacy records into `reviews`; do not assume the Firestore `reviews` collection name is populated. |

`CollectionNames` also declares `reviews`, `reports`, and `payments`, but no active feature repository writes those collections. Listing models already contain rating aggregates; no server aggregation function was found. No reliable source of actual production records was accessed during this audit.

### Authentication and roles

- Registration uses Firebase email/password, creates a tenant profile, and optionally writes a landlord/provider role request atomically.
- Login, logout, auth-state listening, and password reset use Firebase Auth.
- A missing profile can be created from the Firebase Auth user; email is required.
- The UI/router uses profile role plus Firebase `admin` custom claim for admin access. The admin claim is provisioned by a local Firebase Admin SDK script using external service-account credentials.
- Firestore rules prevent clients from assigning `admin` and restrict owner profile writes; admin role/verification changes require admin rules.
- Admin role approval updates the request and profile in a Firestore batch. Rejected requests reset the profile to tenant and record a reason.
- Account password hashes and Firebase UIDs cannot be assumed portable to Supabase Auth. The account transition needs an explicit user re-authentication/password-reset plan and a mapping for foreign keys.

### Listings and moderation

- Browse uses approved-only queries, optional category/area/keyword filters, three sort modes, cursor pagination, and a featured query.
- Listing creation checks the profile role and uses the profile’s name/phone/verification state. Non-admin submissions enter `pending`; admin-created listings can be approved immediately.
- Owner edits preserve rating/featured/verification fields and reset status to `pending`; admin moderation approves/rejects with a bounded rejection reason.
- Admin tools list/filter pending items, manage users and role requests, update verification, and show counts.
- Search uses lowercased prefix tokens derived from title/category/area. This is not equivalent to PostgreSQL full-text search; retain the current behavior or approve a search redesign before changing it.
- The current feature `MediaUploader` only validates HTTP(S) image URLs (maximum eight). The Firebase Storage dependency is unused in that flow.

### Favorites and chat

- Favorites are owner-scoped, bounded/paginated, and only considered available while the listing is approved.
- Chat rooms are intended to be per listing and user pair, sorted deterministically; messages are text-only, paginated, and watched through Firestore streams. The room tracks last-message metadata and unread counts.
- **Existing chat/rules mismatch:** `firestore.rules` requires `lastMessageId` on valid room creation and a message send that updates it atomically, but `ChatRepository.openRoom` does not write that field and `sendMessage` does not update it. The rules also require the created message and room summary to reference the same message ID. The fake-Firestore repository tests do not enforce security rules. Verify/fix the existing Firebase workflow separately before using it as migration parity evidence.
- The older `lib/services/chat_service.dart` uses a different, non-deterministic room shape (`participantIds`, `participantNames`, `lastMessageTime`) and a non-atomic message update. Keep it classified as legacy until a complete route/reference review proves it can be removed.

## 4. Existing test coverage and observed baseline

- Flutter tests cover auth validation/phone normalization, role access, Firebase error mapping, listings browse/repository/widgets, admin repository behavior, favorites, and chat repository behavior. Most repository tests use `fake_cloud_firestore`; these do not verify deployed Firestore rules or Supabase RLS.
- `tests/firestore.rules.test.cjs` contains 15 emulator-oriented security tests for profiles, role requests, admin claims, listings, favorites, chat, public reads, and default-deny behavior.
- No Supabase repository, storage, Auth, Realtime, schema, or RLS tests exist yet.
- Baseline validation was run against the current worktree:
  - `flutter analyze` failed with 70 diagnostics, including compile errors in the modified `lib/app.dart` (missing Flutter/Supabase imports) and missing `AruaCityFinderApp` references in `test/widget_test.dart`.
  - `flutter test` completed 31 tests and failed to compile `test/widget_test.dart` for the same replaced app-widget issue.
  - `npm run test:rules:unit` could not start because `@firebase/rules-unit-testing` is not installed in the workspace.
- To distinguish pre-existing issues, a detached worktree at checked-in `HEAD` was analyzed and tested: it reports 42 analyzer diagnostics (largely existing deprecation/info findings) and all 37 Flutter tests pass, including the widget tests. In the modified worktree there are 70 diagnostics and the widget test cannot compile. The additional 28 diagnostics and widget-test regression are caused by the local starter-code edits in `lib/app.dart`/`lib/main.dart` (including missing imports, removal of `AruaCityFinderApp`, and missing `ProviderScope`/router shell), rather than by a pre-existing widget-test failure. No application files were changed to repair these issues.
- `npm run test:rules:unit` could not start because `@firebase/rules-unit-testing` is not installed in the workspace.
- The analyzer and widget-test failures in the current worktree are documented, not repaired or reverted.

## 5. Recommended PostgreSQL schema

Use the proposed relational tables, expanded only to preserve existing behavior. Use `timestamptz` for timestamps, integer/bigint values for UGX (never floating point), explicit foreign keys and checks, and indexes for foreign keys and actual query patterns. Keep table/column names lowercase `snake_case`.

| Table | Recommended columns and constraints |
|---|---|
| `profiles` | `id uuid primary key references auth.users(id) on delete cascade`; `full_name`, `email`, `phone`, `avatar_url`, optional `fcm_tokens` only if verified as required; `role` checked against tenant/landlord/provider/admin; `is_verified`; `account_status` based on Firebase Auth disabled state and any verified status fields (the inspected profile model has no `accountStatus` field); timestamps. Keep email here only if the app needs client-accessible/admin-searchable profile email; otherwise Auth remains its source of truth. Do not permit a user to write their own role, verification, or account status. Admin profile values may be imported, but must not confer admin privileges automatically. |
| `categories` | UUID ID, unique stable slug, label/name, optional description, `is_active`, sort order, created/updated timestamps. Preserve the current category labels and active/inactive admin configuration. |
| `areas` | UUID ID, unique stable slug, label/name, optional description, `is_active`, sort order, created/updated timestamps. Seed only after comparing with the live Firestore config. |
| `listings` | UUID ID; `owner_id` FK; preserve `owner_name`/`owner_phone` snapshots if public contact behavior requires them; `type` checked as property/service; `category_id` and `area_id` FKs; title/title-lower, description, `price_ugx bigint CHECK (price_ugx > 0)`, checked `price_unit`, address, latitude/longitude, bedrooms/bathrooms, amenities, video URL, status checked pending/approved/rejected, rejection reason, `is_featured`, timestamps. Keep a unique `legacy_firebase_id` during migration to preserve old links and enable idempotent imports. |
| `listing_images` | UUID ID; listing FK with deliberate cascade behavior; `image_url` for legacy/external URLs; `storage_path` for Supabase Storage objects; display order; created timestamp; unique `(listing_id, display_order)`. Treat the first ordered image as thumbnail or define one explicit thumbnail rule, rather than maintaining conflicting image lists. |
| `role_requests` | UUID ID; `user_id` FK; requested role check landlord/provider; status check pending/approved/rejected; `reviewed_by` profile FK; review timestamps/rejection reason; created/updated timestamps. Allow one pending request per user (partial unique index) while retaining prior reviewed requests. |
| `favorites` | UUID ID or a composite `(user_id, listing_id)` primary key; both FKs; created timestamp; unique `(user_id, listing_id)`. Add an index for each user’s newest favorites. |
| `chat_rooms` | UUID ID; listing FK; two distinct participant profile FKs stored in canonical order; unique `(listing_id, participant_one, participant_two)`; last-message preview/time and timestamps. Preserve the per-listing room identity and prohibit self-chat. |
| `chat_messages` | UUID ID; room FK; sender profile FK; text/message body; initially text-only `message_type` check; created timestamp. Index `(room_id, created_at desc, id)` for the current cursor order. If unread/read state must be per user, add `chat_message_reads` keyed by message and reader, or maintain unread counters only through a trusted transaction. |
| Ratings/reviews and reports | No PostgreSQL table in this migration. They are explicitly deferred features. Inventory any existing legacy `ratings` records and preserve/export them before Firebase retirement; do not create new rating/report UX or database behavior here. |

### Normalization and compatibility decisions

- The current model has one moderation `status`; the proposal’s additional `moderation_status` would duplicate it. Keep one status until a separate listing lifecycle (for example active/archived) is explicitly required.
- `role_requests/{uid}` is one document per user, so a later request may overwrite a reviewed request. Retaining full request history in PostgreSQL would change that behavior; confirm whether to preserve history or keep one current request per user.
- `property_type` is not represented in the existing model (which only distinguishes `type: property/service`). Do not populate or require it until the property subtypes are confirmed.
- `ownerVerified` duplicates `profiles.is_verified`; derive it via a listing/profile relation or safe view, unless a deliberate historical snapshot is required.
- `rating_avg`/`rating_count` are present on listings but the review source is inconsistent: an unused `reviews` collection constant versus a legacy `ratings` service. Do not add a new ratings feature in this migration. Export/inventory legacy records and decide separately how they are preserved before Firestore retirement.
- Existing favorite documents duplicate listing data. The normalized table should join the listing; keep a carefully defined snapshot only if offline behavior requires it.
- PostgreSQL can preserve the current browse/query model with indexes for approved/newest listings, owner listings, featured listings, and category/area filters. A GIN full-text index is appropriate only if changing from the current custom prefix-token behavior; do not silently change search results.
- UUIDs fit Supabase Auth identity and the proposed schema. Preserve Firebase document IDs in migration mapping columns/tables because they may not be UUIDs and are embedded in web listing URLs and chat references.
- Use a private, trusted admin-role mechanism (for example server-managed `app_metadata` or a tightly scoped database role table/function). Never authorize from user-editable `user_metadata`, and never ship a service-role/secret key in Flutter. Account for JWT claim refresh after role changes.
- Enable RLS on every exposed application table and Storage objects. Public reads should be limited to approved listings; listing owners may manage only their own rows and owner edits must return the listing to pending. Admin approval, role approval, ratings aggregates, and privileged profile fields must be server-controlled. Add both `USING` and `WITH CHECK` to update policies; RLS row filters alone do not restrict writable columns, so use column grants and/or trusted operations for protected fields.
- Chat room/message access must check the caller’s participant identity, not merely that the caller is authenticated. Supabase Realtime must be enabled only for the required chat tables and must remain subject to RLS.
- Storage needs explicit bucket/object policies and ownership-based paths. Keep current external image URLs readable during migration; do not assume all current media is stored in Firebase Storage.

## 6. Files likely to change in later phases

This list is a planning map, not authorization to edit or delete the files now.

- **Bootstrap/configuration:** `lib/main.dart`, `lib/app.dart`, `pubspec.yaml`, `pubspec.lock`, and environment/build configuration. Restore the marketplace app shell and single shared Supabase client before replacing feature repositories. Keep Firebase bootstrap/configuration until cutover is verified.
- **Auth and role routing:** `lib/features/auth/data/auth_repository.dart`, `app_user.dart`, `lib/features/auth/presentation/auth_providers.dart`, auth screens, `lib/core/router/app_router.dart`, and `lib/core/router/role_access.dart`.
- **Listings/configuration/media:** `lib/features/listings/data/listing.dart`, `listings_repository.dart`, `app_config.dart`, `media_uploader.dart`, related Riverpod providers/screens, and a new dedicated Supabase Storage service.
- **Favorites/chat:** `lib/features/favorites/data/favorites_repository.dart`, `lib/features/chat/data/chat_repository.dart`, their providers/screens, and message/read-state models.
- **Admin:** `lib/features/admin/data/admin_repository.dart`, `admin_records.dart`, admin providers/screens, and a trusted replacement for `tools/set_admin.js`.
- **Shared errors and tests:** `lib/core/errors/firebase_error_mapper.dart` and related tests; repository tests; new Supabase Auth/storage/RLS tests. Keep the existing Firestore rules and tests until the Firebase implementation is no longer in use.
- **Backend/deployment:** new `supabase/migrations/`, local Supabase config/seeds/tests, bucket policies, and possibly an Edge Function or trusted admin operation. No such migration/backend files currently exist.
- **Retirement only after parity:** Firebase dependencies, `lib/firebase_options.dart`, platform Firebase files (including Android `google-services.json`), `firebase.json`, Firestore rules/indexes, and legacy Firebase utilities. Do not remove these in the audit or before migration acceptance.

## 7. Risks, open decisions, and next actions

1. **Resolve the current app bootstrap edits first.** The current worktree cannot pass analyzer/widget tests, and the feature app is disconnected from the current entry point.
2. **Choose the account migration experience.** Existing Firebase passwords are not portable by assumption. Decide whether users re-register, use password reset/re-authentication, or receive another staged migration flow; obtain a Firebase data export and plan Firebase-UID-to-Supabase-UUID mapping.
3. **Confirm the production source of truth and environments.** Identify the Firebase dev/prod projects, Supabase dev/prod projects, who can export the current Firestore data/config/media, and whether Firebase must remain for FCM or other services.
4. **Export and verify category/area config before seed data.** The code defaults (`Rentals`, `Plumbing`, `Electrical`, `Cleaning` and the listed Arua areas) may be overridden by Firestore admin configuration.
5. **Decide search compatibility.** Retain current prefix matching for first release or approve a measured PostgreSQL search redesign.
6. **Resolve rating/report scope.** Determine whether the legacy `ratings` collection is in use, how it maps to one-review-per-user/listing, and whether reports are in the initial cutover.
7. **Choose Supabase Flutter package lane before implementation.** `pubspec.yaml` currently constrains `supabase_flutter` to `^2.18.3`. The Supabase changelog announces a v3 major API change; verify the stable release/migration guide and lock a tested version before coding rather than making an unrelated package upgrade during this audit.
8. **Set acceptance gates before cutover.** Add local RLS tests for every table/storage policy, then workflow tests for registration/login/reset, role approval, listing create/edit/moderation, favorites, chat access/read state, and image uploads. Keep both backends during phased verification.

## 8. Documentation consulted

- [Supabase Flutter quickstart](https://supabase.com/docs/guides/getting-started/quickstarts/flutter)
- [Supabase Row Level Security](https://supabase.com/docs/guides/database/postgres/row-level-security)
- [Supabase Storage](https://supabase.com/docs/guides/storage)
- [Supabase Auth](https://supabase.com/docs/guides/auth)
- [Supabase Flutter v3 changelog](https://supabase.com/changelog/supabase-flutter-v3)

## 9. Confirmed project decisions

1. **Accounts:** Preserve Firebase profile fields, roles, and account status values in the migration. Firebase passwords are not assumed transferable. Maintain an explicit Firebase UID to Supabase Auth UUID mapping. Importing an `admin` profile role does not grant administrator privileges; privileged access requires a separate trusted, explicit administrator bootstrap/approval.
2. **Categories and areas:** Do not invent seed data. Export the current Firestore configuration, verify IDs/labels/active flags with the project owner, then import the approved export into PostgreSQL.
3. **Search:** Use PostgreSQL full-text search with appropriate indexes while retaining current prefix-search behavior, category/area filters, sort options, and bounded cursor pagination.
4. **Ratings and reports:** Do not add these features in this migration. Document as later work, and inventory/export any existing legacy rating data before Firebase retirement.
5. **Push notifications:** FCM may remain as a separate push service. It is not currently used by the inspected application code, so verify whether deployed or planned workflows require it before removing its package/configuration.
6. **Local changes:** Preserve current modifications in `lib/main.dart` and `lib/app.dart`. Their differences from checked-in `HEAD` were inspected and are documented in §1. Existing modifications to the dependency manifest/lockfile were also left untouched.
7. **Test failures:** On clean checked-in `HEAD`, `flutter analyze` reports 42 existing diagnostics and `flutter test` passes all 37 tests. On the modified worktree, analysis reports 70 diagnostics and `test/widget_test.dart` fails to compile. The added diagnostics and test failure come from the local starter replacement in `lib/main.dart`/`lib/app.dart`, not the original checked-in app. This task does not fix those files.

## 10. Final recommended PostgreSQL schema

Use the following initial application schema in the Supabase `public` schema (or another deliberately exposed schema), with RLS enabled before any client grants. This is a design recommendation only; no SQL has been generated or applied.

### Core tables

| Table | Columns and integrity rules |
|---|---|
| `profiles` | `id uuid primary key references auth.users(id) on delete cascade`; `full_name text not null`; `email text`; `phone text`; `avatar_url text`; optional `fcm_tokens text[]` only if verified as required; `role text not null check (role in ('tenant','landlord','provider','admin'))`; `is_verified boolean not null default false`; `account_status` populated from verified Firebase Auth/profile status values (no `accountStatus` field was found in the inspected `AppUser` schema; inventory disabled Auth accounts and deployed status fields before defining allowed values); `created_at`, `updated_at timestamptz not null`. Preserve relevant profile data and role; protect `role`, `is_verified`, `account_status`, and admin authorization from user writes. Admin profile values may be imported, but must not confer admin privileges automatically. |
| `firebase_user_mappings` | `firebase_uid text primary key`; `supabase_user_id uuid not null unique references auth.users(id)`; `migration_batch text not null`; `mapped_at timestamptz not null`; optional import verification metadata. Keep mapping records in a restricted schema/table with no public client access. |
| `categories` | `id uuid primary key`; `legacy_id text unique`; `name text not null`; `slug text unique`; `description text`; `is_active boolean not null`; `sort_order integer`; timestamps. Populate only from a reviewed export of Firestore `config/categories`. |
| `areas` | Same structure as categories; populate only from a reviewed export of Firestore `config/areas`. |
| `listings` | `id uuid primary key`; `legacy_id text unique`; `owner_id uuid not null references profiles(id)`; owner contact snapshots where needed; `type text check (type in ('property','service'))`; `category_id`, `area_id` FKs; `title`, `title_lower`, `description`; `price_ugx bigint check (price_ugx > 0)`; `price_unit text check (price_unit in ('month','job','hour','fixed'))`; `address`; `latitude`, `longitude double precision` with range checks; optional positive bedroom/bathroom counts; `amenities text[] not null default '{}'`; optional `video_url`; `status text check (status in ('pending','approved','rejected'))`; `rejection_reason`; `is_featured boolean not null default false`; rating aggregate fields only as legacy read-only snapshots, not writable client data; `search_document tsvector` maintained by a trigger/generated mechanism based on approved searchable text; timestamps. Preserve listing fields and behavior from the current Firestore model. |
| `listing_images` | `id uuid primary key`; `listing_id uuid not null references listings(id) on delete cascade`; `image_url text` for legacy/external URLs; `storage_path text` for Supabase objects; `display_order integer not null check (display_order >= 0)`; `created_at timestamptz`; ensure at least one of URL/path exists and unique `(listing_id, display_order)`. |
| `role_requests` | `id uuid primary key`; `user_id uuid not null references profiles(id)`; requested-role check landlord/provider; status check pending/approved/rejected; requester name/email/phone snapshots if the admin workflow needs them; `reviewed_by uuid references profiles(id)`; `reviewed_at`, `rejection_reason`, `created_at`, `updated_at timestamptz`. Add a partial unique index for one pending request per user. Preserve existing request IDs/status/history where exported; do not grant roles during import. |
| `favorites` | `user_id uuid references profiles(id) on delete cascade`; `listing_id uuid references listings(id) on delete cascade`; `created_at timestamptz`; primary key or unique constraint `(user_id, listing_id)`. Fetch current listing fields through a join, and index `(user_id, created_at desc, listing_id)` for the existing favorites page. |
| `chat_rooms` | `id uuid primary key`; `legacy_id text unique`; `listing_id uuid references listings(id)`; canonical sorted `participant_one uuid`, `participant_two uuid` FKs, distinct check, unique `(listing_id, participant_one, participant_two)`; listing title/thumbnail snapshots if needed for inbox continuity; last-message preview/time, created/updated timestamps. Index both participant inbox access patterns by participant and descending `last_message_at`. |
| `chat_messages` | `id uuid primary key`; `legacy_id text`; `room_id uuid not null references chat_rooms(id) on delete cascade`; `sender_id uuid not null references profiles(id)`; `message text not null check (length(message) between 1 and 1000)`; `message_type text not null default 'text' check (message_type = 'text')`; `created_at timestamptz not null`. Add `(room_id, created_at desc, id desc)` for bounded cursor pagination and uniqueness for `(room_id, legacy_id)` when a legacy ID exists. |
| `chat_message_reads` (recommended) | `message_id uuid references chat_messages(id) on delete cascade`; `user_id uuid references profiles(id) on delete cascade`; `read_at timestamptz not null`; primary key `(message_id, user_id)`. This normalized read receipt supports per-user unread state; maintain it via participant-authorized operations. |

### Search and browse indexes

- Maintain a PostgreSQL `tsvector` over title and description (with category/area labels where appropriate), using a GIN index. Query with `websearch_to_tsquery`/`plainto_tsquery` and rank results.
- Preserve existing prefix search by OR-ing a bounded prefix-token match against full-text results (for example a normalized `search_prefixes text[]` with a GIN index, generated during writes/import). Avoid an unbounded substring scan.
- Preserve filters for category and area and sorts by newest, price ascending, and price descending. Add composite indexes based on those query combinations, including approved status, sort key, and a stable unique tie-breaker.
- Use keyset pagination with all ordering columns plus `id` as the deterministic cursor. Keep page size bounded at the existing default of 20 and maximum of 100.
- Public browse queries must constrain the query to approved listings; RLS independently enforces that rule.

### Deliberately excluded from initial schema

Do not add rating/review or report tables, write paths, or UI as part of this migration. Preserve listing rating aggregates as imported legacy display data only if verified as required; expose them read-only and do not claim new ratings functionality. Review the old `ratings` collection and service as a separate follow-up before Firebase is retired.

## 11. Firebase-to-Supabase service mapping

| Existing Firebase surface | Supabase replacement / migration boundary |
|---|---|
| Firebase Authentication email/password, auth-state changes, logout, reset | Supabase Auth email/password, auth state/session persistence, sign-out, and reset flow. Firebase credential migration is a separate user re-authentication/password-reset process; never copy passwords or assume hashes transfer. |
| Firestore `users/{uid}` | `profiles`, with Supabase Auth UUID as `profiles.id`; copy/map Firebase UID via restricted `firebase_user_mappings`. |
| Firestore `listings` | PostgreSQL `listings` with relational category/area references and `listing_images`; retain listing IDs as `legacy_id` for deep links/data reconciliation. |
| Firestore `config/categories`, `config/areas` | PostgreSQL `categories` and `areas`, imported only from reviewed Firestore exports. |
| Firestore `role_requests` and admin batches | `role_requests` plus a trusted transaction/RPC/Edge Function that atomically records review and changes the profile role. Never allow the client to self-approve or set admin. |
| Firestore `favorites/{uid}/items` | `favorites` relation table; user-scoped RLS; listing data joined at read time. |
| Firestore `chat_rooms` and nested `messages` | `chat_rooms`, `chat_messages`, and read receipts, with participant-only RLS and Supabase Realtime for authorized chat updates. |
| Firebase Storage | Supabase Storage buckets and `storage.objects` RLS. Current feature repository uses URL validation rather than Firebase Storage; preserve external URLs and migrate only objects proven to exist. |
| Firestore Security Rules | PostgreSQL RLS, column privileges, constraints, and trusted server operations; add local policy tests. |
| Firebase Cloud Messaging | Retain FCM as a distinct push service if notifications are required. Supabase Realtime supports live data updates, not OS push delivery. Preserve Firebase project configuration until FCM dependencies are confirmed unnecessary. |
| Firebase App Check | No active App Check integration was found. Do not treat it as migrated; evaluate Supabase Auth/RLS and platform abuse controls separately. |
| Firebase Functions/Admin SDK | No Cloud Functions directory was found. Replace privileged client workflows with narrowly scoped server-side Supabase operations; the Firebase admin bootstrap script is not portable and must not become a client privilege path. |
| Legacy `RatingService`, `reports`, `payments` constants | No new Supabase service in this migration. Inventory/export any stored legacy data; ratings/reports/payments remain separately scoped future work. |

## 12. Authentication and account migration plan

1. **Inventory first:** using trusted Firebase Admin SDK/export tooling, enumerate Firebase Auth users and Firestore profiles. Capture UID, email, display name, phone, current profile role, verification/account status, timestamps, role requests, and migration-relevant metadata. Do not export password material into application files or logs.
2. **Define identity mapping:** create each Supabase Auth identity with a new UUID and persist a one-to-one Firebase UID → Supabase UUID mapping in a restricted migration table/file. Use this map to rewrite every owner, participant, sender, favorite, reviewer, and role-request foreign key. Keep original Firebase IDs on imported content for reconciliation and shared-link redirects.
3. **Separate credentials from profile migration:** Firebase passwords are not assumed portable. Use a user-invited re-authentication/password-reset activation flow (or an explicitly validated provider-supported import path if discovered later). Do not set a default/shared password or send credentials in plaintext. Accounts without a verified matching email require a manual recovery flow.
4. **Preserve profile/role/status:** import existing profile fields and actual account-status values. Resolve missing profiles, duplicate emails, malformed phones, and conflicting Auth/profile data into a review queue instead of silently discarding them.
5. **Do not auto-grant admins:** preserve the imported profile role value for audit/continuity, but initialize Supabase authorization so imported admin records have no privileged effective access. A trusted operator explicitly approves the administrator allowlist/custom claim after identity verification; keep an audit trail. The migration script must not bulk-set admin claims from Firebase profile values.
6. **Cutover in stages:** support a defined period for Firebase sign-in or a controlled migration prompt; once the user establishes Supabase credentials, resolve the mapping and use the Supabase UUID for all new writes. Communicate the cutover and recovery/support procedure before disabling Firebase Auth.

## 13. Firestore data migration and category/area verification

1. Obtain a consistent, access-controlled Firestore export (including documents and subcollections) and Firebase Auth user inventory from the correct dev/prod projects. Keep backups encrypted and outside source control; record export time, project ID, counts, and checksums.
2. Separately export `config/categories` and `config/areas` using a read-only Admin SDK script. Preserve document IDs, item IDs, labels, descriptions if present, active flags, and ordering. The Flutter defaults in `arua_areas.dart` and `listing_categories.dart` are not authoritative if admins have edited remote config.
3. Have the project owner verify exported category/area records against current operations. Produce an approved import manifest; flag unknown IDs, duplicate labels, inactive entries, and any listing references without a match. Do not add guessed seed records.
4. Create and validate the Firebase UID mapping before importing relational data. Load source exports into staging tables/files, validate counts and foreign keys, normalize timestamps to UTC `timestamptz`, retain monetary UGX values as integers, and map `GeoPoint` to latitude/longitude.
5. Import users/profiles and configuration first, then listings/images references, role requests, favorites, chat rooms/messages/read counts, with stable legacy IDs and idempotent upsert keys. Preserve listing status/rejection reason, owner snapshots, sort behavior, and approval state.
6. Inventory Firebase Storage objects and external image URLs separately. The current feature uploader accepts URLs; do not infer Firebase Storage objects from URL strings. Preserve existing URLs during the transition and create an object manifest with source path, listing/profile owner, content type, size, and checksum for actual objects.
7. Reconcile source and target per-table counts, representative records, orphan/duplicate reports, role/status distributions, category/area references, favorite order, room participants, message order, image URL/object availability, and browse/search result samples. Resolve all discrepancies before enabling production writes.
8. Use a read-only/staging dry run first, then a controlled final sync/cutover window with writes paused or dual-write reconciliation explicitly designed and tested. Keep a restorable Firebase export and rollback path until acceptance.
9. Export legacy `ratings` data and any other out-of-scope collections for preservation/review; do not silently drop them when Firebase is retired. No rating/report user-facing functionality is added by this phase.

## 14. Security and RLS implementation plan

- Enable RLS on every exposed application table and Storage object table before granting client access. Verify Data API exposure and grants independently of RLS.
- Use `auth.uid()` ownership checks for profile/favorite writes and listing ownership. Public/anonymous selection is restricted to approved listings; owners can read their own pending/rejected listings. Keep column-level privileges or trusted RPCs for protected fields because RLS does not itself protect individual columns.
- Users can update only explicitly whitelisted self-profile fields. Never allow a client to write `role`, `is_verified`, `account_status`, role-request review fields, owner verification, feature flags, moderation status, rating aggregates, mapping rows, or admin authorization metadata.
- A landlord/provider listing insert must have `owner_id = auth.uid()` and `status = 'pending'`; owner updates preserve owner/aggregate/admin fields and set the status back to pending. Only explicitly authorized administrators may approve/reject, with reason validation.
- RLS authorization for admins must use server-managed authorization data (e.g. trusted `app_metadata`/claims or a protected authorization table), never user-editable metadata. Imported Firebase admin role values do not create effective Supabase admins. Design for JWT claim refresh after changes.
- Restrict role requests to the authenticated user; make review and profile-role assignment atomic through a trusted, auditable operation. Do not create broad `SECURITY DEFINER` functions as a shortcut; if one is justified, isolate it from exposed schemas, check caller identity/authorization in its body, minimize privileges, and test it.
- Favorites: only the authenticated owner can select/insert/delete their row; enforce uniqueness and a valid listing FK.
- Chat: `chat_rooms` and `chat_messages` selection and writes require authenticated membership. Message sender must equal `auth.uid()` and be a room participant. Prevent self-chat, participant reassignment, message edits/deletes unless intentionally authorized, and unauthorized room metadata changes. Verify room-level and message-level policies in tests.
- Storage: choose private/public bucket behavior explicitly. Use immutable owner-prefixed object paths and enforce bucket, owner UID, image type, file size, and allowed operations in Storage RLS. Do not expose service-role credentials in Flutter. Existing public URLs remain until verified replacements are available.
- Add automated local RLS tests for anonymous, tenant, landlord, provider, unrelated user, and approved administrator roles, including update-column attempts, status transitions, ID reassignment, chat participant isolation, and storage path/type/size controls.

## 15. Chat migration plan

1. Treat the feature-first deterministic per-listing room shape as the target; do not migrate legacy `ChatService` documents into it without a field-by-field compatibility check.
2. Generate one mapping per legacy room/document ID to the new room UUID; translate both participant Firebase UIDs and listing Firebase IDs using approved mapping tables.
3. Copy room snapshots (`listingTitle`, `listingThumb`), `lastMessage`, `lastMessageAt`, `createdAt`, and each participant’s unread count. Preserve nested message IDs as `legacy_id`, sender, text, and original timestamp; sort consistently and verify page boundaries.
4. Choose a deterministic uniqueness rule on `(listing_id, canonical participant pair)` so retrying the import or opening a room cannot create duplicates. Reject self-chat and invalid/missing participants.
5. Derive and validate unread state before cutover. Prefer normalized read receipts for durable per-user state; if retaining counters, update counters and room summary atomically in trusted operations.
6. Enable Supabase Realtime only for necessary chat events/tables. Realtime subscriptions must be authenticated and participant-filtered by RLS; test reconnection, pagination, duplicate delivery, ordering, and read-state updates.
7. Resolve the existing Firestore chat/rules mismatch before using current traffic as a trusted reference. Keep Firebase chat available during a staged comparison, then cut over writes and reads together after parity and access-control tests pass.

## 16. Image storage migration plan

1. Confirm actual media locations from exported Firestore records and Firebase Storage inventory; current feature listing writes only accept HTTP(S) URLs and no Firebase Storage API use was found.
2. Keep existing external/Firebase URLs usable while importing listing data. Store the source URL and original Firebase object path in a migration manifest; do not rewrite URLs before destination objects are verified.
3. Define buckets (e.g. listing media and profile media), visibility, allowed image MIME types, maximum object size/count, and immutable owner-prefixed paths before implementation. Apply Storage RLS before client upload.
4. For actual Firebase Storage objects, copy bytes server-side using trusted credentials, preserve object metadata where needed, compress/resize only under an approved quality policy, and verify checksum/content-type/size after upload. Never download/re-upload through an untrusted client or commit service credentials.
5. Write Supabase `storage_path` plus the final public URL or signed-URL strategy to `listing_images` only after successful object verification. Keep original URLs as rollback references until the migration is accepted.
6. Add upload/delete/list service tests for owner isolation, rejected MIME/size, retry/idempotency, multi-image order, and read behavior for approved listings. Do not remove Firebase Storage configuration until inventory confirms it is not needed by any legacy consumer.

## 17. Phased implementation checklist (approval-gated)

### Phase 0 — prerequisites and baseline
- [ ] Resolve the existing local `main.dart`/`app.dart` starter edits without overwriting user work; agree whether to restore the marketplace shell as a separate explicit change.
- [ ] Obtain Firebase dev/prod export access and Supabase dev project/configuration.
- [ ] Confirm backup, rollback, migration window, user communications, and operator responsible for admin bootstrap.
- [ ] Repair/establish passing app analyzer and widget-test baseline in a separately scoped change.

### Phase 1 — export and discovery
- [ ] Export Firestore and Auth inventories from the correct environment, plus Storage object inventory if applicable.
- [ ] Export `config/categories` and `config/areas`; verify and sign off values with the project owner.
- [ ] Inventory profile account-status values, admin roles, role requests, ratings records, FCM use, listing IDs, favorites, and chat data.
- [ ] Produce a mapping/exception report before importing data.

### Phase 2 — schema and authorization
- [ ] Confirm final columns, checks, deletion behavior, indexes, legacy-ID mapping, and text-search semantics.
- [ ] Create reviewed, version-controlled Supabase migrations and staging import tooling (only after approval).
- [ ] Implement RLS, grants, trusted privileged operations, and Storage policies.
- [ ] Run local database lint/advisors and adversarial RLS tests before client integration.

### Phase 3 — client foundations and authentication
- [ ] Restore/retain the real app bootstrap and configure one shared Supabase client using environment-specific public URL/key configuration.
- [ ] Add typed repositories and error mapping while leaving Firebase services intact.
- [ ] Implement account mapping, user-driven credential establishment/reset, session persistence, profile loading, and guarded admin authorization.
- [ ] Keep Firebase Auth available through the verified transition; do not copy Firebase passwords.

### Phase 4 — configuration and listings
- [ ] Import reviewed categories/areas and verify exact labels/active state.
- [ ] Migrate listings and image references; reconcile counts, legacy URLs, owner IDs, and moderation status.
- [ ] Implement browse filters, FTS plus prefix compatibility, sort modes, cursor pagination, detail, owner dashboard, and admin moderation.
- [ ] Verify owner edits reset pending and moderation/admin privileges are server-enforced.

### Phase 5 — role requests and favorites
- [ ] Import/reconcile role requests without granting roles automatically.
- [ ] Implement protected, atomic role approval and explicit admin provisioning.
- [ ] Migrate favorites, preserve saved timestamps/order, and test unavailable/unapproved listing behavior.

### Phase 6 — chat and Realtime
- [ ] Resolve Firebase chat/rules mismatch and inventory both legacy and feature-first room formats.
- [ ] Migrate rooms/messages/read state and verify participant mapping.
- [ ] Implement RLS-protected realtime inbox/message subscriptions and compare results during staged rollout.

### Phase 7 — Storage and optional FCM continuity
- [ ] Migrate only verified Firebase Storage objects; preserve external URLs.
- [ ] Verify image display/upload/delete and Storage RLS on web and Android.
- [ ] Retain FCM if notifications are required; test push independently from Supabase Realtime.

### Phase 8 — acceptance and Firebase retirement
- [ ] Run full auth/profile/listing/admin/favorites/chat/image workflow tests and independent RLS tests.
- [ ] Reconcile final data counts and run end-to-end search/filter/sort/pagination checks.
- [ ] Confirm support path for accounts not yet migrated and rollback window closure.
- [ ] Only after explicit cutover approval, remove obsolete Firebase Auth/Firestore code and dependencies; preserve FCM dependencies/configuration if still required.
- [ ] Archive Firebase exports and document deferred ratings/reports work before disabling any Firebase project services.

## 18. Risks and dependencies

- **Current source state:** local app entry-point edits have broken the widget-test compile and increased analyzer diagnostics; they remain untouched pending an explicit implementation task.
- **Account continuity:** no password transfer assumption is safe; user activation/reset, email conflicts, deleted/disabled users, and support for users without accessible email must be designed and communicated.
- **Privilege safety:** preserving the historical admin role field while withholding admin access requires a separate effective-access model, manual allowlist approval, token refresh, and auditable trusted tooling.
- **Unverified data/config:** no live Firebase export was accessed. Production category/area values, account-status semantics, record counts, and storage usage remain unknown until exported and verified.
- **Search parity:** PostgreSQL full-text ranking differs from prefix token matching. Combined indexed FTS/prefix behavior and cursor stability require explicit query/result tests, especially when price sorting is combined with text relevance.
- **Schema compatibility:** category/area IDs, old listing IDs embedded in URLs, Firestore GeoPoints, denormalized owner/contact snapshots, and non-UUID chat/favorite IDs need mapping and fallback rules.
- **Chat security and data quality:** Firestore chat rules and feature repository disagree on `lastMessageId`; older chat documents use a different schema. Reconcile before migration and do not conflate legacy and feature-first room formats.
- **Storage gaps:** no active Firebase Storage uploader was found, while media URLs may point to external or Firebase hosts. Inventory objects and preserve URL availability before changing rendering.
- **Push notifications:** FCM is present as a dependency/profile field but unused in inspected code; confirm external/deployed use before package/project retirement.
- **RLS correctness:** role and moderation operations need trusted server authorization; tests must cover column protection, row reassignment, participant isolation, and policy behavior rather than only UI guards.
- **Dependency/version decisions:** `supabase_flutter` currently resolves within the v2 constraint. Supabase announced a v3 breaking-change release in November 2026; check the current stable version and migration guide when implementation begins, then pin/lock the chosen compatible version. Do not bulk-upgrade unrelated packages.
- **Migration operation:** large imports, final sync, and bucket copies need staging, retry/idempotency, checksums, backup retention, and a rehearsed rollback; no production migration should run before review/approval.
- **Deferred product scope:** ratings, reports, and payments are outside this migration. Preserve/export existing legacy rating data where present and track those features for later approval instead of silently deleting them.

## 19. Approval gate

This update is a plan only. No Supabase migration, database write, application functionality change, Firebase dependency removal, category/area seed, or production export was performed. Wait for explicit approval before starting implementation.

## 20. Approved migration clarifications

The following requirements supplement every earlier migration recommendation:

1. Preserve the existing feature-first Flutter architecture, including Riverpod providers/controllers/repositories and GoRouter routes. Preserve all active marketplace functionality, including public browse/detail, provider listing management, admin moderation, favorites, chat, auth, and profile behavior.
2. Do not replace or create an alternate application shell. The uncommitted Todos starter is not part of the target architecture and must not be used as a migration scaffold.
3. Preserve every existing local change. Do not use `git reset`, `git checkout`, `git restore`, or other destructive worktree commands. The local changes must be inspected and reconciled by small, reviewable edits.
4. Restoration of the original marketplace bootstrap is separate from database migration. No bootstrap restoration will be applied until the exact proposed diff is reviewed and approved.
5. Preserve Firebase profile data, roles, account statuses, listing moderation and approval state, search behavior, favorites, and chat data. Verify source data before and after migration.
6. Keep Firebase dependencies and configuration available throughout the transition. Firebase Auth/Firestore remain rollback sources until Supabase migration acceptance. FCM may remain independently as a push service.
7. PostgreSQL full-text search is required. It must operate alongside compatible prefix matching so title/category/area and sort/filter behavior remain stable. Search parity tests must include accent/case/whitespace, short prefixes, category/area intersections, empty and multi-term searches, no-result searches, newest/price sorting, and cursor boundaries.
8. Existing role-request records and review metadata are preserved. Role and moderation approval operations must run through trusted server-side operations and must remain inaccessible to ordinary Flutter clients.
9. Existing external image URLs remain valid during migration. Supabase Storage is implemented separately. Only verified Firebase Storage objects or explicitly confirmed source objects are copied; URL-only records are not assumed to be storage objects.
10. Imported Firebase `admin` profile values do not automatically become Supabase administrators. Effective admin authorization requires a separate trusted bootstrap/explicit allowlist and must be logged/audited.
11. Categories and areas remain unseeded until reviewed Firestore exports are supplied and approved. Existing code defaults are fallback UI values only and are not migration evidence.
12. Select and test a stable compatible `supabase_flutter` release before implementation. The v2/v3 migration implications must be evaluated without unrelated dependency upgrades.
13. RLS must be implemented and tested for profiles, listings, role requests, favorites, chat, and storage before application tables/buckets are exposed to Flutter writes.
14. Automated coverage must include auth/session/profile, listing CRUD/moderation, favorites, chat, storage, and authorization/privilege restrictions.
15. Ratings, reports, and payments remain outside the initial migration scope. Existing relevant records are inventoried and exported for later phases rather than silently discarded.

## 21. Phase 0 implementation plan

### Phase 0 outcome

Phase 0 is limited to controlled source restoration planning and baseline verification. It does not create SQL, connect to a database, run an export/import, change Firebase code/dependencies, or modify application functionality.

### 21.1 Complete uncommitted-change inventory

| Worktree item | Purpose observed | Phase 0 disposition |
|---|---|---|
| `lib/main.dart` | Replaces Firebase initialization, Riverpod `ProviderScope`, app export, and marketplace startup with `Supabase.initialize` and `runApp(MyApp())`; the URL/publishable key and Todos imports are starter-code changes. | Preserve until the user-approved bootstrap restoration diff is applied. Restore only the controlled marketplace bootstrap portion, not through a reset or checkout. |
| `lib/app.dart` | Removes Flutter/Riverpod imports, `AruaCityFinderApp`, `MaterialApp.router`, app theme, and GoRouter; replaces the application shell with `MyApp`/`HomePage` and a `.from('todos').select()` query. | Preserve for review. Restore the original marketplace app widget in a separate controlled edit. |
| `pubspec.yaml` | Adds `supabase_flutter: ^2.18.3` while retaining all Firebase dependencies. | Preserve. No package-upgrade or removal action in Phase 0. Select/test a stable SDK version later under approval. |
| `pubspec.lock` | Resolves the new Supabase v2 dependency graph, including `supabase`, `supabase_flutter`, `gotrue`, `postgrest`, `realtime_client`, `storage_client`, `functions_client`, app-link packages, and their transitive dependencies. | Preserve exactly. Do not refresh or regenerate it as part of restoration. |
| `linux/flutter/generated_plugin_registrant.cc` | Adds generated Linux registrations for `app_links_linux`. | Preserve until an SDK regeneration is performed by Flutter tooling after approval; generated file is a consequence of the manifest/local package resolution. |
| `linux/flutter/generated_plugins.cmake` | Adds `app_links_linux` to the generated Linux plugin list. | Preserve; generated artifact. |
| `linux/flutter/generated_plugin_registrant.h` | Modified generated/header state detected by Git, likely line-ending/generated synchronization. | Inspect and preserve unless Flutter tooling shows a meaningful plugin change after the approved package state is established. |
| `macos/Flutter/GeneratedPluginRegistrant.swift` | Adds `app_links` registration and reorders existing Firebase/plugin registration blocks. | Preserve until a controlled package/Flutter regeneration. |
| `windows/flutter/generated_plugin_registrant.cc` | Adds `app_links` registration and reorders existing Windows Firebase/plugin registrations. | Preserve until a controlled package/Flutter regeneration. |
| `windows/flutter/generated_plugins.cmake` | Adds `app_links` and reorders the existing plugin list. | Preserve; generated artifact. |
| `.agents/` | Pre-existing local agent skill files, including Supabase Postgres best-practice references. | Not application source. Preserve and do not edit or delete. |
| `.goose/` | Pre-existing local tooling state, purpose inferred only from directory presence. | Not application source. Preserve and do not inspect as application functionality. |
| `skills-lock.json` | Local skills lock metadata. | Tooling metadata. Preserve and do not modify in Phase 0. |
| `docs/SUPABASE_MIGRATION_AUDIT.md` | Migration planning document created during this task. | Intended deliverable. Continue updating as audit only. |

No tracked Firebase source, security rules, repository, provider, route, or model file is modified in the current worktree. The app-entry and dependency/generated-registration changes are the only source/dependency modifications found.

### 21.2 Exact files for controlled bootstrap restoration

The proposal is limited to one restore and, if necessary, a small supporting file correction:

1. [lib/main.dart](<C:/Users/User/Documents/PROGRAMMING PROJECTS/Arua-rentals/lib/main.dart>) — replace the local Todos/Supabase bootstrap with the checked-in Firebase bootstrap:
   - import `firebase_core`;
   - import Flutter, Riverpod, `app.dart`, and `firebase_options.dart`;
   - keep `export 'app.dart' show AruaCityFinderApp`;
   - ensure Flutter bindings;
   - initialize Firebase using `DefaultFirebaseOptions.currentPlatform`;
   - retain the Firebase App Check TODO;
   - run `ProviderScope` with `AruaCityFinderApp`.
2. [lib/app.dart](<C:/Users/User/Documents/PROGRAMMING PROJECTS/Arua-rentals/lib/app.dart>) — replace the local starter widget with the checked-in original:
   - Flutter and Riverpod imports;
   - app router and theme imports;
   - `AruaCityFinderApp` as a `ConsumerWidget`;
   - `MaterialApp.router` with debug banner disabled, `Arua City Finder`, `AppTheme.light`, and `appRouterProvider`.
3. No repository/provider/listing/auth/chat/favorites/admin files change in this task.
4. No Firebase dependency or generated platform configuration is removed.
5. The existing `supabase_flutter` manifest/lock additions and generated app-link plugin registrations remain present unless a later approved package decision requires otherwise.
6. The two proposed file changes are to be shown as a patch for review before application. No execution occurs as part of this plan.

### 21.3 Safe restoration approach

Use an explicit patch or controlled text edit of only `lib/main.dart` and `lib/app.dart`, preserving everything else:

- Do not use `git reset --hard`, `git reset --mixed`, `git checkout --`, `git restore`, or file deletion.
- Capture a pre-restoration status/diff for `main.dart`, `app.dart`, `pubspec.yaml`, `pubspec.lock`, and generated registration files.
- Apply the minimal two-file patch that restores the original exports, Firebase bootstrap, Riverpod scope, router, and theme. Do not reimplement or rename the app shell.
- Preserve the `supabase_flutter` dependency and lock entries. Do not run a package upgrade or dependency removal during restoration.
- If generated plugin files are stale after the package state changes, let Flutter tooling regenerate only those generated files and review the resulting diff; do not manually reconcile source logic in generated files.
- Re-run status/diff immediately and verify no file outside the approved scope changed.

### 21.4 Proposed Phase 0 diff review

The intended conceptual diff is:

```diff
// lib/main.dart
-import the Supabase-only starter/bootstrap code
+import firebase_core, flutter, riverpod
+import app.dart and firebase_options.dart
+export app.dart show AruaCityFinderApp
+ensure Flutter bindings
+initialize Firebase
+run ProviderScope(AruaCityFinderApp)

// lib/app.dart
-remove Todos starter and Supabase todos query
+restore the original AruaCityFinderApp ConsumerWidget
+restore MaterialApp.router
+restore AppTheme.light
+restore appRouterProvider
```

The exact line-by-line patch must be reviewed separately before application.

### 21.5 Verification commands

After approval and controlled restoration, run from the repository root:

```powershell
git status --short
git diff --stat
git diff -- lib/main.dart lib/app.dart
git diff --check
flutter pub get
flutter analyze
flutter test
```

For repository comparison and no-local-regression confirmation:

```powershell
git diff --stat HEAD
git diff --name-status HEAD
git diff --exit-code -- \
  lib/features lib/core lib/services lib/screens lib/models \
  firestore.rules firestore.indexes.json tests test pubspec.yaml
```

PowerShell should be used instead of shell-only `&&`; combine only when the next command should depend on the prior command. Do not run Firebase emulator or Supabase database commands in Phase 0.

### 21.6 Expected Phase 0 results

After restoring only the original bootstrap:

- `lib/main.dart` defines initialized Firebase startup plus `ProviderScope`.
- `lib/app.dart` exports `AruaCityFinderApp` and restores `MaterialApp.router`.
- No feature-first repository, provider, route, model, security rule, or test file is expected to change.
- `flutter pub get` should retain the existing Supabase dependency while keeping Firebase dependencies; lock resolution may add package transitive state but must not produce unrelated direct package upgrades.
- `flutter analyze` should return to the clean-`HEAD` baseline of 42 diagnostics when the worktree otherwise remains as inspected. Baseline diagnostics are existing SDK/deprecation findings, not this app-feature implementation.
- `flutter test` should pass all 37 tests, including `test/widget_test.dart`.
- `git diff --check` should pass.
- Status should still show the preserved Supabase manifest/lock/generated-registration changes plus any approved/explicit bootstrap diff. No reset or loss of local work should occur.

If these exact baseline results are not reproduced, stop and compare the two-file diff before making unrelated fixes. Current analyzer/test failures are not an invitation for broad refactoring.

### 21.7 Phase 0 non-goals and stop conditions

Do not proceed in Phase 0 if:

- exact bootstrap code cannot be shown in a patch before application;
- restoring one of the two files would remove or overwrite unrelated local content;
- package resolution proposes unrelated direct dependency upgrades;
- a database, export, secret, or migration tool is requested or required;
- the expected 37-test result or clean-HEAD analyzer baseline is not reached after a minimal bootstrap patch.

This Phase 0 plan is for review only and has not been executed.
