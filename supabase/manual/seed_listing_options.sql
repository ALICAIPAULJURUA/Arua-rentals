insert into public.categories (name, slug, is_active, sort_order)
values
  ('Rentals', 'rentals', true, 0),
  ('Plumbing', 'plumbing', true, 1),
  ('Electrical', 'electrical', true, 2),
  ('Cleaning', 'cleaning', true, 3)
on conflict (slug) do update
set
  name = excluded.name,
  is_active = excluded.is_active,
  sort_order = excluded.sort_order;

insert into public.areas (name, slug, is_active, sort_order)
values
  ('Arua City', 'arua-city', true, 0),
  ('Arua Hill', 'arua-hill', true, 1),
  ('Ayivu', 'ayivu', true, 2),
  ('Awindiri', 'awindiri', true, 3),
  ('Ediofe', 'ediofe', true, 4),
  ('Mvara', 'mvara', true, 5),
  ('Oli', 'oli', true, 6),
  ('Odravu', 'odravu', true, 7),
  ('Pajulu', 'pajulu', true, 8),
  ('River Oli', 'river-oli', true, 9),
  ('Senior Quarters', 'senior-quarters', true, 10)
on conflict (slug) do update
set
  name = excluded.name,
  is_active = excluded.is_active,
  sort_order = excluded.sort_order;
