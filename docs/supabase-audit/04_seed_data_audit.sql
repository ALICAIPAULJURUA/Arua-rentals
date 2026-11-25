-- 04_seed_data_audit.sql
-- Arua Rentals Supabase read-only seed/config data audit.
-- READ ONLY: SELECT only. No INSERT/UPDATE/DELETE.
-- Does not expose user/profile personal information.

-- =========================
-- 1) Categories overview
-- =========================
select
  count(*) as total_categories,
  count(*) filter (where is_active) as active_categories,
  count(*) filter (where not is_active) as inactive_categories,
  count(*) filter (where slug is null or btrim(slug)='') as missing_slug_count,
  case when count(*) = 0 then 'WARNING' else 'PASS' end as status
from public.categories;

select
  id,
  name,
  slug,
  is_active,
  sort_order,
  created_at,
  updated_at
from public.categories
order by sort_order asc, name asc;

-- Duplicate category slugs/names
select lower(btrim(slug)) as slug_normalized, count(*) as row_count,
       string_agg(name, ', ' order by name) as names,
       case when count(*) > 1 then 'FAIL' else 'PASS' end as status
from public.categories
group by lower(btrim(slug))
having count(*) > 1
order by slug_normalized;

select lower(btrim(name)) as name_normalized, count(*) as row_count,
       string_agg(slug, ', ' order by slug) as slugs,
       case when count(*) > 1 then 'WARNING' else 'PASS' end as status
from public.categories
group by lower(btrim(name))
having count(*) > 1
order by name_normalized;

-- Expected category seed records (from supabase/manual/seed_listing_options.sql)
with expected(slug, name, sort_order) as (
  values
    ('rentals','Rentals',0),
    ('plumbing','Plumbing',1),
    ('electrical','Electrical',2),
    ('cleaning','Cleaning',3)
)
select
  e.slug,
  e.name as expected_name,
  e.sort_order as expected_sort_order,
  c.name as actual_name,
  c.is_active as actual_is_active,
  c.sort_order as actual_sort_order,
  case when c.id is null then 'FAIL'
       when not c.is_active then 'WARNING'
       when c.name <> e.name then 'WARNING'
       else 'PASS' end as status
from expected e
left join public.categories c on c.slug = e.slug
order by e.sort_order;

-- =========================
-- 2) Areas overview
-- =========================
select
  count(*) as total_areas,
  count(*) filter (where is_active) as active_areas,
  count(*) filter (where not is_active) as inactive_areas,
  count(*) filter (where slug is null or btrim(slug)='') as missing_slug_count,
  case when count(*) = 0 then 'WARNING' else 'PASS' end as status
from public.areas;

select
  id,
  name,
  slug,
  is_active,
  sort_order,
  created_at,
  updated_at
from public.areas
order by sort_order asc, name asc;

-- Duplicate area slugs/names
select lower(btrim(slug)) as slug_normalized, count(*) as row_count,
       string_agg(name, ', ' order by name) as names,
       case when count(*) > 1 then 'FAIL' else 'PASS' end as status
from public.areas
group by lower(btrim(slug))
having count(*) > 1
order by slug_normalized;

select lower(btrim(name)) as name_normalized, count(*) as row_count,
       string_agg(slug, ', ' order by slug) as slugs,
       case when count(*) > 1 then 'WARNING' else 'PASS' end as status
from public.areas
group by lower(btrim(name))
having count(*) > 1
order by name_normalized;

-- Expected area seed records (from supabase/manual/seed_listing_options.sql)
with expected(slug, name, sort_order) as (
  values
    ('arua-city','Arua City',0),
    ('arua-hill','Arua Hill',1),
    ('ayivu','Ayivu',2),
    ('awindiri','Awindiri',3),
    ('ediofe','Ediofe',4),
    ('mvara','Mvara',5),
    ('oli','Oli',6),
    ('odravu','Odravu',7),
    ('pajulu','Pajulu',8),
    ('river-oli','River Oli',9),
    ('senior-quarters','Senior Quarters',10)
)
select
  e.slug,
  e.name as expected_name,
  e.sort_order as expected_sort_order,
  a.name as actual_name,
  a.is_active as actual_is_active,
  a.sort_order as actual_sort_order,
  case when a.id is null then 'FAIL'
       when not a.is_active then 'WARNING'
       when a.name <> e.name then 'WARNING'
       else 'PASS' end as status
from expected e
left join public.areas a on a.slug = e.slug
order by e.sort_order;

-- =========================
-- 3) Referential integrity signals (no PII)
-- =========================
select
  (select count(*) from public.listings) as listings_count,
  (select count(*) from public.listings l where not exists (select 1 from public.categories c where c.id=l.category_id)) as listings_missing_category,
  (select count(*) from public.listings l where not exists (select 1 from public.areas a where a.id=l.area_id)) as listings_missing_area,
  case when (select count(*) from public.listings l where not exists (select 1 from public.categories c where c.id=l.category_id)) > 0 then 'FAIL' else 'PASS' end as category_fk_signal,
  case when (select count(*) from public.listings l where not exists (select 1 from public.areas a where a.id=l.area_id)) > 0 then 'FAIL' else 'PASS' end as area_fk_signal;
