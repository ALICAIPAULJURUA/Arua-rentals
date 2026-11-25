grant usage on schema private to authenticated;

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

  if tg_op = 'INSERT' then
    new.status := 'pending';
    new.rejection_reason := null;
    new.rating_avg := 0;
    new.rating_count := 0;
    new.is_featured := false;

    select p.is_verified
    into new.owner_verified
    from public.profiles p
    where p.id = new.owner_id;

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

drop trigger if exists listings_protect_owner_fields on public.listings;
create trigger listings_protect_owner_fields
  before insert or update on public.listings
  for each row execute function private.protect_listing_owner_fields();
