-- Manual schema upgrade for distinct super-admin access.
-- Review before applying to the hosted project; this file is not executed here.

alter table public.profiles
  add column if not exists role_before_admin text;

alter table public.profiles
  drop constraint if exists profiles_role_check;

alter table public.profiles
  add constraint profiles_role_check
  check (role in ('tenant', 'landlord', 'provider', 'admin', 'super_admin'));

alter table public.profiles
  drop constraint if exists profiles_role_before_admin_check;

alter table public.profiles
  add constraint profiles_role_before_admin_check
  check (
    role_before_admin is null
    or role_before_admin in ('tenant', 'landlord', 'provider')
  );

create or replace function private.is_super_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select (select auth.uid()) is not null
    and coalesce(
      (auth.jwt()->'app_metadata'->>'super_admin')::boolean,
      false
    )
    and exists (
      select 1
      from public.profiles as profile
      where profile.id = (select auth.uid())
        and profile.role = 'super_admin'
        and profile.account_status = 'active'
    );
$$;

revoke execute on function private.is_super_admin() from public, anon;
grant execute on function private.is_super_admin() to authenticated;

grant usage on schema private to authenticated;

-- A definer lookup prevents recursive profiles RLS while requiring both the
-- trusted JWT claim and the caller's current persisted privileged role.
create or replace function private.is_app_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select (select auth.uid()) is not null
    and exists (
      select 1
      from public.profiles as profile
      where profile.id = (select auth.uid())
        and profile.account_status = 'active'
        and (
          (
            profile.role = 'admin'
            and coalesce(
              (auth.jwt()->'app_metadata'->>'admin')::boolean,
              false
            )
          )
          or (
            profile.role = 'super_admin'
            and coalesce(
              (auth.jwt()->'app_metadata'->>'super_admin')::boolean,
              false
            )
          )
        )
    );
$$;

revoke execute on function private.is_app_admin() from public, anon;
grant execute on function private.is_app_admin() to authenticated;

create or replace function private.protect_profile_fields()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if old.role = 'super_admin'
     and current_user not in ('postgres', 'service_role')
     and not private.is_super_admin() then
    raise exception 'Super-admin profiles are protected from administrator changes';
  end if;

  if new.role is distinct from old.role then
    if old.role = 'super_admin' and new.role <> 'super_admin' then
      if current_user not in ('postgres', 'service_role') then
        raise exception 'Super-admin demotion requires trusted provisioning';
      end if;
    elsif new.role = 'super_admin' and old.role <> 'super_admin' then
      if current_user not in ('postgres', 'service_role')
         and (
           not coalesce(
             (auth.jwt()->'app_metadata'->>'super_admin')::boolean,
             false
           )
           or new.id is distinct from (select auth.uid())
         ) then
        raise exception 'Super-admin role changes require trusted self-provisioning';
      end if;
    elsif old.role = 'admin' or new.role = 'admin' then
      if not private.is_super_admin() then
        raise exception 'Only a super admin may grant or revoke admin access';
      end if;
    elsif not private.is_app_admin() then
      raise exception 'Only an administrator may change account roles';
    end if;
  end if;

  if new.role_before_admin is distinct from old.role_before_admin
     and not private.is_super_admin() then
    raise exception 'Only a super admin may change the saved account role';
  end if;

  if new.is_verified is distinct from old.is_verified
     and not private.is_app_admin() then
    raise exception 'Only an administrator may change verification status';
  end if;

  if (new.account_status is distinct from old.account_status
      or new.legacy_firebase_uid is distinct from old.legacy_firebase_uid)
     and not private.is_super_admin() then
    raise exception 'Only a super admin may change account status or mappings';
  end if;

  return new;
end;
$$;

revoke execute on function private.protect_profile_fields()
  from public, anon, authenticated;

drop policy if exists categories_admin_manage on public.categories;
drop policy if exists categories_super_admin_manage on public.categories;
create policy categories_super_admin_manage on public.categories
  for all to authenticated
  using (private.is_super_admin())
  with check (private.is_super_admin());

drop policy if exists areas_admin_manage on public.areas;
drop policy if exists areas_super_admin_manage on public.areas;
create policy areas_super_admin_manage on public.areas
  for all to authenticated
  using (private.is_super_admin())
  with check (private.is_super_admin());

notify pgrst, 'reload schema';

-- Verification: profile role values, new helper definitions, and global-settings policies.
select conname, pg_get_constraintdef(oid) as definition
from pg_constraint
where conrelid = 'public.profiles'::regclass
  and conname in ('profiles_role_check', 'profiles_role_before_admin_check')
order by conname;

select p.oid::regprocedure as function_name, pg_get_functiondef(p.oid) as definition
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'private'
  and p.proname in ('is_app_admin', 'is_super_admin', 'protect_profile_fields')
order by p.proname;

select
  has_schema_privilege('authenticated', 'private', 'USAGE') as authenticated_has_private_usage,
  has_function_privilege('authenticated', 'private.is_app_admin()', 'EXECUTE') as authenticated_can_check_admin,
  has_function_privilege('authenticated', 'private.is_super_admin()', 'EXECUTE') as authenticated_can_check_super_admin,
  has_schema_privilege('anon', 'private', 'USAGE') as anon_has_private_usage,
  has_function_privilege('anon', 'private.is_app_admin()', 'EXECUTE') as anon_can_check_admin,
  has_function_privilege('anon', 'private.is_super_admin()', 'EXECUTE') as anon_can_check_super_admin;

select schemaname, tablename, policyname, roles, cmd, qual, with_check
from pg_policies
where schemaname = 'public'
  and tablename in ('categories', 'areas')
order by tablename, policyname;
