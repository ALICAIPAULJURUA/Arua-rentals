create extension if not exists pgcrypto;

create schema if not exists private;
revoke all on schema private from public;
revoke all on schema private from anon, authenticated;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  email text,
  phone text,
  avatar_url text,
  fcm_tokens text[] not null default '{}',
  role text not null default 'tenant'
    check (role in ('tenant', 'landlord', 'provider', 'admin')),
  is_verified boolean not null default false,
  account_status text not null default 'active',
  legacy_firebase_uid text unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.firebase_user_mappings (
  firebase_uid text primary key,
  supabase_user_id uuid not null unique references auth.users(id) on delete cascade,
  migration_batch text not null,
  mapped_at timestamptz not null default now(),
  verification_metadata jsonb
);

create table if not exists public.categories (
  id uuid primary key default gen_random_uuid(),
  legacy_id text unique,
  name text not null,
  slug text not null unique,
  description text,
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.areas (
  id uuid primary key default gen_random_uuid(),
  legacy_id text unique,
  name text not null,
  slug text not null unique,
  description text,
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.listings (
  id uuid primary key default gen_random_uuid(),
  legacy_id text unique,
  owner_id uuid not null references public.profiles(id),
  owner_name text,
  owner_phone text,
  type text not null check (type in ('property', 'service')),
  category_id uuid not null references public.categories(id),
  area_id uuid not null references public.areas(id),
  title text not null check (char_length(title) between 1 and 200),
  title_lower text not null,
  description text not null,
  price_ugx bigint not null check (price_ugx > 0),
  price_unit text not null check (price_unit in ('month', 'job', 'hour', 'fixed')),
  address text,
  latitude double precision check (latitude is null or (latitude between -90 and 90)),
  longitude double precision check (longitude is null or (longitude between -180 and 180)),
  bedrooms integer check (bedrooms is null or bedrooms >= 0),
  bathrooms integer check (bathrooms is null or bathrooms >= 0),
  amenities text[] not null default '{}',
  thumbnail_url text,
  video_url text,
  status text not null default 'pending'
    check (status in ('pending', 'approved', 'rejected')),
  rejection_reason text,
  rating_avg double precision not null default 0 check (rating_avg between 0 and 5),
  rating_count integer not null default 0 check (rating_count >= 0),
  search_document tsvector,
  search_prefixes text[] not null default '{}',
  is_featured boolean not null default false,
  owner_verified boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.listing_images (
  id uuid primary key default gen_random_uuid(),
  listing_id uuid not null references public.listings(id) on delete cascade,
  image_url text,
  storage_path text,
  display_order integer not null check (display_order >= 0),
  created_at timestamptz not null default now(),
  constraint listing_images_source_check
    check (image_url is not null or storage_path is not null),
  constraint listing_images_unique_order
    unique (listing_id, display_order)
);

create table if not exists public.role_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  requested_role text not null check (requested_role in ('landlord', 'provider')),
  status text not null default 'pending'
    check (status in ('pending', 'approved', 'rejected')),
  name text,
  email text,
  phone text,
  reviewed_by uuid references public.profiles(id),
  reviewed_at timestamptz,
  rejection_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.favorites (
  user_id uuid not null references public.profiles(id) on delete cascade,
  listing_id uuid not null references public.listings(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, listing_id)
);

create table if not exists public.chat_rooms (
  id uuid primary key default gen_random_uuid(),
  legacy_id text unique,
  listing_id uuid not null references public.listings(id) on delete cascade,
  participant_one uuid not null references public.profiles(id),
  participant_two uuid not null references public.profiles(id),
  last_message text not null default '',
  last_message_at timestamptz not null default now(),
  unread_count jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint chat_rooms_distinct_participants
    check (participant_one <> participant_two),
  constraint chat_rooms_unique_pair
    unique (listing_id, participant_one, participant_two)
);

create table if not exists public.chat_messages (
  id uuid primary key default gen_random_uuid(),
  legacy_id text,
  room_id uuid not null references public.chat_rooms(id) on delete cascade,
  sender_id uuid not null references public.profiles(id),
  message text not null check (char_length(message) between 1 and 1000),
  message_type text not null default 'text'
    check (message_type = 'text'),
  created_at timestamptz not null default now(),
  constraint chat_messages_unique_legacy_id
    unique (room_id, legacy_id)
);

create table if not exists public.chat_message_reads (
  message_id uuid not null references public.chat_messages(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  read_at timestamptz not null default now(),
  primary key (message_id, user_id)
);

create index if not exists listings_owner_created_idx
  on public.listings (owner_id, created_at desc);
create index if not exists listings_status_created_idx
  on public.listings (status, created_at desc);
create index if not exists listings_featured_created_idx
  on public.listings (status, is_featured, created_at desc);
create index if not exists listings_category_created_idx
  on public.listings (category_id, status, created_at desc);
create index if not exists listings_area_created_idx
  on public.listings (area_id, status, created_at desc);
create index if not exists listings_price_created_idx
  on public.listings (status, price_ugx, created_at desc);
create index if not exists listings_search_gin_idx
  on public.listings using gin (search_document);
create index if not exists listings_prefix_gin_idx
  on public.listings using gin (search_prefixes);
create index if not exists listings_legacy_id_idx
  on public.listings (legacy_id);

create index if not exists role_requests_pending_idx
  on public.role_requests (status, created_at desc);
create index if not exists favorites_user_created_idx
  on public.favorites (user_id, created_at desc, listing_id);
create index if not exists chat_rooms_participant_one_idx
  on public.chat_rooms (participant_one, last_message_at desc);
create index if not exists chat_rooms_participant_two_idx
  on public.chat_rooms (participant_two, last_message_at desc);
create index if not exists chat_messages_room_created_idx
  on public.chat_messages (room_id, created_at desc, id desc);
create index if not exists listing_images_listing_order_idx
  on public.listing_images (listing_id, display_order);

create unique index if not exists role_requests_one_pending_idx
  on public.role_requests (user_id)
  where status = 'pending';

create or replace function private.is_app_admin()
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce(
    (auth.jwt()->'app_metadata'->>'admin')::boolean,
    false
  );
$$;

revoke execute on function private.is_app_admin() from public, anon;
grant execute on function private.is_app_admin() to authenticated;

create or replace function private.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (
    id,
    full_name,
    email,
    phone,
    role,
    is_verified,
    account_status
  )
  values (
    new.id,
    coalesce(
      nullif(trim(new.raw_user_meta_data->>'full_name'), ''),
      split_part(coalesce(new.email, ''), '@', 1),
      'Arua City Finder User'
    ),
    new.email,
    nullif(trim(new.raw_user_meta_data->>'phone'), ''),
    'tenant',
    false,
    'active'
  )
  on conflict (id) do update set
    email = excluded.email,
    updated_at = now();
  return new;
end;
$$;

revoke execute on function private.handle_new_auth_user() from public, anon;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function private.handle_new_auth_user();

create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

revoke execute on function public.set_updated_at() from public, anon;
grant execute on function public.set_updated_at() to authenticated;

drop trigger if exists profiles_set_updated_at on public.profiles;
create trigger profiles_set_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

drop trigger if exists categories_set_updated_at on public.categories;
create trigger categories_set_updated_at
  before update on public.categories
  for each row execute function public.set_updated_at();

drop trigger if exists areas_set_updated_at on public.areas;
create trigger areas_set_updated_at
  before update on public.areas
  for each row execute function public.set_updated_at();

drop trigger if exists listings_set_updated_at on public.listings;
create trigger listings_set_updated_at
  before update on public.listings
  for each row execute function public.set_updated_at();

drop trigger if exists role_requests_set_updated_at on public.role_requests;
create trigger role_requests_set_updated_at
  before update on public.role_requests
  for each row execute function public.set_updated_at();

drop trigger if exists chat_rooms_set_updated_at on public.chat_rooms;
create trigger chat_rooms_set_updated_at
  before update on public.chat_rooms
  for each row execute function public.set_updated_at();

create or replace function private.protect_profile_fields()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if coalesce(private.is_app_admin(), false) then
    return new;
  end if;

  if new.role is distinct from old.role
     or new.is_verified is distinct from old.is_verified
     or new.account_status is distinct from old.account_status
     or new.legacy_firebase_uid is distinct from old.legacy_firebase_uid
  then
    raise exception 'Profile role, verification, account status, and mapping fields are protected';
  end if;

  return new;
end;
$$;

revoke execute on function private.protect_profile_fields() from public, anon, authenticated;

drop trigger if exists profiles_protect_fields on public.profiles;
create trigger profiles_protect_fields
  before update on public.profiles
  for each row execute function private.protect_profile_fields();

create or replace function private.protect_listing_owner_fields()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if coalesce(private.is_app_admin(), false) then
    return new;
  end if;

  if new.owner_id is distinct from old.owner_id
     or new.rating_avg is distinct from old.rating_avg
     or new.rating_count is distinct from old.rating_count
     or new.is_featured is distinct from old.is_featured
     or new.owner_verified is distinct from old.owner_verified
     or new.status <> 'pending'
  then
    raise exception 'Owner updates cannot change ownership, moderation, aggregate, or featured fields';
  end if;

  if new.rejection_reason is distinct from old.rejection_reason then
    new.rejection_reason := null;
  end if;

  return new;
end;
$$;

revoke execute on function private.protect_listing_owner_fields() from public, anon, authenticated;

drop trigger if exists listings_protect_owner_fields on public.listings;
create trigger listings_protect_owner_fields
  before update on public.listings
  for each row execute function private.protect_listing_owner_fields();

create or replace function public.generate_listing_prefixes(
  p_title text,
  p_category text,
  p_area text
)
returns text[]
language plpgsql
immutable
set search_path = ''
as $$
declare
  token text;
  prefix_length integer;
  result text[] := '{}';
begin
  for token in
    select word
    from unnest(
      regexp_split_to_array(
        lower(concat_ws(' ', coalesce(p_title, ''), coalesce(p_category, ''), coalesce(p_area, ''))),
        '[^a-z0-9]+'
      )
    ) as word
  loop
    if coalesce(length(token), 0) > 0 then
      for prefix_length in 1..length(token) loop
        result := array_append(result, substr(token, 1, prefix_length));
      end loop;
    end if;
  end loop;
  return array(
    select distinct prefix
    from unnest(result) as prefixes(prefix)
    order by prefix
  );
end;
$$;

revoke execute on function public.generate_listing_prefixes(text, text, text)
  from public, anon;
grant execute on function public.generate_listing_prefixes(text, text, text)
  to authenticated;

create or replace function public.refresh_listing_search(p_listing_id uuid)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  listing_record public.listings%rowtype;
  category_name text;
  area_name text;
begin
  select * into listing_record
  from public.listings
  where id = p_listing_id;

  if listing_record.id is null then
    return;
  end if;

  select name into category_name
  from public.categories
  where id = listing_record.category_id;

  select name into area_name
  from public.areas
  where id = listing_record.area_id;

  update public.listings
  set
    title_lower = lower(trim(title)),
    search_document =
      to_tsvector(
        'simple',
        concat_ws(
          ' ',
          title,
          coalesce(description, ''),
          coalesce(category_name, ''),
          coalesce(area_name, '')
        )
      ),
    search_prefixes =
      public.generate_listing_prefixes(title, category_name, area_name)
  where id = p_listing_id;
end;
$$;

revoke execute on function public.refresh_listing_search(uuid) from public, anon;
grant execute on function public.refresh_listing_search(uuid) to authenticated;

create or replace function public.listing_search_refresh()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  perform public.refresh_listing_search(coalesce(new.id, old.id));
  return new;
end;
$$;

drop trigger if exists listings_refresh_search on public.listings;
create trigger listings_refresh_search
  after insert or update of title, description, category_id, area_id
  on public.listings
  for each row execute function public.listing_search_refresh();

create or replace function public.category_area_search_refresh()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_table_name = 'categories' then
    update public.listings l
    set category_id = l.category_id
    where l.category_id = coalesce(new.id, old.id);
  else
    update public.listings l
    set area_id = l.area_id
    where l.area_id = coalesce(new.id, old.id);
  end if;
  return new;
end;
$$;

drop trigger if exists categories_refresh_listing_search on public.categories;
create trigger categories_refresh_listing_search
  after update of name
  on public.categories
  for each row execute function public.category_area_search_refresh();

drop trigger if exists areas_refresh_listing_search on public.areas;
create trigger areas_refresh_listing_search
  after update of name
  on public.areas
  for each row execute function public.category_area_search_refresh();

create or replace function private.review_role_request(
  p_request_id uuid,
  p_decision text,
  p_rejection_reason text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  request_record public.role_requests%rowtype;
begin
  if (select auth.uid()) is null or not private.is_app_admin() then
    raise exception 'Administrator access is required';
  end if;
  if p_decision not in ('approved', 'rejected') then
    raise exception 'Decision must be approved or rejected';
  end if;

  select * into request_record
  from public.role_requests
  where id = p_request_id
  for update;

  if request_record.id is null or request_record.status <> 'pending' then
    raise exception 'This role request is no longer pending';
  end if;

  if p_decision = 'rejected'
     and (
       p_rejection_reason is null
       or char_length(trim(p_rejection_reason)) < 1
       or char_length(trim(p_rejection_reason)) > 500
     ) then
    raise exception 'A rejection reason of 1 to 500 characters is required';
  end if;

  update public.role_requests
  set
    status = p_decision,
    reviewed_by = (select auth.uid()),
    reviewed_at = now(),
    rejection_reason = case
      when p_decision = 'rejected' then trim(p_rejection_reason)
      else null
    end,
    updated_at = now()
  where id = p_request_id;

  if p_decision = 'approved' then
    update public.profiles
    set role = request_record.requested_role,
        updated_at = now()
    where id = request_record.user_id;
  else
    update public.profiles
    set role = 'tenant',
        updated_at = now()
    where id = request_record.user_id;
  end if;
end;
$$;

revoke execute on function private.review_role_request(uuid, text, text)
  from public, anon;
grant execute on function private.review_role_request(uuid, text, text)
  to authenticated;

create or replace function private.review_listing(
  p_listing_id uuid,
  p_status text,
  p_rejection_reason text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null or not private.is_app_admin() then
    raise exception 'Administrator access is required';
  end if;
  if p_status not in ('approved', 'rejected') then
    raise exception 'Listing status must be approved or rejected';
  end if;
  if p_status = 'rejected'
     and (
       p_rejection_reason is null
       or char_length(trim(p_rejection_reason)) < 1
       or char_length(trim(p_rejection_reason)) > 500
     ) then
    raise exception 'A rejection reason of 1 to 500 characters is required';
  end if;

  update public.listings
  set
    status = p_status,
    rejection_reason = case
      when p_status = 'rejected' then trim(p_rejection_reason)
      else null
    end,
    updated_at = now()
  where id = p_listing_id;

  if not found then
    raise exception 'This listing no longer exists';
  end if;
end;
$$;

revoke execute on function private.review_listing(uuid, text, text)
  from public, anon;
grant execute on function private.review_listing(uuid, text, text)
  to authenticated;

create or replace function private.open_chat_room(p_listing_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  listing_record public.listings%rowtype;
  current_user_id uuid;
  canonical_one uuid;
  canonical_two uuid;
  room_id uuid;
begin
  current_user_id := (select auth.uid());
  if current_user_id is null then
    raise exception 'Authentication is required';
  end if;

  select * into listing_record
  from public.listings
  where id = p_listing_id
  for share;

  if listing_record.id is null or listing_record.status <> 'approved' then
    raise exception 'This listing is not available for chat';
  end if;
  if listing_record.owner_id = current_user_id then
    raise exception 'You cannot chat with yourself';
  end if;

  if current_user_id::text < listing_record.owner_id::text then
    canonical_one := current_user_id;
    canonical_two := listing_record.owner_id;
  else
    canonical_one := listing_record.owner_id;
    canonical_two := current_user_id;
  end if;

  select id into room_id
  from public.chat_rooms
  where listing_id = p_listing_id
    and participant_one = canonical_one
    and participant_two = canonical_two;

  if room_id is not null then
    return room_id;
  end if;

  insert into public.chat_rooms (
    listing_id,
    participant_one,
    participant_two,
    unread_count
  )
  values (
    p_listing_id,
    canonical_one,
    canonical_two,
    jsonb_build_object(canonical_one::text, 0, canonical_two::text, 0)
  )
  returning id into room_id;

  return room_id;
end;
$$;

revoke execute on function private.open_chat_room(uuid) from public, anon;
grant execute on function private.open_chat_room(uuid) to authenticated;

create or replace function private.send_chat_message(
  p_room_id uuid,
  p_message text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  room_record public.chat_rooms%rowtype;
  current_user_id uuid;
  recipient_id uuid;
  message_id uuid;
  recipient_count integer;
begin
  current_user_id := (select auth.uid());
  if current_user_id is null then
    raise exception 'Authentication is required';
  end if;
  if char_length(trim(p_message)) < 1
     or char_length(trim(p_message)) > 1000 then
    raise exception 'Messages must be 1 to 1000 characters';
  end if;

  select * into room_record
  from public.chat_rooms
  where id = p_room_id
  for update;

  if room_record.id is null
     or current_user_id not in (room_record.participant_one, room_record.participant_two) then
    raise exception 'You cannot access this chat';
  end if;

  recipient_id := case
    when room_record.participant_one = current_user_id
      then room_record.participant_two
    else room_record.participant_one
  end;

  insert into public.chat_messages (
    room_id,
    sender_id,
    message,
    message_type
  )
  values (
    p_room_id,
    current_user_id,
    trim(p_message),
    'text'
  )
  returning id into message_id;

  recipient_count := coalesce(
    (room_record.unread_count ->> recipient_id::text)::integer,
    0
  );

  update public.chat_rooms
  set
    last_message = trim(p_message),
    last_message_at = now(),
    unread_count =
      room_record.unread_count || jsonb_build_object(
        recipient_id::text,
        recipient_count + 1
      ),
    updated_at = now()
  where id = p_room_id;

  return message_id;
end;
$$;

revoke execute on function private.send_chat_message(uuid, text) from public, anon;
grant execute on function private.send_chat_message(uuid, text) to authenticated;

create or replace function private.mark_chat_read(p_room_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  room_record public.chat_rooms%rowtype;
  current_user_id uuid;
begin
  current_user_id := (select auth.uid());
  if current_user_id is null then
    raise exception 'Authentication is required';
  end if;

  select * into room_record
  from public.chat_rooms
  where id = p_room_id
  for update;

  if room_record.id is null
     or current_user_id not in (room_record.participant_one, room_record.participant_two) then
    raise exception 'You cannot access this chat';
  end if;

  insert into public.chat_message_reads (message_id, user_id)
  select id, current_user_id
  from public.chat_messages
  where room_id = p_room_id
  on conflict (message_id, user_id) do update set read_at = now();

  update public.chat_rooms
  set unread_count =
    room_record.unread_count || jsonb_build_object(current_user_id::text, 0),
    updated_at = now()
  where id = p_room_id;
end;
$$;

revoke execute on function private.mark_chat_read(uuid) from public, anon;
grant execute on function private.mark_chat_read(uuid) to authenticated;

create or replace function public.review_role_request(
  p_request_id uuid,
  p_decision text,
  p_rejection_reason text default null
)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
begin
  perform private.review_role_request(
    p_request_id,
    p_decision,
    p_rejection_reason
  );
end;
$$;

revoke execute on function public.review_role_request(uuid, text, text)
  from public, anon;
grant execute on function public.review_role_request(uuid, text, text)
  to authenticated;

create or replace function public.review_listing(
  p_listing_id uuid,
  p_status text,
  p_rejection_reason text default null
)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
begin
  perform private.review_listing(
    p_listing_id,
    p_status,
    p_rejection_reason
  );
end;
$$;

revoke execute on function public.review_listing(uuid, text, text)
  from public, anon;
grant execute on function public.review_listing(uuid, text, text)
  to authenticated;

create or replace function public.open_chat_room(p_listing_id uuid)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
begin
  return private.open_chat_room(p_listing_id);
end;
$$;

revoke execute on function public.open_chat_room(uuid) from public, anon;
grant execute on function public.open_chat_room(uuid) to authenticated;

create or replace function public.send_chat_message(
  p_room_id uuid,
  p_message text
)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
begin
  return private.send_chat_message(p_room_id, p_message);
end;
$$;

revoke execute on function public.send_chat_message(uuid, text) from public, anon;
grant execute on function public.send_chat_message(uuid, text) to authenticated;

create or replace function public.mark_chat_read(p_room_id uuid)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
begin
  perform private.mark_chat_read(p_room_id);
end;
$$;

revoke execute on function public.mark_chat_read(uuid) from public, anon;
grant execute on function public.mark_chat_read(uuid) to authenticated;

alter table public.profiles enable row level security;
alter table public.firebase_user_mappings enable row level security;
alter table public.categories enable row level security;
alter table public.areas enable row level security;
alter table public.listings enable row level security;
alter table public.listing_images enable row level security;
alter table public.role_requests enable row level security;
alter table public.favorites enable row level security;
alter table public.chat_rooms enable row level security;
alter table public.chat_messages enable row level security;
alter table public.chat_message_reads enable row level security;

drop policy if exists profiles_owner_select on public.profiles;
drop policy if exists profiles_owner_update on public.profiles;
drop policy if exists categories_public_select on public.categories;
drop policy if exists categories_admin_manage on public.categories;
drop policy if exists areas_public_select on public.areas;
drop policy if exists areas_admin_manage on public.areas;
drop policy if exists listings_public_select on public.listings;
drop policy if exists listings_owner_select on public.listings;
drop policy if exists listings_admin_select on public.listings;
drop policy if exists listings_owner_insert on public.listings;
drop policy if exists listings_admin_insert on public.listings;
drop policy if exists listings_owner_update on public.listings;
drop policy if exists listings_admin_update on public.listings;
drop policy if exists listings_owner_delete on public.listings;
drop policy if exists listings_admin_delete on public.listings;
drop policy if exists listing_images_public_select on public.listing_images;
drop policy if exists listing_images_owner_manage on public.listing_images;
drop policy if exists role_requests_owner_select on public.role_requests;
drop policy if exists role_requests_admin_select on public.role_requests;
drop policy if exists role_requests_owner_insert on public.role_requests;
drop policy if exists favorites_owner_all on public.favorites;
drop policy if exists chat_rooms_participant_select on public.chat_rooms;
drop policy if exists chat_messages_participant_select on public.chat_messages;
drop policy if exists chat_reads_participant_manage on public.chat_message_reads;

create policy profiles_owner_select on public.profiles
  for select to authenticated
  using (id = (select auth.uid()) or private.is_app_admin());

create policy profiles_owner_update on public.profiles
  for update to authenticated
  using (id = (select auth.uid()) or private.is_app_admin())
  with check (id = (select auth.uid()) or private.is_app_admin());

create policy categories_public_select on public.categories
  for select to anon, authenticated
  using (is_active);

create policy categories_admin_manage on public.categories
  for all to authenticated
  using (private.is_app_admin())
  with check (private.is_app_admin());

create policy areas_public_select on public.areas
  for select to anon, authenticated
  using (is_active);

create policy areas_admin_manage on public.areas
  for all to authenticated
  using (private.is_app_admin())
  with check (private.is_app_admin());

create policy listings_public_select on public.listings
  for select to anon, authenticated
  using (status = 'approved');

create policy listings_owner_select on public.listings
  for select to authenticated
  using (owner_id = (select auth.uid()));

create policy listings_admin_select on public.listings
  for select to authenticated
  using (private.is_app_admin());

create policy listings_owner_insert on public.listings
  for insert to authenticated
  with check (
    owner_id = (select auth.uid())
    and status = 'pending'
    and exists (
      select 1
      from public.profiles
      where id = (select auth.uid())
        and role in ('landlord', 'provider')
    )
  );

create policy listings_admin_insert on public.listings
  for insert to authenticated
  with check (private.is_app_admin());

create policy listings_owner_update on public.listings
  for update to authenticated
  using (owner_id = (select auth.uid()))
  with check (
    owner_id = (select auth.uid())
    and status = 'pending'
  );

create policy listings_admin_update on public.listings
  for update to authenticated
  using (private.is_app_admin())
  with check (private.is_app_admin());

create policy listings_owner_delete on public.listings
  for delete to authenticated
  using (owner_id = (select auth.uid()));

create policy listings_admin_delete on public.listings
  for delete to authenticated
  using (private.is_app_admin());

create policy listing_images_public_select on public.listing_images
  for select to anon, authenticated
  using (
    exists (
      select 1
      from public.listings
      where listings.id = listing_images.listing_id
        and listings.status = 'approved'
    )
  );

create policy listing_images_owner_manage on public.listing_images
  for all to authenticated
  using (
    exists (
      select 1
      from public.listings
      where listings.id = listing_images.listing_id
        and listings.owner_id = (select auth.uid())
    )
  )
  with check (
    exists (
      select 1
      from public.listings
      where listings.id = listing_images.listing_id
        and listings.owner_id = (select auth.uid())
    )
  );

create policy role_requests_owner_select on public.role_requests
  for select to authenticated
  using (user_id = (select auth.uid()));

create policy role_requests_admin_select on public.role_requests
  for select to authenticated
  using (private.is_app_admin());

create policy role_requests_owner_insert on public.role_requests
  for insert to authenticated
  with check (
    user_id = (select auth.uid())
    and status = 'pending'
  );

create policy favorites_owner_all on public.favorites
  for all to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create policy chat_rooms_participant_select on public.chat_rooms
  for select to authenticated
  using (
    participant_one = (select auth.uid())
    or participant_two = (select auth.uid())
  );

create policy chat_messages_participant_select on public.chat_messages
  for select to authenticated
  using (
    exists (
      select 1
      from public.chat_rooms
      where chat_rooms.id = chat_messages.room_id
        and (
          chat_rooms.participant_one = (select auth.uid())
          or chat_rooms.participant_two = (select auth.uid())
        )
    )
  );

create policy chat_reads_participant_manage on public.chat_message_reads
  for all to authenticated
  using (
    user_id = (select auth.uid())
    and exists (
      select 1
      from public.chat_messages
      join public.chat_rooms
        on chat_rooms.id = chat_messages.room_id
      where chat_messages.id = chat_message_reads.message_id
        and (
          chat_rooms.participant_one = (select auth.uid())
          or chat_rooms.participant_two = (select auth.uid())
        )
    )
  )
  with check (
    user_id = (select auth.uid())
    and exists (
      select 1
      from public.chat_messages
      join public.chat_rooms
        on chat_rooms.id = chat_messages.room_id
      where chat_messages.id = chat_message_reads.message_id
        and (
          chat_rooms.participant_one = (select auth.uid())
          or chat_rooms.participant_two = (select auth.uid())
        )
    )
  );

grant usage on schema public to anon, authenticated;
grant select on public.categories, public.areas to anon, authenticated;
grant insert, update, delete on public.categories, public.areas to authenticated;
grant select, insert, update, delete on public.listings to authenticated;
grant select on public.listing_images to anon, authenticated;
grant select on public.listings to anon;

grant select, insert, update on public.profiles to authenticated;
grant insert, update, delete on public.listing_images to authenticated;
grant select, insert on public.role_requests to authenticated;
grant select, insert, update, delete on public.favorites to authenticated;
grant select on public.chat_rooms, public.chat_messages, public.chat_message_reads to authenticated;
grant insert, update, delete on public.chat_message_reads to authenticated;

revoke all on public.firebase_user_mappings from anon, authenticated;
grant select on public.role_requests to authenticated;
grant select, insert, update, delete on public.role_requests to authenticated;
grant select on public.chat_rooms, public.chat_messages to authenticated;

insert into storage.buckets (id, name, public)
values ('listing-images', 'listing-images', true),
       ('avatars', 'avatars', true)
on conflict (id) do update set
  public = excluded.public;

update storage.buckets
set public = false
where id in ('listing-images', 'avatars');

drop policy if exists listing_images_public_read on storage.objects;
create policy listing_images_public_read
  on storage.objects for select
  to anon, authenticated
  using (
    bucket_id = 'listing-images'
    and (
      exists (
        select 1
        from public.listings
        where listings.status = 'approved'
          and listings.id::text = (storage.foldername(name))[2]
      )
      or (
        (select auth.uid()) is not null
        and (storage.foldername(name))[1] = (select auth.uid())::text
      )
    )
  );

drop policy if exists listing_images_owner_insert on storage.objects;
create policy listing_images_owner_insert
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'listing-images'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

drop policy if exists listing_images_owner_update on storage.objects;
create policy listing_images_owner_update
  on storage.objects for update
  to authenticated
  using (
    bucket_id = 'listing-images'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  )
  with check (
    bucket_id = 'listing-images'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

drop policy if exists listing_images_owner_delete on storage.objects;
create policy listing_images_owner_delete
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'listing-images'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

drop policy if exists avatars_public_read on storage.objects;
create policy avatars_public_read
  on storage.objects for select
  to anon, authenticated
  using (bucket_id = 'avatars');

drop policy if exists avatars_owner_insert on storage.objects;
create policy avatars_owner_insert
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

drop policy if exists avatars_owner_update on storage.objects;
create policy avatars_owner_update
  on storage.objects for update
  to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  )
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

drop policy if exists avatars_owner_delete on storage.objects;
create policy avatars_owner_delete
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );
