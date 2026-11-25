-- 03_storage_audit.sql
-- Arua Rentals Supabase read-only storage audit.
-- READ ONLY: SELECT/catalog inspection only.

-- =========================
-- 1) Bucket configuration
-- =========================
with expected_buckets(bucket_id, expected_public, expected_size_limit, expected_mime_types) as (
  values
    ('listing-images', false, 6291456, array['image/jpeg','image/png','image/webp']::text[]),
    ('listing-videos', false, 52428800, array['video/mp4','video/webm']::text[]),
    ('avatars', false, null::integer, null::text[])
)
select
  eb.bucket_id,
  case when b.id is null then 'FAIL' else 'PASS' end as exists_status,
  b.public as actual_public,
  case when b.id is null then 'FAIL'
       when b.public = eb.expected_public then 'PASS'
       else 'FAIL' end as public_status,
  b.file_size_limit as actual_file_size_limit,
  case when eb.expected_size_limit is null then 'NOT_VERIFIED'
       when b.file_size_limit = eb.expected_size_limit then 'PASS'
       when b.id is null then 'FAIL'
       else 'WARNING' end as size_limit_status,
  b.allowed_mime_types as actual_allowed_mime_types,
  case when eb.expected_mime_types is null then 'NOT_VERIFIED'
       when b.allowed_mime_types @> eb.expected_mime_types and eb.expected_mime_types @> b.allowed_mime_types then 'PASS'
       when b.id is null then 'FAIL'
       else 'WARNING' end as mime_type_status,
  eb.expected_public,
  eb.expected_size_limit,
  eb.expected_mime_types
from expected_buckets eb
left join storage.buckets b on b.id = eb.bucket_id
order by eb.bucket_id;

-- =========================
-- 2) All storage.objects policies (review for unexpected permissive policies)
-- =========================
select
  policyname,
  permissive,
  roles,
  cmd,
  qual as using_expression,
  with_check as with_check_expression,
  case
    when coalesce(qual,'') ilike '%bucket_id = ''listing-images''%'
      or coalesce(with_check,'') ilike '%bucket_id = ''listing-images''%'
      or coalesce(qual,'') ilike '%bucket_id = ''listing-videos''%'
      or coalesce(with_check,'') ilike '%bucket_id = ''listing-videos''%'
      then 'INFO'
    else 'REVIEW'
  end as relevance
from pg_policies
where schemaname = 'storage'
  and tablename = 'objects'
order by policyname;

-- =========================
-- 3) Expected listing-images policies
-- =========================
with expected(policyname, cmd) as (
  values
    ('listing_images_public_read','SELECT'),
    ('listing_images_owner_read','SELECT'),
    ('listing_images_admin_read','SELECT'),
    ('listing_images_owner_insert','INSERT'),
    ('listing_images_admin_insert','INSERT'),
    ('listing_images_owner_update','UPDATE'),
    ('listing_images_admin_update','UPDATE'),
    ('listing_images_owner_delete','DELETE'),
    ('listing_images_admin_delete','DELETE')
)
select
  e.policyname,
  e.cmd as expected_cmd,
  case when p.policyname is null then 'WARNING' else 'PASS' end as exists_status,
  p.roles,
  p.cmd as actual_cmd,
  p.qual as using_expression,
  p.with_check as with_check_expression
from expected e
left join pg_policies p
  on p.schemaname='storage' and p.tablename='objects' and p.policyname=e.policyname
order by e.policyname;

-- =========================
-- 4) Expected listing-videos policies
-- =========================
with expected(policyname, cmd) as (
  values
    ('listing_videos_public_read','SELECT'),
    ('listing_videos_owner_read','SELECT'),
    ('listing_videos_admin_read','SELECT'),
    ('listing_videos_owner_insert','INSERT'),
    ('listing_videos_admin_insert','INSERT'),
    ('listing_videos_owner_update','UPDATE'),
    ('listing_videos_admin_update','UPDATE'),
    ('listing_videos_owner_delete','DELETE'),
    ('listing_videos_admin_delete','DELETE')
)
select
  e.policyname,
  e.cmd as expected_cmd,
  case when p.policyname is null then 'FAIL' else 'PASS' end as exists_status,
  p.roles,
  p.cmd as actual_cmd,
  p.qual as using_expression,
  p.with_check as with_check_expression
from expected e
left join pg_policies p
  on p.schemaname='storage' and p.tablename='objects' and p.policyname=e.policyname
order by e.policyname;

-- =========================
-- 5) Ownership/media-reference validation checks
-- =========================
-- PASS means policy text contains expected ownership/reference checks; WARNING means review manually.
select
  policyname,
  cmd,
  case when coalesce(qual,'') ilike '%listing_images%' or coalesce(with_check,'') ilike '%listing_images%'
       then 'PASS' else 'WARNING' end as references_listing_images_table,
  case when coalesce(qual,'') ilike '%storage_path = storage.objects.name%' or coalesce(with_check,'') ilike '%storage_path = storage.objects.name%'
       then 'PASS' else 'WARNING' end as validates_storage_path_reference,
  case when coalesce(qual,'') ilike '%owner_id = (select auth.uid())%' or coalesce(with_check,'') ilike '%owner_id = (select auth.uid())%'
       then 'PASS' else 'WARNING' end as validates_owner_id,
  qual as using_expression,
  with_check as with_check_expression
from pg_policies
where schemaname='storage' and tablename='objects'
  and policyname like 'listing_images_%'
order by policyname;

select
  policyname,
  cmd,
  case when coalesce(qual,'') ilike '%video_url = storage.objects.name%' or coalesce(with_check,'') ilike '%video_url = storage.objects.name%'
       then 'PASS' else 'WARNING' end as validates_video_reference,
  case when coalesce(qual,'') ilike '%owner_id = (select auth.uid())%' or coalesce(with_check,'') ilike '%owner_id = (select auth.uid())%'
       then 'PASS' else 'WARNING' end as validates_owner_id,
  case when coalesce(qual,'') ilike '%status%approved%' or coalesce(with_check,'') ilike '%status%approved%'
       then 'PASS' else 'NOT_APPLICABLE' end as approved_check_status,
  qual as using_expression,
  with_check as with_check_expression
from pg_policies
where schemaname='storage' and tablename='objects'
  and policyname like 'listing_videos_%'
order by policyname;

-- Folder-name-only risk heuristic (review manually).
select
  policyname,
  cmd,
  roles,
  case
    when (coalesce(qual,'') ilike '%foldername%' or coalesce(with_check,'') ilike '%foldername%')
     and coalesce(qual,'') not ilike '%listing_images%'
     and coalesce(qual,'') not ilike '%video_url = storage.objects.name%'
     and coalesce(with_check,'') not ilike '%listing_images%'
     and coalesce(with_check,'') not ilike '%video_url = storage.objects.name%'
    then 'WARNING'
    else 'PASS'
  end as folder_only_heuristic,
  qual as using_expression,
  with_check as with_check_expression
from pg_policies
where schemaname='storage' and tablename='objects'
  and (policyname like 'listing_images_%' or policyname like 'listing_videos_%')
order by policyname;

-- =========================
-- 6) Overlapping permissive storage policies for listing buckets
-- =========================
with policy_roles as (
  select
    p.policyname,
    p.permissive,
    p.cmd,
    trim(role_name) as role_name,
    coalesce(p.qual,'') || ' ' || coalesce(p.with_check,'') as policy_text
  from pg_policies p
  cross join lateral unnest(p.roles) as role_name
  where p.schemaname='storage' and p.tablename='objects'
)
select
  case
    when policy_text ilike '%listing-images%' then 'listing-images'
    when policy_text ilike '%listing-videos%' then 'listing-videos'
    else 'other'
  end as bucket_scope,
  role_name,
  cmd,
  count(*) as permissive_policy_count,
  string_agg(policyname, ', ' order by policyname) as policies,
  case when count(*) > 1 then 'WARNING' else 'PASS' end as status
from policy_roles
where permissive='PERMISSIVE'
  and (policy_text ilike '%listing-images%' or policy_text ilike '%listing-videos%')
group by 1, role_name, cmd
having count(*) > 1
order by bucket_scope, role_name, cmd;
