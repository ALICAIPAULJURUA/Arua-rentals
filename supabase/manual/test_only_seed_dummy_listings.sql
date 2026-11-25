-- TEST-ONLY DUMMY LISTING SEED — DO NOT RUN IN PRODUCTION
-- =========================================================
-- Purpose:
--   Prepare at least one realistic [TEST DATA] listing for every category in
--   public.categories in an ISOLATED TEST/DEV Supabase project.
--
-- Safety rules:
--   - DO NOT run against production.
--   - Review this script before execution.
--   - This script is intended for the Supabase SQL editor/service-role context;
--     that context can bypass RLS. Do not bypass RLS in application code.
--   - No fabricated images/storage objects are referenced.
--   - Existing real data is not modified or deleted.
--   - Running again should not create duplicates for the same category+owner.
--
-- Preconditions:
--   1. Confirm the target project is an isolated test/dev project.
--   2. Identify a real test user UUID that already exists in public.profiles and
--      is allowed to own listings in that test environment.
--   3. Ensure categories and at least one area exist.
--
-- How to use:
--   1. Replace the placeholder owner UUID below.
--   2. Optionally replace the area selection logic.
--   3. Run in Supabase SQL editor against the TEST project only.
--   4. Verify with the post-seed query at the end.
--
-- IMPORTANT: Replace this value before running.
-- Use a real test profile UUID from public.profiles in the isolated test project.

begin;

do 
declare
  v_owner_id uuid := 'REPLACE_WITH_TEST_OWNER_PROFILE_UUID';
  v_area_id uuid;
  v_category record;
  v_title text;
  v_description text;
  v_price bigint;
  v_type text;
  v_price_unit text;
  v_inserted integer := 0;
begin
  if v_owner_id::text = 'REPLACE_WITH_TEST_OWNER_PROFILE_UUID' then
    raise exception 'Replace REPLACE_WITH_TEST_OWNER_PROFILE_UUID with a real test profile UUID before running.';
  end if;

  if not exists (select 1 from public.profiles where id = v_owner_id) then
    raise exception 'Owner profile % does not exist in public.profiles.', v_owner_id;
  end if;

  select id
    into v_area_id
  from public.areas
  where is_active = true
  order by sort_order asc, name asc
  limit 1;

  if v_area_id is null then
    raise exception 'No active area found in public.areas.';
  end if;

  for v_category in
    select id, name, slug
    from public.categories
    order by sort_order asc, name asc
  loop
    -- Heuristic mapping: adjust after review if your project uses custom types.
    if v_category.slug ~* '(rent|sale|property|house|land|apartment|room|accommod|hostel|shop|office|warehouse)'
       or v_category.name ~* '(rent|sale|property|house|land|apartment|room|accommod|hostel|shop|office|warehouse)'
    then
      v_type := 'property';
      v_price_unit := 'month';
      v_price := 350000;
      v_title := format('[TEST DATA] Sample %s Listing', v_category.name);
      v_description := format(
        '[TEST DATA] This is a fictional %s listing created for testing. It is not a real offer. Please remove or ignore during production use.',
        v_category.name
      );
    else
      v_type := 'service';
      v_price_unit := case
        when v_category.slug ~* '(clean|plumb|elect|repair|maint|paint|wash)' then 'job'
        else 'fixed'
      end;
      v_price := 50000;
      v_title := format('[TEST DATA] Sample %s Service', v_category.name);
      v_description := format(
        '[TEST DATA] This is a fictional %s service listing created for testing. It is not a real offer. Please remove or ignore during production use.',
        v_category.name
      );
    end if;

    if not exists (
      select 1
      from public.listings
      where owner_id = v_owner_id
        and category_id = v_category.id
        and title = v_title
    ) then
      insert into public.listings (
        owner_id,
        owner_name,
        owner_phone,
        type,
        category_id,
        area_id,
        title,
        title_lower,
        description,
        price_ugx,
        price_unit,
        status,
        amenities,
        search_prefixes,
        is_featured,
        owner_verified
      )
      select
        p.id,
        coalesce(nullif(trim(p.full_name), ''), '[TEST DATA] Test Owner'),
        p.phone,
        v_type,
        v_category.id,
        v_area_id,
        v_title,
        lower(v_title),
        v_description,
        v_price,
        v_price_unit,
        'pending',
        '{}',
        '{}',
        false,
        coalesce(p.is_verified, false)
      from public.profiles p
      where p.id = v_owner_id;

      v_inserted := v_inserted + 1;
    end if;
  end loop;

  raise notice 'Inserted % [TEST DATA] listing(s).', v_inserted;
end ;

-- Post-seed verification (run in the same test project):
-- select c.name, c.slug, count(l.id) as test_listings
-- from public.categories c
-- left join public.listings l
--   on l.category_id = c.id
--  and l.title like '[TEST DATA]%'
-- group by c.name, c.slug, c.sort_order
-- order by c.sort_order asc, c.name asc;

commit;
