-- Manual deployment: restore listing image RPCs required by Flutter app.
-- Read carefully before running in Supabase SQL Editor. Do NOT run automatically.
--
-- Verified production schema note (2026-11-25):
--   public.listings.type, public.listings.price_unit, public.listings.status
--   are TEXT columns in production (not custom enum types). Do not cast to
--   public.listing_type / public.listing_price_unit / public.listing_status.
--
-- Purpose:
--   Creates public.replace_listing_images(uuid, jsonb)
--   Creates public.update_listing_with_images(uuid, jsonb, jsonb)
--   Signatures/arg names match Flutter repository calls in
--   lib/features/listings/data/supabase_listings_repository.dart.
--
-- SECURITY DEFINER / RLS bypass note:
--   These functions are SECURITY DEFINER with fixed search_path = pg_catalog, public.
--   This is necessary to perform coordinated listing + listing_images writes and to
--   validate storage.objects references consistently. Because SECURITY DEFINER can
--   bypass RLS, all relevant authorization rules are enforced inside the functions:
--   authentication, owner/admin identity, pending-only restriction for ordinary
--   owners (mirroring listings_owner_update), protected-field preservation, and
--   strict image/path validation.
--
-- Security/status rules:
--   - Auth required. Caller must be listing owner or trusted app admin
--     (private.is_app_admin()).
--   - Ordinary owners may update listing details/image metadata only when the
--     listing status is 'pending'. Approved/rejected/non-pending listings cannot
--     be modified by ordinary owners through these RPCs.
--   - Trusted admins may manage listings according to private.is_app_admin().
--   - Existing listing status and rejection_reason are preserved by this RPC.
--     It never resets approval status and never accepts owner/admin status or
--     rejection_reason changes through p_listing_data.
--   - Protected fields never changed from caller input: owner_id, rating_avg,
--     rating_count, is_featured, owner_verified, status, rejection_reason.
--   - Image validation: p_images must be array; max 8 images; each entry must be
--     object with non-negative integer display_order; duplicate display_order
--     values rejected; each image must have storage_path or external http/https URL.
--   - Storage path validation: exactly 3 segments; segment 1 == listing owner UUID;
--     segment 2 == listing UUID; segment 3 == non-empty filename; referenced object
--     must exist in private bucket 'listing-images' in storage.objects.
--   - EXECUTE revoked from PUBLIC and anon; granted only to authenticated.

begin;

create or replace function public.replace_listing_images(
  p_listing_id uuid,
  p_images jsonb default '[]'::jsonb
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_user_id uuid := auth.uid();
  v_listing_owner uuid;
  v_listing_status text;
  v_is_admin boolean := false;
  v_image jsonb;
  v_image_url text;
  v_storage_path text;
  v_display_order integer;
  v_seen_orders integer[] := '{}'::integer[];
begin
  if v_user_id is null then
    raise exception 'Authentication required.' using errcode = '42501';
  end if;

  select l.owner_id, l.status
    into v_listing_owner, v_listing_status
  from public.listings l
  where l.id = p_listing_id
  for update;

  if not found then
    raise exception 'Listing not found.' using errcode = 'P0002';
  end if;

  if to_regprocedure('private.is_app_admin()') is not null then
    select private.is_app_admin() into v_is_admin;
  end if;

  if not coalesce(v_is_admin, false) then
    if v_listing_owner <> v_user_id then
      raise exception 'You can only edit your own listings.' using errcode = '42501';
    end if;
    if coalesce(v_listing_status, '') <> 'pending' then
      raise exception 'Only pending listings can be edited by owners.' using errcode = '42501';
    end if;
  end if;

  if p_images is null or jsonb_typeof(p_images) <> 'array' then
    raise exception 'p_images must be a JSON array.' using errcode = '22P02';
  end if;

  if jsonb_array_length(p_images) > 8 then
    raise exception 'A listing can contain at most 8 images.' using errcode = '22023';
  end if;

  delete from public.listing_images
  where listing_id = p_listing_id;

  for v_image in select value from jsonb_array_elements(p_images)
  loop
    if jsonb_typeof(v_image) <> 'object' then
      raise exception 'Each image entry must be a JSON object.' using errcode = '22P02';
    end if;

    v_image_url := nullif(btrim(v_image ->> 'image_url'), '');
    v_storage_path := nullif(btrim(v_image ->> 'storage_path'), '');
    v_display_order := case
      when v_image ? 'display_order'
        and (v_image ->> 'display_order') ~ '^[0-9]+$'
        then (v_image ->> 'display_order')::integer
      else null
    end;

    if v_display_order is null or v_display_order < 0 then
      raise exception 'Image display_order must be a non-negative integer.' using errcode = '22P02';
    end if;
    if v_display_order = any(v_seen_orders) then
      raise exception 'Duplicate image display_order values are not allowed.' using errcode = '22023';
    end if;
    v_seen_orders := array_append(v_seen_orders, v_display_order);

    if v_storage_path is not null then
      -- Exactly 3 segments: <owner_uuid>/<listing_uuid>/<filename>
      if array_length(string_to_array(v_storage_path, '/'), 1) <> 3
         or split_part(v_storage_path, '/', 1) <> v_listing_owner::text
         or split_part(v_storage_path, '/', 2) <> p_listing_id::text
         or btrim(split_part(v_storage_path, '/', 3)) = '' then
        raise exception 'Image storage_path must be <owner_uuid>/<listing_uuid>/<filename> for the listing owner and listing.' using errcode = '42501';
      end if;

      if not exists (
        select 1
        from storage.objects o
        where o.bucket_id = 'listing-images'
          and o.name = v_storage_path
      ) then
        raise exception 'Referenced image object does not exist in listing-images.' using errcode = '23503';
      end if;

      v_image_url := null;
    elsif v_image_url is not null then
      if v_image_url !~* '^https?://' then
        raise exception 'External image URLs must use http or https.' using errcode = '22P02';
      end if;
    else
      raise exception 'Each image must include image_url or storage_path.' using errcode = '22P02';
    end if;

    insert into public.listing_images (
      listing_id,
      image_url,
      storage_path,
      display_order
    ) values (
      p_listing_id,
      v_image_url,
      v_storage_path,
      v_display_order
    );
  end loop;
end;
$$;

create or replace function public.update_listing_with_images(
  p_listing_id uuid,
  p_listing_data jsonb,
  p_images jsonb default '[]'::jsonb
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_user_id uuid := auth.uid();
  v_listing_owner uuid;
  v_is_admin boolean := false;
  v_existing_status text;
  v_existing_rejection_reason text;
  v_existing_rating_avg numeric;
  v_existing_rating_count integer;
  v_existing_is_featured boolean;
  v_existing_owner_verified boolean;
begin
  if v_user_id is null then
    raise exception 'Authentication required.' using errcode = '42501';
  end if;
  if p_listing_data is null or jsonb_typeof(p_listing_data) <> 'object' then
    raise exception 'p_listing_data must be a JSON object.' using errcode = '22P02';
  end if;
  if p_images is null or jsonb_typeof(p_images) <> 'array' then
    raise exception 'p_images must be a JSON array.' using errcode = '22P02';
  end if;

  select
    l.owner_id,
    l.status,
    l.rejection_reason,
    l.rating_avg,
    l.rating_count,
    l.is_featured,
    l.owner_verified
  into
    v_listing_owner,
    v_existing_status,
    v_existing_rejection_reason,
    v_existing_rating_avg,
    v_existing_rating_count,
    v_existing_is_featured,
    v_existing_owner_verified
  from public.listings l
  where l.id = p_listing_id
  for update;

  if not found then
    raise exception 'Listing not found.' using errcode = 'P0002';
  end if;

  if to_regprocedure('private.is_app_admin()') is not null then
    select private.is_app_admin() into v_is_admin;
  end if;

  -- Mirror listings_owner_update RLS: ordinary owners can only edit pending listings.
  if not coalesce(v_is_admin, false) then
    if v_listing_owner <> v_user_id then
      raise exception 'You can only edit your own listings.' using errcode = '42501';
    end if;
    if coalesce(v_existing_status, '') <> 'pending' then
      raise exception 'Only pending listings can be edited by owners.' using errcode = '42501';
    end if;
  end if;

  -- Status/approval are controlled by the trusted admin workflow (review_listing).
  -- This RPC preserves existing status/rejection_reason and never accepts
  -- owner/admin status or rejection_reason changes through p_listing_data.
  update public.listings
  set
    owner_name = coalesce(nullif(btrim(p_listing_data ->> 'owner_name'), ''), owner_name),
    owner_phone = coalesce(nullif(btrim(p_listing_data ->> 'owner_phone'), ''), owner_phone),
    type = coalesce(nullif(btrim(p_listing_data ->> 'type'), ''), type),
    category_id = coalesce(nullif(btrim(p_listing_data ->> 'category_id'), '')::uuid, category_id),
    area_id = coalesce(nullif(btrim(p_listing_data ->> 'area_id'), '')::uuid, area_id),
    title = coalesce(nullif(btrim(p_listing_data ->> 'title'), ''), title),
    title_lower = coalesce(nullif(btrim(p_listing_data ->> 'title_lower'), ''), title_lower),
    description = coalesce(nullif(btrim(p_listing_data ->> 'description'), ''), description),
    price_ugx = coalesce((p_listing_data ->> 'price_ugx')::bigint, price_ugx),
    price_unit = coalesce(nullif(btrim(p_listing_data ->> 'price_unit'), ''), price_unit),
    address = case
      when p_listing_data ? 'address' then nullif(btrim(p_listing_data ->> 'address'), '')
      else address
    end,
    latitude = case
      when p_listing_data ? 'latitude' then (p_listing_data ->> 'latitude')::double precision
      else latitude
    end,
    longitude = case
      when p_listing_data ? 'longitude' then (p_listing_data ->> 'longitude')::double precision
      else longitude
    end,
    bedrooms = case
      when p_listing_data ? 'bedrooms' then (p_listing_data ->> 'bedrooms')::integer
      else bedrooms
    end,
    bathrooms = case
      when p_listing_data ? 'bathrooms' then (p_listing_data ->> 'bathrooms')::integer
      else bathrooms
    end,
    amenities = case
      when p_listing_data ? 'amenities'
        and jsonb_typeof(p_listing_data -> 'amenities') = 'array'
        then coalesce(
          (
            select array_agg(value)
            from jsonb_array_elements_text(p_listing_data -> 'amenities') as value
          ),
          '{}'::text[]
        )
      else amenities
    end,
    thumbnail_url = case
      when p_listing_data ? 'thumbnail_url' then nullif(btrim(p_listing_data ->> 'thumbnail_url'), '')
      else thumbnail_url
    end,
    video_url = case
      when p_listing_data ? 'video_url' then nullif(btrim(p_listing_data ->> 'video_url'), '')
      else video_url
    end,
    status = v_existing_status,
    rejection_reason = v_existing_rejection_reason,
    search_prefixes = case
      when p_listing_data ? 'search_prefixes'
        and jsonb_typeof(p_listing_data -> 'search_prefixes') = 'array'
        then coalesce(
          (
            select array_agg(value)
            from jsonb_array_elements_text(p_listing_data -> 'search_prefixes') as value
          ),
          '{}'::text[]
        )
      else search_prefixes
    end,
    rating_avg = v_existing_rating_avg,
    rating_count = v_existing_rating_count,
    is_featured = v_existing_is_featured,
    owner_verified = v_existing_owner_verified
  where id = p_listing_id;

  -- Flutter sends the full desired image list for the listing. The repository
  -- avoids calling this RPC when image metadata is unchanged, preventing
  -- accidental deletion during ordinary non-image edits.
  perform public.replace_listing_images(p_listing_id, p_images);
end;
$$;

revoke all on function public.replace_listing_images(uuid, jsonb) from public;
revoke all on function public.replace_listing_images(uuid, jsonb) from anon;
revoke all on function public.update_listing_with_images(uuid, jsonb, jsonb) from public;
revoke all on function public.update_listing_with_images(uuid, jsonb, jsonb) from anon;
grant execute on function public.replace_listing_images(uuid, jsonb) to authenticated;
grant execute on function public.update_listing_with_images(uuid, jsonb, jsonb) to authenticated;

commit;
