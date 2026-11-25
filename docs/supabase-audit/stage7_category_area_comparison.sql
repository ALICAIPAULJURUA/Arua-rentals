-- Stage 7 read-only comparison: deployed categories/areas vs. app/seed expectations.
-- DO NOT EXECUTE AS WRITE. This file contains SELECT statements only.
-- Run in Supabase SQL Editor (read-only) and capture all result sets.

-- 1) Current deployed categories
select id, name, slug, is_active, sort_order, created_at, updated_at
from public.categories
order by sort_order nulls last, name;

-- 2) Current deployed areas
select id, name, slug, is_active, sort_order, created_at, updated_at
from public.areas
order by sort_order nulls last, name;

-- 3) Expected categories (from supabase/manual/seed_listing_options.sql and app defaults)
with expected_categories(slug, name, is_active, sort_order) as (
  values
    ('rentals', 'Rentals', true, 0),
    ('plumbing', 'Plumbing', true, 1),
    ('electrical', 'Electrical', true, 2),
    ('cleaning', 'Cleaning', true, 3)
)
select
  e.slug as expected_slug,
  e.name as expected_name,
  e.is_active as expected_is_active,
  e.sort_order as expected_sort_order,
  c.id as deployed_id,
  c.name as deployed_name,
  c.slug as deployed_slug,
  c.is_active as deployed_is_active,
  c.sort_order as deployed_sort_order,
  case
    when c.id is null then 'MISSING'
    when c.name is distinct from e.name then 'NAME_MISMATCH'
    when c.is_active is distinct from e.is_active then 'ACTIVE_MISMATCH'
    when c.sort_order is distinct from e.sort_order then 'SORT_ORDER_MISMATCH'
    else 'MATCH'
  end as comparison_status
from expected_categories e
left join public.categories c on c.slug = e.slug
order by e.sort_order;

-- 4) Expected areas (from supabase/manual/seed_listing_options.sql and app defaults)
with expected_areas(slug, name, is_active, sort_order) as (
  values
    ('arua-city', 'Arua City', true, 0),
    ('arua-hill', 'Arua Hill', true, 1),
    ('ayivu', 'Ayivu', true, 2),
    ('awindiri', 'Awindiri', true, 3),
    ('ediofe', 'Ediofe', true, 4),
    ('mvara', 'Mvara', true, 5),
    ('oli', 'Oli', true, 6),
    ('odravu', 'Odravu', true, 7),
    ('pajulu', 'Pajulu', true, 8),
    ('river-oli', 'River Oli', true, 9),
    ('senior-quarters', 'Senior Quarters', true, 10)
)
select
  e.slug as expected_slug,
  e.name as expected_name,
  e.is_active as expected_is_active,
  e.sort_order as expected_sort_order,
  a.id as deployed_id,
  a.name as deployed_name,
  a.slug as deployed_slug,
  a.is_active as deployed_is_active,
  a.sort_order as deployed_sort_order,
  case
    when a.id is null then 'MISSING'
    when a.name is distinct from e.name then 'NAME_MISMATCH'
    when a.is_active is distinct from e.is_active then 'ACTIVE_MISMATCH'
    when a.sort_order is distinct from e.sort_order then 'SORT_ORDER_MISMATCH'
    else 'MATCH'
  end as comparison_status
from expected_areas e
left join public.areas a on a.slug = e.slug
order by e.sort_order;

-- 5) Deployed rows not present in expected seed set (review before any seed apply)
with expected_category_slugs(slug) as (
  values ('rentals'), ('plumbing'), ('electrical'), ('cleaning')
)
select 'category' as kind, c.id, c.name, c.slug, c.is_active, c.sort_order
from public.categories c
left join expected_category_slugs e on e.slug = c.slug
where e.slug is null
union all
with expected_area_slugs(slug) as (
  values ('arua-city'), ('arua-hill'), ('ayivu'), ('awindiri'), ('ediofe'),
         ('mvara'), ('oli'), ('odravu'), ('pajulu'), ('river-oli'), ('senior-quarters')
)
select 'area' as kind, a.id, a.name, a.slug, a.is_active, a.sort_order
from public.areas a
left join expected_area_slugs e on e.slug = a.slug
where e.slug is null
order by kind, sort_order nulls last, name;

-- 6) Duplicate slug safety check (should be empty if slug unique constraints exist)
select 'category' as kind, slug, count(*) as row_count
from public.categories
group by slug
having count(*) > 1
union all
select 'area' as kind, slug, count(*) as row_count
from public.areas
group by slug
having count(*) > 1;