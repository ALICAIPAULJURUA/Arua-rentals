-- PROPOSED Stage 7 remediation — DO NOT APPLY WITHOUT EXPLICIT APPROVAL.
-- Purpose: restore missing listing image RPCs and harden listing-images storage/table access
-- for property/service submission flows, based on Stage 6/7 read-only review.
--
-- Confirmed deployed gaps addressed (user-supplied, not re-verified here):
--   - public.replace_listing_images missing
--   - public.update_listing_with_images missing
--   - listing-images bucket has NULL file_size_limit/allowed_mime_types
--   - listing_images_public_read does not verify exact listing_images.storage_path
--
-- Preconditions (verify read-only before apply):
--   1. storage.buckets contains id='listing-images' and public=false.
--   2. public.listings, public.listing_images, public.profiles, storage.objects exist
--      with expected columns used below.
--   3. private.is_app_admin() exists and reflects intended admin semantics.
--   4. storage.foldername(text) exists.
--   5. Review ALL existing storage.objects and public.listing_images policies for
--      permissive policies with different names; this script replaces only named policies.
--   6. Confirm no active clients depend on anonymous/public execute of image RPCs.
--
-- Existing production objects expected to be replaced/modified by this script:
--   - storage.buckets listing-images limits/MIME types (updated).
--   - private schema usage/grant for authenticated (granted).
--   - private.is_app_admin() execute grants (revoked from public/anon, granted to authenticated).
--   - public.replace_listing_images(uuid,jsonb): created.
--   - public.update_listing_with_images(uuid,jsonb,jsonb): created.
--   - storage.objects policies named:
--       listing_images_public_read, listing_images_owner_read, listing_images_admin_read,
--       listing_images_owner_insert, listing_images_admin_insert,
--       listing_images_owner_update, listing_images_admin_update,
--       listing_images_owner_delete, listing_images_admin_delete
--     (dropped/recreated).
--   - public.listing_images policies named:
--       listing_images_admin_select, listing_images_admin_insert,
--       listing_images_admin_update, listing_images_admin_delete
--     (dropped/recreated).
--
-- Security assumptions:
--   - RPCs are SECURITY INVOKER so listings/listing_images RLS and triggers apply.
--   - search_path is fixed to '' and all objects are schema-qualified.
--   - storage_path ownership is bound to listing.owner_id/listing.id from DB, not client input.
--   - External image URLs are constrained to http/https and size; domain allowlisting is not enforced.
--   - Any permissive same-table policy not named here may still grant access.
--
-- Rollback: see docs/supabase-audit/STAGE_7_ROLLBACK_PLAN.md (image script section).

begin;

do $$
begin
  if not exists (
    select 1
    from storage.buckets
    where id = 'listing-images'
  ) then
    raise exception 'The listing-images Storage bucket does not exist';
  end if;

  if exists (
    select 1
    from storage.buckets
    where id = 'listing-images'
      and public is distinct from false
  ) then
    raise exception 'The listing-images bucket must remain private';
  end if;
end;
$$;

update storage.buckets
set
  file_size_limit = 6291456,
  allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp']::text[]
where id = 'listing-images'
  and public is false;

grant usage on schema private to authenticated;
revoke execute on function private.is_app_admin() from public, anon;
grant execute on function private.is_app_admin() to authenticated;

create or replace function public.replace_listing_images(
  p_listing_id uuid,
  p_images jsonb
)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  listing_owner_id uuid;
begin
  if (select auth.uid()) is null then
    raise exception 'Authentication is required to replace listing images'
      using errcode = '42501';
  end if;

  select l.owner_id
  into listing_owner_id
  from public.listings l
  where l.id = p_listing_id
    and (
      l.owner_id = (select auth.uid())
      or (select private.is_app_admin())
    );

  if listing_owner_id is null then
    raise exception 'The listing is unavailable for image changes'
      using errcode = '42501';
  end if;

  if p_images is null or jsonb_typeof(p_images) is distinct from 'array' then
    raise exception 'Image metadata must be a JSON array'
      using errcode = '22023';
  end if;

  if jsonb_array_length(p_images) > 8 then
    raise exception 'A listing can have at most 8 images'
      using errcode = '22023';
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(p_images) as image(
      image_url text,
      storage_path text,
      display_order integer
    )
    where image.display_order is null
      or image.display_order < 0
      or ((image.image_url is null) = (image.storage_path is null))
      or (
        image.image_url is not null
        and (
          char_length(image.image_url) > 2048
          or image.image_url !~* '^https?://[^/?#[:space:]]+([/?#][^[:space:]]*)?$'
        )
      )
      or (
        image.storage_path is not null
        and image.storage_path !~ (
          '^'
          || listing_owner_id::text
          || '/'
          || p_listing_id::text
          || '/[^/]+$'
        )
      )
  ) then
    raise exception 'Image metadata does not match the listing owner and ID'
      using errcode = '22023';
  end if;

  delete from public.listing_images li
  where li.listing_id = p_listing_id;

  insert into public.listing_images (
    listing_id,
    image_url,
    storage_path,
    display_order
  )
  select
    p_listing_id,
    image.image_url,
    image.storage_path,
    image.display_order
  from jsonb_to_recordset(p_images) as image(
    image_url text,
    storage_path text,
    display_order integer
  );

  if exists (
    select 1
    from public.listing_images li
    where li.listing_id = p_listing_id
      and li.storage_path is not null
      and not exists (
        select 1
        from storage.objects so
        where so.bucket_id = 'listing-images'
          and so.name = li.storage_path
      )
  ) then
    raise exception 'A referenced listing image does not exist in Storage'
      using errcode = '22023';
  end if;
end;
$$;

revoke all on function public.replace_listing_images(uuid, jsonb)
  from public, anon;
grant execute on function public.replace_listing_images(uuid, jsonb)
  to authenticated;

create or replace function public.update_listing_with_images(
  p_listing_id uuid,
  p_listing_data jsonb,
  p_images jsonb
)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  existing_listing public.listings%rowtype;
  candidate_listing public.listings%rowtype;
  caller_is_admin boolean;
  updated_row_count integer;
begin
  if (select auth.uid()) is null then
    raise exception 'Authentication is required to update a listing'
      using errcode = '42501';
  end if;

  if p_listing_data is null
     or jsonb_typeof(p_listing_data) is distinct from 'object' then
    raise exception 'Listing data must be a JSON object'
      using errcode = '22023';
  end if;

  select l.*
  into existing_listing
  from public.listings l
  where l.id = p_listing_id
  for update;

  if not found then
    raise exception 'The listing is unavailable for editing'
      using errcode = '42501';
  end if;

  caller_is_admin := (select private.is_app_admin());
  if existing_listing.owner_id <> (select auth.uid())
     and not caller_is_admin then
    raise exception 'You can only edit your own listing'
      using errcode = '42501';
  end if;

  if exists (
    select 1
    from jsonb_object_keys(p_listing_data) as supplied(key)
    where supplied.key not in (
      'owner_id', 'owner_name', 'owner_phone', 'type', 'category_id', 'area_id',
      'title', 'title_lower', 'description', 'price_ugx', 'price_unit',
      'address', 'latitude', 'longitude', 'bedrooms', 'bathrooms', 'amenities',
      'thumbnail_url', 'video_url', 'status', 'rejection_reason',
      'search_prefixes', 'rating_avg', 'rating_count', 'is_featured', 'owner_verified'
    )
  ) then
    raise exception 'Listing data contains unsupported fields'
      using errcode = '22023';
  end if;

  candidate_listing := jsonb_populate_record(existing_listing, p_listing_data);
  if candidate_listing.id <> p_listing_id
     or candidate_listing.owner_id is distinct from existing_listing.owner_id then
    raise exception 'Listing identity and ownership cannot be changed'
      using errcode = '42501';
  end if;

  update public.listings l
  set
    owner_id = candidate_listing.owner_id,
    owner_name = candidate_listing.owner_name,
    owner_phone = candidate_listing.owner_phone,
    type = candidate_listing.type,
    category_id = candidate_listing.category_id,
    area_id = candidate_listing.area_id,
    title = candidate_listing.title,
    title_lower = candidate_listing.title_lower,
    description = candidate_listing.description,
    price_ugx = candidate_listing.price_ugx,
    price_unit = candidate_listing.price_unit,
    address = candidate_listing.address,
    latitude = candidate_listing.latitude,
    longitude = candidate_listing.longitude,
    bedrooms = candidate_listing.bedrooms,
    bathrooms = candidate_listing.bathrooms,
    amenities = candidate_listing.amenities,
    thumbnail_url = candidate_listing.thumbnail_url,
    video_url = candidate_listing.video_url,
    status = candidate_listing.status,
    rejection_reason = candidate_listing.rejection_reason,
    rating_avg = candidate_listing.rating_avg,
    rating_count = candidate_listing.rating_count,
    search_prefixes = candidate_listing.search_prefixes,
    is_featured = candidate_listing.is_featured,
    owner_verified = candidate_listing.owner_verified
  where l.id = p_listing_id;

  get diagnostics updated_row_count = row_count;
  if updated_row_count <> 1 then
    raise exception 'The listing could not be updated under current permissions'
      using errcode = '42501';
  end if;

  perform public.replace_listing_images(p_listing_id, p_images);
end;
$$;

revoke all on function public.update_listing_with_images(uuid, jsonb, jsonb)
  from public, anon;
grant execute on function public.update_listing_with_images(uuid, jsonb, jsonb)
  to authenticated;

-- Storage.objects policies: replace named listing-images policies.
-- WARNING: other permissive policies with different names may still grant access.
drop policy if exists listing_images_public_read on storage.objects;
create policy listing_images_public_read
  on storage.objects for select
  to anon, authenticated
  using (
    bucket_id = 'listing-images'
    and exists (
      select 1
      from public.listings l
      join public.listing_images li on li.listing_id = l.id
      where l.id::text = (storage.foldername(storage.objects.name))[2]
        and l.owner_id::text = (storage.foldername(storage.objects.name))[1]
        and l.status = 'approved'
        and li.storage_path = storage.objects.name
    )
  );

drop policy if exists listing_images_owner_read on storage.objects;
create policy listing_images_owner_read
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'listing-images'
    and (storage.foldername(storage.objects.name))[1] = (select auth.uid())::text
    and exists (
      select 1
      from public.listings l
      join public.listing_images li on li.listing_id = l.id
      where l.id::text = (storage.foldername(storage.objects.name))[2]
        and l.owner_id = (select auth.uid())
        and l.owner_id::text = (storage.foldername(storage.objects.name))[1]
        and li.storage_path = storage.objects.name
    )
  );

drop policy if exists listing_images_admin_read on storage.objects;
create policy listing_images_admin_read
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'listing-images'
    and (select private.is_app_admin())
    and exists (
      select 1
      from public.listings l
      join public.listing_images li on li.listing_id = l.id
      where l.id::text = (storage.foldername(storage.objects.name))[2]
        and l.owner_id::text = (storage.foldername(storage.objects.name))[1]
        and li.storage_path = storage.objects.name
    )
  );

drop policy if exists listing_images_owner_insert on storage.objects;
create policy listing_images_owner_insert
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'listing-images'
    and (storage.foldername(storage.objects.name))[1] = (select auth.uid())::text
    and exists (
      select 1
      from public.listings l
      where l.id::text = (storage.foldername(storage.objects.name))[2]
        and l.owner_id = (select auth.uid())
        and l.owner_id::text = (storage.foldername(storage.objects.name))[1]
    )
  );

drop policy if exists listing_images_admin_insert on storage.objects;
create policy listing_images_admin_insert
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'listing-images'
    and (select private.is_app_admin())
    and exists (
      select 1
      from public.listings l
      where l.id::text = (storage.foldername(storage.objects.name))[2]
        and l.owner_id::text = (storage.foldername(storage.objects.name))[1]
    )
  );

drop policy if exists listing_images_owner_update on storage.objects;
create policy listing_images_owner_update
  on storage.objects for update
  to authenticated
  using (
    bucket_id = 'listing-images'
    and (storage.foldername(storage.objects.name))[1] = (select auth.uid())::text
    and exists (
      select 1
      from public.listings l
      where l.id::text = (storage.foldername(storage.objects.name))[2]
        and l.owner_id = (select auth.uid())
        and l.owner_id::text = (storage.foldername(storage.objects.name))[1]
    )
  )
  with check (
    bucket_id = 'listing-images'
    and (storage.foldername(storage.objects.name))[1] = (select auth.uid())::text
    and exists (
      select 1
      from public.listings l
      where l.id::text = (storage.foldername(storage.objects.name))[2]
        and l.owner_id = (select auth.uid())
        and l.owner_id::text = (storage.foldername(storage.objects.name))[1]
    )
  );

drop policy if exists listing_images_admin_update on storage.objects;
create policy listing_images_admin_update
  on storage.objects for update
  to authenticated
  using (
    bucket_id = 'listing-images'
    and (select private.is_app_admin())
    and exists (
      select 1
      from public.listings l
      where l.id::text = (storage.foldername(storage.objects.name))[2]
        and l.owner_id::text = (storage.foldername(storage.objects.name))[1]
    )
  )
  with check (
    bucket_id = 'listing-images'
    and (select private.is_app_admin())
    and exists (
      select 1
      from public.listings l
      where l.id::text = (storage.foldername(storage.objects.name))[2]
        and l.owner_id::text = (storage.foldername(storage.objects.name))[1]
    )
  );

drop policy if exists listing_images_owner_delete on storage.objects;
create policy listing_images_owner_delete
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'listing-images'
    and (storage.foldername(storage.objects.name))[1] = (select auth.uid())::text
    and exists (
      select 1
      from public.listings l
      where l.id::text = (storage.foldername(storage.objects.name))[2]
        and l.owner_id = (select auth.uid())
        and l.owner_id::text = (storage.foldername(storage.objects.name))[1]
    )
  );

drop policy if exists listing_images_admin_delete on storage.objects;
create policy listing_images_admin_delete
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'listing-images'
    and (select private.is_app_admin())
    and exists (
      select 1
      from public.listings l
      where l.id::text = (storage.foldername(storage.objects.name))[2]
        and l.owner_id::text = (storage.foldername(storage.objects.name))[1]
    )
  );

-- Admin table policies for public.listing_images.
-- These are additive/replacements for named admin policies only.
drop policy if exists listing_images_admin_select on public.listing_images;
create policy listing_images_admin_select
  on public.listing_images for select
  to authenticated
  using ((select private.is_app_admin()));

drop policy if exists listing_images_admin_insert on public.listing_images;
create policy listing_images_admin_insert
  on public.listing_images for insert
  to authenticated
  with check ((select private.is_app_admin()));

drop policy if exists listing_images_admin_update on public.listing_images;
create policy listing_images_admin_update
  on public.listing_images for update
  to authenticated
  using ((select private.is_app_admin()))
  with check ((select private.is_app_admin()));

drop policy if exists listing_images_admin_delete on public.listing_images;
create policy listing_images_admin_delete
  on public.listing_images for delete
  to authenticated
  using ((select private.is_app_admin()));

commit;

-- Post-deployment verification (read-only):
-- select id, public, file_size_limit, allowed_mime_types
-- from storage.buckets where id = 'listing-images';
-- select policyname, roles, cmd from pg_policies
-- where schemaname='storage' and tablename='objects' and policyname like 'listing_images_%'
-- order by policyname;
-- select proname, prosecdef, proconfig,
--   has_function_privilege('authenticated', p.oid, 'EXECUTE') as auth_exec,
--   has_function_privilege('anon', p.oid, 'EXECUTE') as anon_exec
-- from pg_proc p join pg_namespace n on n.oid=p.pronamespace
-- where n.nspname='public' and p.proname in ('replace_listing_images','update_listing_with_images');