-- Discover shows verified members only, regardless of who is searching.
--
-- nearby_pets() relied on RLS to hide unverified members, but admins may read
-- every pet for moderation, so an admin's Discover listed unverified pets.
-- The function now filters on the owner's verification itself. Same
-- signature and output as 012_match_breakdown.sql.

create or replace function public.nearby_pets(
  radius_km        double precision default 5,
  lat              double precision default null,
  lng              double precision default null,
  my_pet_id        uuid default null,
  species_filter   public.pet_species[] default null,
  sizes            public.pet_size[] default null,
  energies         public.energy_level[] default null,
  temperaments     public.pet_temperament[] default null,
  min_age_months   integer default null,
  max_age_months   integer default null,
  vaccinated_only  boolean default false,
  page_size        integer default 30,
  page_offset      integer default 0
)
returns table (
  pet_id              uuid,
  name                text,
  species             public.pet_species,
  breed               text,
  gender              public.pet_gender,
  size                public.pet_size,
  energy              public.energy_level,
  temperament         public.pet_temperament,
  play_style          public.play_style,
  age_months          integer,
  vaccinated          boolean,
  photo               text,
  likes               text[],
  owner_id            uuid,
  owner_username      text,
  owner_avatar_url    text,
  area_name           text,
  approx_distance_km  numeric,
  compatibility       integer,
  approx_lat          double precision,
  approx_lng          double precision
)
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  center extensions.geography;
  mine   public.pets;
begin
  if not private.is_verified() then
    raise exception 'Only verified users can discover pets' using errcode = '42501';
  end if;

  if radius_km is null or radius_km <= 0 or radius_km > 50 then
    raise exception 'radius_km must be between 0 and 50';
  end if;

  if lat is not null and lng is not null then
    center := extensions.st_point(lng, lat)::extensions.geography;
  else
    select extensions.st_point(l.lng, l.lat)::extensions.geography into center
    from public.get_my_location() l;
  end if;

  if center is null then
    raise exception 'Set your location first' using errcode = 'P0001';
  end if;

  if my_pet_id is not null then
    select * into mine from public.pets p where p.id = my_pet_id and p.owner_id = auth.uid();
    if not found then
      raise exception 'my_pet_id must be one of your pets';
    end if;
  end if;

  return query
  select
    p.id,
    p.name,
    p.species,
    p.breed,
    p.gender,
    p.size,
    p.energy,
    p.temperament,
    p.play_style,
    case when p.birth_date is not null
         then (extract(year from age(p.birth_date)) * 12 + extract(month from age(p.birth_date)))::integer
    end,
    p.vaccinated,
    p.photos[1],
    p.likes,
    o.id,
    o.username,
    o.avatar_url,
    case when o.show_area then o.area_name end,
    private.round_distance_km(extensions.st_distance(o.public_location, center)),
    case when my_pet_id is not null then private.compatibility(mine, p) end,
    extensions.st_y(o.public_location::extensions.geometry),
    extensions.st_x(o.public_location::extensions.geometry)
  from public.pets p
  join public.profiles o on o.id = p.owner_id
  where o.id <> auth.uid()
    -- Verified owners only, whoever is searching: admins can read every pet
    -- for moderation, but Discover must never show unverified members.
    and o.verification_status = 'verified'
    and o.public_location is not null
    and extensions.st_dwithin(o.public_location, center, radius_km * 1000)
    and (species_filter is null or p.species = any (species_filter))
    and (sizes is null or p.size = any (sizes))
    and (energies is null or p.energy = any (energies))
    and (temperaments is null or p.temperament = any (temperaments))
    and (not vaccinated_only or p.vaccinated)
    and (min_age_months is null or p.birth_date <= current_date - make_interval(months => min_age_months))
    and (max_age_months is null or p.birth_date >= current_date - make_interval(months => max_age_months))
  order by o.public_location operator(extensions.<->) center, p.created_at
  limit least(greatest(page_size, 1), 100)
  offset greatest(page_offset, 0);
end;
$$;

