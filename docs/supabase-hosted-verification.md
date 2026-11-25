# Hosted Supabase verification

The configured Supabase project is the existing production project. Both
`supabase/manual/secure_listing_insert_fields.sql` and
`supabase/manual/seed_listing_options.sql` have already been applied there.
**Do not rerun either script.** This document describes read-only checks and a
separately gated test suite; do not run the hosted suite until the project owner
has explicitly approved its production writes, deletions, and email requests.

## Read-only project checks

`supabase.local.json` is local configuration. Keep it untracked and never copy
its contents into logs, source control, or chat. The application reads
`SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY` through
`SupabaseConfig`; its URL parser accepts the project origin and the `/rest/v1`
form. The auth redirect is `aruacityfinder://auth/callback`.

The public Data API can confirm that a table route is exposed, but cannot
enumerate PostgreSQL RLS policies or prove that a hidden row exists. To inspect
the production database without changing data, open **Dashboard → SQL Editor →
New query** and run these queries individually.

### Application-table RLS

Lists regular and partitioned tables in the application (`public`) and Storage
(`storage`) schemas, including whether row-level security is enabled or forced.
```sql
select n.nspname as schema_name, c.relname as table_name,
       c.relrowsecurity as rls_enabled, c.relforcerowsecurity as rls_forced
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname in ('public', 'storage')
  and c.relkind in ('r', 'p')
order by n.nspname, c.relname;
```

### RLS policies

Shows every policy on tables in `public` and `storage`, its command and target
roles, and the `USING` (`qual`) and `WITH CHECK` expressions.
```sql
select schemaname, tablename, policyname, permissive, roles, cmd, qual, with_check
from pg_policies
where schemaname in ('public', 'storage')
order by schemaname, tablename, policyname;
```

### Table grants and schema usage

Lists direct table privileges, including grants to `PUBLIC`, `anon`, and
`authenticated`. The second query checks schema `USAGE`, which is separate from
table privileges and matters for API access.
```sql
select table_schema, table_name, grantor, grantee, privilege_type, is_grantable
from information_schema.table_privileges
where table_schema in ('public', 'storage')
order by table_schema, table_name, grantee, privilege_type;
```

```sql
select schema_name, role_name,
       has_schema_privilege(role_name, schema_name, 'USAGE') as has_usage
from (values ('public'), ('storage'), ('private')) as schemas(schema_name)
cross join (values ('anon'), ('authenticated'), ('service_role')) as roles(role_name)
order by schema_name, role_name;
```

### Storage bucket configuration and policies

Shows the named bucket's visibility and upload constraints.
```sql
select id, name, public, file_size_limit, allowed_mime_types, created_at, updated_at
from storage.buckets
where id = 'listing-images';
```

Shows policies on Storage objects, including their `USING` and `WITH CHECK`
expressions. These are row-level policies for the `storage.objects` table.
```sql
select schemaname, tablename, policyname, permissive, roles, cmd, qual, with_check
from pg_policies
where schemaname = 'storage'
  and tablename in ('objects', 'buckets')
order by tablename, policyname;
```

### Application functions and security-definer settings

Lists functions and procedures in the application `public` and internal
`private` schemas, their owners, security-definer flag, function settings, and
definitions. Review the definitions of security-definer functions to confirm
they perform their own authorization checks and use a safe `search_path`.
```sql
select n.nspname as schema_name,
       p.proname as routine_name,
       pg_get_function_identity_arguments(p.oid) as identity_arguments,
       pg_get_userbyid(p.proowner) as owner,
       l.lanname as language,
       p.prosecdef as security_definer,
       p.proconfig as function_settings,
       pg_get_functiondef(p.oid) as definition
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
join pg_language l on l.oid = p.prolang
where n.nspname in ('public', 'private')
  and p.prokind in ('f', 'p')
order by n.nspname, p.proname, identity_arguments;
```

All queries above are `SELECT`-only and make no database changes. In
**Authentication → URL Configuration**,
verify `aruacityfinder://auth/callback` is in Redirect URLs. The redirect
allowlist is not returned by the public Auth settings endpoint.

## Hosted integration suite — production writes

The suite is disabled unless `RUN_SUPABASE_HOSTED_TESTS=true`. Before it signs
in or makes requests, it also requires:

- `SUPABASE_EXPECTED_PROJECT_HOST`: the exact production host
  (for example, `<project-ref>.supabase.co`), to prevent testing the wrong
  configured project.
- `SUPABASE_TEST_ACCOUNT_MARKER`: a marker of at least six characters present
  in the local part of every test account email. Use clearly marked, dedicated
  test accounts, never existing user accounts.
- `SUPABASE_HOSTED_TEST_WRITE_ACK=I_APPROVE_HOSTED_TEST_WRITES`, set only after
  explicitly approving the hosted writes and cleanup.
- Separate credentials for a dedicated landlord, second landlord, tenant,
  administrator, and a controlled signup mailbox that accepts plus-address
  aliases. The signup email is generated for each run by appending
  `+<marker>_hosted_<UTC-microseconds>` to the configured signup email's local
  part. Never use a service-role key.

Configure these only in a private local VS Code terminal/run configuration:

- `SUPABASE_TEST_LANDLORD_EMAIL` / `SUPABASE_TEST_LANDLORD_PASSWORD`
- `SUPABASE_TEST_SECOND_LANDLORD_EMAIL` /
  `SUPABASE_TEST_SECOND_LANDLORD_PASSWORD`
- `SUPABASE_TEST_TENANT_EMAIL` / `SUPABASE_TEST_TENANT_PASSWORD`
- `SUPABASE_TEST_ADMIN_EMAIL` / `SUPABASE_TEST_ADMIN_PASSWORD`
- `SUPABASE_TEST_NEW_USER_EMAIL` / `SUPABASE_TEST_NEW_USER_PASSWORD`
- `SUPABASE_TEST_ACCOUNT_MARKER`
- `SUPABASE_EXPECTED_PROJECT_HOST`
- `SUPABASE_HOSTED_TEST_WRITE_ACK`

The test administrator must have its trusted admin claim assigned by the
existing server-side process. Do not grant roles or edit claims from the client.
The environment value `SUPABASE_TEST_NEW_USER_EMAIL` is the base mailbox, not
the exact generated address. Use a provider that supports plus-addressing or
catch-all mail for that domain. Do not reuse the same run's generated address.

The following Windows PowerShell setup prompts for passwords and emails without
echoing them and stores values in this PowerShell process only. Do not enable
transcription or share the terminal transcript. The values still exist in
process memory while set.

```powershell
function Set-PrivateProcessValue {
    param([Parameter(Mandatory = $true)][string]$Name)

    $secure = Read-Host -Prompt $Name -AsSecureString
    $bstr = [IntPtr]::Zero
    $plain = $null
    try {
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        [Environment]::SetEnvironmentVariable($Name, $plain, 'Process')
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
        $plain = $null
        $secure.Dispose()
    }
}

$env:SUPABASE_EXPECTED_PROJECT_HOST = 'ruxbwidezpmyuzuvtpvx.supabase.co'
$env:SUPABASE_TEST_ACCOUNT_MARKER = Read-Host 'Marker in every dedicated test email local part'
Set-PrivateProcessValue SUPABASE_TEST_LANDLORD_EMAIL
Set-PrivateProcessValue SUPABASE_TEST_LANDLORD_PASSWORD
Set-PrivateProcessValue SUPABASE_TEST_SECOND_LANDLORD_EMAIL
Set-PrivateProcessValue SUPABASE_TEST_SECOND_LANDLORD_PASSWORD
Set-PrivateProcessValue SUPABASE_TEST_TENANT_EMAIL
Set-PrivateProcessValue SUPABASE_TEST_TENANT_PASSWORD
Set-PrivateProcessValue SUPABASE_TEST_ADMIN_EMAIL
Set-PrivateProcessValue SUPABASE_TEST_ADMIN_PASSWORD
Set-PrivateProcessValue SUPABASE_TEST_NEW_USER_EMAIL
Set-PrivateProcessValue SUPABASE_TEST_NEW_USER_PASSWORD

$config = Get-Content .\supabase.local.json -Raw | ConvertFrom-Json
$actualHost = ([Uri]$config.SUPABASE_URL).Host
if ($actualHost -ne $env:SUPABASE_EXPECTED_PROJECT_HOST) {
    throw 'Configured Supabase host does not match the expected production host.'
}
Write-Output "Supabase host check passed: $actualHost"
```

Do **not** set the write acknowledgement or run this command until production
write-test approval has been explicitly given:

```powershell
$env:SUPABASE_HOSTED_TEST_WRITE_ACK = 'I_APPROVE_HOSTED_TEST_WRITES'
flutter test --dart-define-from-file=supabase.local.json --dart-define=RUN_SUPABASE_HOSTED_TESTS=true test\supabase_hosted_integration_test.dart
```

### Exact hosted side effects

The suite is not read-only:

- Signs in the four dedicated accounts; makes one invalid-password attempt;
  sends a password-recovery request to the dedicated landlord account.
- Registers a uniquely marked address derived from the configured signup
  mailbox and its database-created profile. Email auto-confirm is disabled in
  the inspected project settings: the test requires a user with a null session
  and reads its profile using the dedicated administrator. It does not confirm
  the email or verify sign-in for that new user. The generated email is printed
  by the test so it can be identified for manual cleanup. The Auth user is
  **not** automatically deleted.
- After the run, find the exact generated address in **Dashboard →
  Authentication → Users**, confirm the marker and timestamp-like suffix, then
  delete only that signup test user. The profile's `id` references
  `auth.users(id) ON DELETE CASCADE` in the migration, so deleting this Auth
  user cascades to its profile. Do not delete by a broad email prefix or marker.
- Temporarily changes the dedicated landlord's profile name and restores it in
  `finally`; it queries the profile afterward to verify both original name and
  phone. A failed restoration is reported as a critical failure.
- Attempts protected-field changes. Each must either raise PostgreSQL
  authorization code `42501`, or affect zero rows with the original field
  value verified unchanged. If a change succeeds, it restores only that exact
  field on the dedicated landlord and reports a critical RLS failure.
- Attempts an unauthorized tenant listing insert with a cryptographically
  random ID and unique test title. It checks the ID was unused first. If the
  insert unexpectedly succeeds—or if the response is ambiguous—it looks up
  only that exact ID, tenant owner, and unique title, then tracks and deletes
  only a matching row. A `42501` rejection is required; any other result is
  reported as failure/inconclusive.
- Attempts another user's profile read and listing update. The cross-owner
  listing update verifies the test listing's title afterward; if it changed,
  the owner restores that exact test listing before the test reports a critical
  RLS failure.
- Attempts another landlord's Storage overwrite with different bytes and
  delete on the uploaded test object. An explicit Storage authorization error,
  or an empty delete result with the exact original bytes still present, counts
  as denied. If contents changed or the object disappeared, the landlord
  restores only that exact test-owned path before reporting a critical failure.
- Each hosted listing create supplies a cryptographically random UUID that is
  checked as unused and tracked before the insert request. This covers an
  insert that commits even if its response is lost. Each listing test has
  `finally` cleanup, plus test-teardown and suite-teardown retries. Cleanup
  deletes only tracked IDs that also match the expected owner and unique test
  title marker, and only Storage paths allocated beneath a newly created test
  listing. The Storage path is tracked before the upload request, so a response
  lost after the server stores an object can still be cleaned up. It then
  verifies those exact IDs and paths are absent. Cleanup failures are reported,
  not silently ignored.

Listing cleanup uses the dedicated administrator after verifying `id`,
`owner_id`, and the unique test-title prefix. No bulk delete, prefix-only
delete, or cleanup of pre-existing listings is performed. Review test output
and **Authentication → Users**, listings, and the `listing-images` bucket after
an approved run. If process termination, network loss, or cleanup authorization
failure prevents cleanup, use the test output's exact listing IDs and object
paths to inspect and remove only those confirmed test resources manually.

Clear the process-scoped values when finished:

```powershell
@(
  'SUPABASE_EXPECTED_PROJECT_HOST',
  'SUPABASE_TEST_ACCOUNT_MARKER',
  'SUPABASE_HOSTED_TEST_WRITE_ACK',
  'SUPABASE_TEST_LANDLORD_EMAIL',
  'SUPABASE_TEST_LANDLORD_PASSWORD',
  'SUPABASE_TEST_SECOND_LANDLORD_EMAIL',
  'SUPABASE_TEST_SECOND_LANDLORD_PASSWORD',
  'SUPABASE_TEST_TENANT_EMAIL',
  'SUPABASE_TEST_TENANT_PASSWORD',
  'SUPABASE_TEST_ADMIN_EMAIL',
  'SUPABASE_TEST_ADMIN_PASSWORD',
  'SUPABASE_TEST_NEW_USER_EMAIL',
  'SUPABASE_TEST_NEW_USER_PASSWORD'
) | ForEach-Object {
  [Environment]::SetEnvironmentVariable($_, $null, 'Process')
}
```

### Device-only checks

The Dart hosted suite does not exercise a native image picker or a true app
process restart. After the same explicit production-test approval, a dedicated
landlord can test image selection/upload, force-close/restart session restore,
and password reset on a device. These actions also write production data and
send email. Use only a dedicated test identity and remove only its own
test-created records after review. Local/mocked session tests are not hosted
device verification.
