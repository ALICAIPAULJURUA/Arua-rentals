-- 01_database_audit.sql
-- Arua Rentals Supabase read-only database audit.
-- READ ONLY: uses SELECT/catalog inspection only. Do not run in a transaction that
-- includes writes. Safe to run in Supabase SQL Editor as-is.

-- =========================
-- 1) Required tables/columns
-- =========================
with required_tables(table_name) as (
  values
    ('profiles'),
    ('categories'),
    ('areas'),
    ('listings'),
    ('listing_images'),
    ('role_requests'),
    ('favorites'),
    ('chat_rooms'),
    ('chat_messages'),
    ('chat_message_reads'),
    ('firebase_user_mappings')
)
select
  rt.table_name,
  case when t.table_name is null then 'FAIL' else 'PASS' end as status,
  coalesce(t.table_type, 'missing') as table_type
from required_tables rt
left join information_schema.tables t
  on t.table_schema = 'public'
 and t.table_name = rt.table_name
order by rt.table_name;

-- Required columns (expected by repo/schema/manual scripts).
with required_columns(table_name, column_name) as (
  values
    ('profiles','id'), ('profiles','full_name'), ('profiles','email'), ('profiles','phone'),
    ('profiles','avatar_url'), ('profiles','role'), ('profiles','is_verified'),
    ('profiles','account_status'), ('profiles','created_at'), ('profiles','updated_at'),
    ('categories','id'), ('categories','name'), ('categories','slug'),
    ('categories','is_active'), ('categories','sort_order'),
    ('areas','id'), ('areas','name'), ('areas','slug'),
    ('areas','is_active'), ('areas','sort_order'),
    ('listings','id'), ('listings','owner_id'), ('listings','owner_name'), ('listings','owner_phone'),
    ('listings','type'), ('listings','category_id'), ('listings','area_id'),
    ('listings','title'), ('listings','title_lower'), ('listings','description'),
    ('listings','price_ugx'), ('listings','price_unit'), ('listings','address'),
    ('listings','latitude'), ('listings','longitude'), ('listings','bedrooms'),
    ('listings','bathrooms'), ('listings','amenities'), ('listings','thumbnail_url'),
    ('listings','video_url'), ('listings','status'), ('listings','rejection_reason'),
    ('listings','rating_avg'), ('listings','rating_count'), ('listings','search_prefixes'),
    ('listings','is_featured'), ('listings','owner_verified'), ('listings','created_at'),
    ('listings','updated_at'),
    ('listing_images','id'), ('listing_images','listing_id'), ('listing_images','image_url'),
    ('listing_images','storage_path'), ('listing_images','display_order'), ('listing_images','created_at')
)
select
  rc.table_name,
  rc.column_name,
  case when c.column_name is null then 'FAIL' else 'PASS' end as status,
  c.data_type,
  c.is_nullable,
  c.column_default
from required_columns rc
left join information_schema.columns c
  on c.table_schema = 'public'
 and c.table_name = rc.table_name
 and c.column_name = rc.column_name
order by rc.table_name, rc.column_name;

-- =========================
-- 2) Primary keys
-- =========================
select
  tc.table_name,
  kcu.column_name,
  kcu.ordinal_position,
  'PASS' as status
from information_schema.table_constraints tc
join information_schema.key_column_usage kcu
  on tc.constraint_name = kcu.constraint_name
 and tc.table_schema = kcu.table_schema
where tc.table_schema = 'public'
  and tc.constraint_type = 'PRIMARY KEY'
  and tc.table_name in ('profiles','categories','areas','listings','listing_images','role_requests','favorites','chat_rooms')
order by tc.table_name, kcu.ordinal_position;

-- =========================
-- 3) Foreign keys
-- =========================
select
  tc.table_name,
  kcu.column_name,
  ccu.table_name as referenced_table,
  ccu.column_name as referenced_column,
  rc.update_rule,
  rc.delete_rule,
  'INFO' as status
from information_schema.table_constraints tc
join information_schema.key_column_usage kcu
  on tc.constraint_name = kcu.constraint_name
 and tc.table_schema = kcu.table_schema
join information_schema.referential_constraints rc
  on rc.constraint_name = tc.constraint_name
 and rc.constraint_schema = tc.table_schema
join information_schema.constraint_column_usage ccu
  on ccu.constraint_name = rc.unique_constraint_name
 and ccu.constraint_schema = rc.unique_constraint_schema
where tc.table_schema = 'public'
  and tc.constraint_type = 'FOREIGN KEY'
  and tc.table_name in ('listings','listing_images','role_requests','favorites','chat_rooms','chat_messages','chat_message_reads','profiles')
order by tc.table_name, kcu.column_name;

-- =========================
-- 4) Functions and signatures
-- =========================
select
  n.nspname as schema_name,
  p.proname as function_name,
  pg_get_function_identity_arguments(p.oid) as identity_args,
  case p.prosecdef when true then 'SECURITY_DEFINER' else 'SECURITY_INVOKER' end as security_mode,
  p.provolatile as volatility,
  pg_get_function_result(p.oid) as result_type,
  p.proconfig as function_settings,
  has_function_privilege('anon', p.oid, 'EXECUTE') as anon_can_execute,
  has_function_privilege('authenticated', p.oid, 'EXECUTE') as authenticated_can_execute,
  has_function_privilege('public', p.oid, 'EXECUTE') as public_can_execute,
  'INFO' as status
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname in ('public','private')
order by n.nspname, p.proname, identity_args;

-- =========================
-- 5) Required RPC functions
-- =========================
with required_rpcs(function_name, identity_args) as (
  values
    ('replace_listing_images', 'uuid, jsonb'),
    ('update_listing_with_images', 'uuid, jsonb, jsonb')
)
select
  rr.function_name,
  rr.identity_args as expected_identity_args,
  case when p.oid is null then 'FAIL' else 'PASS' end as exists_status,
  case when p.prosecdef is false then 'PASS'
       when p.prosecdef is true then 'WARNING'
       when p.oid is null then 'FAIL'
       else 'NOT_VERIFIED' end as security_mode_status,
  case p.prosecdef when true then 'SECURITY_DEFINER' when false then 'SECURITY_INVOKER' else null end as security_mode,
  has_function_privilege('anon', p.oid, 'EXECUTE') as anon_can_execute,
  has_function_privilege('authenticated', p.oid, 'EXECUTE') as authenticated_can_execute,
  has_function_privilege('public', p.oid, 'EXECUTE') as public_can_execute,
  case
    when p.oid is null then 'FAIL'
    when has_function_privilege('anon', p.oid, 'EXECUTE') then 'FAIL'
    when has_function_privilege('public', p.oid, 'EXECUTE') then 'FAIL'
    when has_function_privilege('authenticated', p.oid, 'EXECUTE') then 'PASS'
    else 'WARNING'
  end as privilege_status,
  p.proconfig as function_settings
from required_rpcs rr
left join pg_proc p
  on p.proname = rr.function_name
 and pg_get_function_identity_arguments(p.oid) = rr.identity_args
 and p.pronamespace = 'public'::regnamespace
order by rr.function_name;

-- Optional: full function definitions for required RPCs (review manually; read-only).
select
  n.nspname as schema_name,
  p.oid::regprocedure as function_name,
  case p.prosecdef when true then 'SECURITY_DEFINER' else 'SECURITY_INVOKER' end as security_mode,
  p.proconfig as function_settings,
  pg_get_functiondef(p.oid) as function_definition
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('replace_listing_images','update_listing_with_images')
order by p.proname;

-- =========================
-- 6) Triggers (focus: listings)
-- =========================
select
  c.relname as table_name,
  t.tgname as trigger_name,
  pg_get_triggerdef(t.oid, true) as trigger_definition,
  case when t.tgenabled = 'O' then 'enabled' else t.tgenabled::text end as enabled_state,
  'INFO' as status
from pg_trigger t
join pg_class c on c.oid = t.tgrelid
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and not t.tgisinternal
  and c.relname in ('listings','listing_images','profiles','categories','areas','role_requests')
order by c.relname, t.tgname;

-- Required listing protection triggers (expected by repo/manual scripts).
with required_triggers(table_name, trigger_name) as (
  values
    ('listings','listings_set_updated_at'),
    ('listings','listings_protect_owner_fields'),
    ('listings','listings_refresh_search')
)
select
  rt.table_name,
  rt.trigger_name,
  case when t.oid is null then 'FAIL' else 'PASS' end as status,
  pg_get_triggerdef(t.oid, true) as trigger_definition
from required_triggers rt
left join pg_trigger t
  on t.tgname = rt.trigger_name
 and t.tgrelid = ('public.' || rt.table_name)::regclass
 and not t.tgisinternal
order by rt.table_name, rt.trigger_name;

-- Inspect protect_listing_owner_fields function for INSERT handling.
select
  p.oid::regprocedure as function_name,
  case when pg_get_functiondef(p.oid) ilike '%TG_OP = ''INSERT''%' then 'PASS' else 'WARNING' end as handles_insert_status,
  case when pg_get_functiondef(p.oid) ilike '%status := ''pending''%' then 'PASS' else 'WARNING' end as insert_pending_status,
  case when pg_get_functiondef(p.oid) ilike '%owner_verified%' then 'PASS' else 'WARNING' end as owner_verified_handling_status,
  pg_get_functiondef(p.oid) as function_definition
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'private'
  and p.proname = 'protect_listing_owner_fields';
