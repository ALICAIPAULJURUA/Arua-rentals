-- 05_security_audit.sql
-- Arua Rentals Supabase read-only security audit.
-- READ ONLY: SELECT/catalog inspection only. No writes, no grants, no DDL.
-- Does not expose user/profile personal data.

-- =========================
-- 1) RLS enabled on sensitive tables
-- =========================
select
  n.nspname as schema_name,
  c.relname as table_name,
  c.relrowsecurity as rls_enabled,
  c.relforcerowsecurity as rls_forced,
  case when c.relrowsecurity then 'PASS' else 'FAIL' end as status
from pg_class c
join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public'
  and c.relkind='r'
  and c.relname in ('profiles','listings','listing_images','categories','areas','role_requests','favorites','chat_rooms','chat_messages','chat_message_reads','firebase_user_mappings')
order by c.relname;

-- =========================
-- 2) Excessive RPC/function privileges
-- =========================
select
  n.nspname as schema_name,
  p.proname as function_name,
  pg_get_function_identity_arguments(p.oid) as identity_args,
  case p.prosecdef when true then 'SECURITY_DEFINER' else 'SECURITY_INVOKER' end as security_mode,
  has_function_privilege('anon', p.oid, 'EXECUTE') as anon_can_execute,
  has_function_privilege('public', p.oid, 'EXECUTE') as public_can_execute,
  has_function_privilege('authenticated', p.oid, 'EXECUTE') as authenticated_can_execute,
  case
    when p.proname in ('replace_listing_images','update_listing_with_images')
      and (has_function_privilege('anon', p.oid, 'EXECUTE') or has_function_privilege('public', p.oid, 'EXECUTE'))
      then 'FAIL'
    when p.proname in ('replace_listing_images','update_listing_with_images')
      and has_function_privilege('authenticated', p.oid, 'EXECUTE')
      then 'PASS'
    when n.nspname='private' and (has_function_privilege('anon', p.oid, 'EXECUTE') or has_function_privilege('public', p.oid, 'EXECUTE'))
      then 'FAIL'
    else 'REVIEW'
  end as status
from pg_proc p
join pg_namespace n on n.oid=p.pronamespace
where n.nspname in ('public','private')
order by status desc, n.nspname, p.proname;

-- =========================
-- 3) Missing listing INSERT protection
-- =========================
select
  p.oid::regprocedure as function_name,
  case when pg_get_functiondef(p.oid) ilike '%TG_OP = ''INSERT''%' then 'PASS' else 'FAIL' end as handles_insert,
  case when pg_get_functiondef(p.oid) ilike '%status := ''pending''%' then 'PASS' else 'WARNING' end as forces_pending,
  case when pg_get_functiondef(p.oid) ilike '%rating_avg := 0%' and pg_get_functiondef(p.oid) ilike '%rating_count := 0%' then 'PASS' else 'WARNING' end as resets_aggregates,
  case when pg_get_functiondef(p.oid) ilike '%is_featured := false%' then 'PASS' else 'WARNING' end as resets_featured,
  case when pg_get_functiondef(p.oid) ilike '%owner_verified%' then 'PASS' else 'WARNING' end as sets_owner_verified_from_profile
from pg_proc p
join pg_namespace n on n.oid=p.pronamespace
where n.nspname='private' and p.proname='protect_listing_owner_fields';

select
  tg.tgname,
  pg_get_triggerdef(tg.oid, true) as trigger_definition,
  case when pg_get_triggerdef(tg.oid, true) ilike '%BEFORE INSERT OR UPDATE%' then 'PASS'
       when pg_get_triggerdef(tg.oid, true) ilike '%BEFORE UPDATE%' then 'WARNING'
       else 'REVIEW' end as status
from pg_trigger tg
join pg_class c on c.oid=tg.tgrelid
join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relname='listings' and not tg.tgisinternal
  and tg.tgname='listings_protect_owner_fields';

-- =========================
-- 4) Public/anon access to listing tables
-- =========================
-- Review any permissive policy granting broad anon/public access.
select
  tablename,
  policyname,
  roles,
  cmd,
  qual as using_expression,
  with_check as with_check_expression,
  case
    when tablename='listings' and policyname='listings_public_select' and qual ilike '%status%approved%' then 'PASS'
    when tablename='listing_images' and policyname='listing_images_public_select' and qual ilike '%approved%' then 'PASS'
    when 'anon' = any(roles) then 'WARNING'
    else 'PASS'
  end as status
from pg_policies
where schemaname='public'
  and tablename in ('listings','listing_images','profiles','categories','areas','role_requests')
order by tablename, policyname;

-- =========================
-- 5) Storage public access / private media exposure
-- =========================
select id, name, public, file_size_limit, allowed_mime_types,
  case when public then 'FAIL' else 'PASS' end as private_status
from storage.buckets
where id in ('listing-images','listing-videos','avatars')
order by id;

-- Storage policies that may expose media. Public read is acceptable only when
-- approved listing + referenced object checks are present.
select
  policyname,
  roles,
  cmd,
  qual as using_expression,
  with_check as with_check_expression,
  case
    when policyname in ('listing_images_public_read','listing_videos_public_read')
     and (coalesce(qual,'') ilike '%approved%' or coalesce(with_check,'') ilike '%approved%')
     and (coalesce(qual,'') ilike '%storage_path = storage.objects.name%' or coalesce(qual,'') ilike '%video_url = storage.objects.name%' or coalesce(with_check,'') ilike '%storage_path = storage.objects.name%' or coalesce(with_check,'') ilike '%video_url = storage.objects.name%')
     then 'PASS'
    when 'anon' = any(roles) then 'WARNING'
    else 'PASS'
  end as status
from pg_policies
where schemaname='storage' and tablename='objects'
  and (policyname like 'listing_images_%' or policyname like 'listing_videos_%' or 'anon' = any(roles))
order by policyname;

-- =========================
-- 6) Conflicting/overlapping permissive policies (RLS + storage)
-- =========================
with policy_roles as (
  select schemaname, tablename, policyname, permissive, cmd, trim(role_name) as role_name
  from pg_policies p
  cross join lateral unnest(p.roles) as role_name
  where (schemaname='public' and tablename in ('profiles','listings','listing_images','categories','areas','role_requests'))
     or (schemaname='storage' and tablename='objects')
)
select
  schemaname,
  tablename,
  role_name,
  cmd,
  count(*) as permissive_policy_count,
  string_agg(policyname, ', ' order by policyname) as policies,
  case when count(*) > 1 then 'WARNING' else 'PASS' end as status
from policy_roles
where permissive='PERMISSIVE'
group by schemaname, tablename, role_name, cmd
having count(*) > 1
order by schemaname, tablename, role_name, cmd;

-- =========================
-- 7) Ownership checks in key policies
-- =========================
select
  tablename,
  policyname,
  cmd,
  case
    when tablename='listings' and cmd in ('INSERT','UPDATE','DELETE','SELECT') and policyname like 'listings_owner_%'
      then case when coalesce(qual,'') ilike '%owner_id%auth.uid()%' or coalesce(with_check,'') ilike '%owner_id%auth.uid()%' then 'PASS' else 'FAIL' end
    when tablename='listing_images' and policyname='listing_images_owner_manage'
      then case when coalesce(qual,'') ilike '%owner_id%auth.uid()%' or coalesce(with_check,'') ilike '%owner_id%auth.uid()%' then 'PASS' else 'FAIL' end
    else 'NOT_APPLICABLE'
  end as ownership_check_status,
  qual as using_expression,
  with_check as with_check_expression
from pg_policies
where schemaname='public'
  and tablename in ('listings','listing_images')
  and policyname like '%owner_%'
order by tablename, policyname;
