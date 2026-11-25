-- 02_rls_policy_audit.sql
-- Arua Rentals Supabase read-only RLS/policy audit.
-- READ ONLY: SELECT/catalog inspection only.

-- =========================
-- 1) RLS enabled status
-- =========================
with target_tables(table_name) as (
  values ('profiles'), ('listings'), ('listing_images'), ('categories'), ('areas'), ('role_requests')
)
select
  tt.table_name,
  c.relrowsecurity as rls_enabled,
  c.relforcerowsecurity as rls_forced,
  case when c.oid is null then 'FAIL'
       when c.relrowsecurity then 'PASS'
       else 'FAIL' end as status
from target_tables tt
left join pg_class c on c.relname = tt.table_name
left join pg_namespace n on n.oid = c.relnamespace and n.nspname = 'public'
order by tt.table_name;

-- =========================
-- 2) Policies for target tables
-- =========================
select
  schemaname,
  tablename,
  policyname,
  permissive,
  roles,
  cmd,
  qual as using_expression,
  with_check as with_check_expression,
  'INFO' as status
from pg_policies
where schemaname = 'public'
  and tablename in ('profiles','listings','listing_images','categories','areas','role_requests')
order by tablename, cmd, policyname;

-- =========================
-- 3) Required policy presence (expected by repo/manual scripts)
-- =========================
with required_policies(tablename, policyname, cmd) as (
  values
    ('profiles','profiles_owner_select','SELECT'),
    ('profiles','profiles_owner_update','UPDATE'),
    ('categories','categories_public_select','SELECT'),
    ('areas','areas_public_select','SELECT'),
    ('listings','listings_public_select','SELECT'),
    ('listings','listings_owner_select','SELECT'),
    ('listings','listings_admin_select','SELECT'),
    ('listings','listings_owner_insert','INSERT'),
    ('listings','listings_admin_insert','INSERT'),
    ('listings','listings_owner_update','UPDATE'),
    ('listings','listings_admin_update','UPDATE'),
    ('listings','listings_owner_delete','DELETE'),
    ('listings','listings_admin_delete','DELETE'),
    ('listing_images','listing_images_public_select','SELECT'),
    ('listing_images','listing_images_owner_manage','ALL'),
    ('role_requests','role_requests_owner_select','SELECT'),
    ('role_requests','role_requests_admin_select','SELECT'),
    ('role_requests','role_requests_owner_insert','INSERT')
)
select
  rp.tablename,
  rp.policyname,
  rp.cmd as expected_cmd,
  case when p.policyname is null then 'WARNING' else 'PASS' end as status,
  p.cmd as actual_cmd,
  p.roles,
  p.qual as using_expression,
  p.with_check as with_check_expression
from required_policies rp
left join pg_policies p
  on p.schemaname = 'public'
 and p.tablename = rp.tablename
 and p.policyname = rp.policyname
order by rp.tablename, rp.policyname;

-- Manual-script/admin/super-admin policy presence (context, not always required).
select
  tablename,
  policyname,
  cmd,
  roles,
  qual as using_expression,
  with_check as with_check_expression,
  case
    when tablename = 'categories' and policyname in ('categories_admin_manage','categories_super_admin_manage') then 'INFO'
    when tablename = 'areas' and policyname in ('areas_admin_manage','areas_super_admin_manage') then 'INFO'
    when tablename = 'listing_images' and policyname like 'listing_images_admin_%' then 'INFO'
    else 'INFO'
  end as status
from pg_policies
where schemaname = 'public'
  and (
    (tablename in ('categories','areas') and policyname in ('categories_admin_manage','categories_super_admin_manage'))
    or (tablename = 'listing_images' and policyname like 'listing_images_admin_%')
  )
order by tablename, policyname;

-- =========================
-- 4) Duplicate/overlapping permissive policies
-- =========================
-- Permissive policies for same table/role/cmd combine with OR. This can be intended
-- (owner OR admin) or risky (accidental extra permissive policy). Review manually.
with policy_roles as (
  select
    p.schemaname,
    p.tablename,
    p.policyname,
    p.permissive,
    p.cmd,
    p.qual,
    p.with_check,
    trim(role_name) as role_name
  from pg_policies p
  cross join lateral unnest(p.roles) as role_name
  where p.schemaname = 'public'
    and p.tablename in ('profiles','listings','listing_images','categories','areas','role_requests')
)
select
  tablename,
  role_name,
  cmd,
  count(*) as permissive_policy_count,
  string_agg(policyname, ', ' order by policyname) as policies,
  case
    when count(*) > 1 then 'WARNING'
    else 'PASS'
  end as status
from policy_roles
where permissive = 'PERMISSIVE'
group by tablename, role_name, cmd
having count(*) > 1
order by tablename, role_name, cmd;

-- =========================
-- 5) Listings RLS sanity checks
-- =========================
-- Owner insert should require owner auth, pending status, and landlord/provider role.
select
  policyname,
  cmd,
  roles,
  qual as using_expression,
  with_check as with_check_expression,
  case when with_check ilike '%owner_id%' and with_check ilike '%auth.uid()%'
       then 'PASS' else 'WARNING' end as owner_check_status,
  case when with_check ilike '%pending%' then 'PASS' else 'WARNING' end as pending_check_status,
  case when with_check ilike '%landlord%' and with_check ilike '%provider%'
       then 'PASS' else 'WARNING' end as role_check_status
from pg_policies
where schemaname='public' and tablename='listings' and policyname='listings_owner_insert';

-- Owner update should require owner and pending status.
select
  policyname,
  cmd,
  roles,
  qual as using_expression,
  with_check as with_check_expression,
  case when qual ilike '%owner_id%' and qual ilike '%auth.uid()%'
       then 'PASS' else 'WARNING' end as owner_using_status,
  case when with_check ilike '%owner_id%' and with_check ilike '%auth.uid()%'
       then 'PASS' else 'WARNING' end as owner_check_status,
  case when with_check ilike '%pending%' then 'PASS' else 'WARNING' end as pending_check_status
from pg_policies
where schemaname='public' and tablename='listings' and policyname='listings_owner_update';

-- Public listing reads should be limited to approved listings.
select
  policyname,
  cmd,
  roles,
  qual as using_expression,
  case when qual ilike '%status%approved%' then 'PASS' else 'WARNING' end as approved_only_status
from pg_policies
where schemaname='public' and tablename='listings' and policyname='listings_public_select';
