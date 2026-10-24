-- Discovery: nearby pets with filters, rounded distances and compatibility.
--
-- Distances and radius checks use the fuzzed public_location only, so repeated
-- searches from different points cannot triangulate anyone's exact location.
-- nearby_pets() runs as the caller: RLS on profiles and pets already limits
-- results to verified, non-blocked users.

-- ---------------------------------------------------------------------------
-- Compatibility score (0 to 100)
--   size 30 + energy 30 + play style 25 + temperament 15,
--   then penalties for cross-species and small-dog mismatches.
-- Unknown values score half, so incomplete profiles land in the middle.
-- ---------------------------------------------------------------------------

create or replace function private.compatibility(a public.pets, b public.pets)
returns integer
language plpgsql
immutable
set search_path = ''
as $$
declare
  size_rank   constant text[] := '{small,medium,large,giant}';
  energy_rank constant text[] := '{low,medium,high}';
  gap   integer;
  score numeric := 0;
begin
  -- Size: 30 for the same size, less per step apart.
  if a.size is null or b.size is null then
    score := score + 15;
  else
    gap := abs(array_position(size_rank, a.size::text) - array_position(size_rank, b.size::text));
    score := score + (array[30, 18, 6, 0])[gap + 1];
  end if;

  -- Energy: 30 for a match, 15 one step apart, 0 for low vs high.
  if a.energy is null or b.energy is null then
    score := score + 15;
  else
    gap := abs(array_position(energy_rank, a.energy::text) - array_position(energy_rank, b.energy::text));
    score := score + (array[30, 15, 0])[gap + 1];
  end if;

  -- Play style: 25 for a match; chasers and wrestlers mix fairly well,
  -- gentle players do not enjoy either much.
  if a.play_style is null or b.play_style is null then
    score := score + 12;
  elsif a.play_style = b.play_style then
    score := score + 25;
  elsif 'gentle' in (a.play_style::text, b.play_style::text) then
    score := score + 5;
  else
    score := score + 15;
  end if;

  -- Temperament: reactive pets are a poor default match for anyone.
  if a.temperament is null or b.temperament is null then
    score := score + 7;
  elsif 'reactive' in (a.temperament::text, b.temperament::text) then
    score := score + 0;
  elsif a.temperament = 'friendly' and b.temperament = 'friendly' then
    score := score + 15;
  elsif a.temperament = 'shy' and b.temperament = 'shy' then
    score := score + 8;
  else
    score := score + 10;
  end if;

  -- Dog meets cat: respect each side's good_with_cats.
  if (a.species = 'dog' and b.species = 'cat') or (a.species = 'cat' and b.species = 'dog') then
    case (case when a.species = 'dog' then a.good_with_cats else b.good_with_cats end)
      when true then null;
      when false then score := score * 0.3;
      else score := score * 0.7;
    end case;
  elsif a.species <> b.species then
    score := score * 0.6;
  end if;

  -- A dog that is not good with small dogs, meeting a small dog.
  if a.species = 'dog' and b.species = 'dog' then
    if (b.size = 'small' and a.good_with_small_dogs is false)
       or (a.size = 'small' and b.good_with_small_dogs is false) then
      score := score * 0.5;
    end if;
  end if;

  return round(score)::integer;
end;
$$;

grant execute on function private.compatibility(public.pets, public.pets) to authenticated;

-- Score two pets the caller can see. Returns null if either is not visible.
create or replace function public.compatibility_score(pet_a uuid, pet_b uuid)
returns integer
language sql
stable
security invoker
set search_path = ''
as $$
  select private.compatibility(a, b)
  from public.pets a, public.pets b
  where a.id = pet_a and b.id = pet_b;
$$;

revoke execute on function public.compatibility_score(uuid, uuid) from public, anon;
grant execute on function public.compatibility_score(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Rounded distance shown to users: "under 1 km", then 0.5 km steps up to
-- 10 km, then whole kilometres.
-- ---------------------------------------------------------------------------

create or replace function private.round_distance_km(meters double precision)
returns numeric
language sql
immutable
set search_path = ''
as $$
  select case
    when meters < 1000  then 1
    when meters < 10000 then round((meters / 1000.0)::numeric * 2) / 2
    else round((meters / 1000.0)::numeric)
  end;
$$;

grant execute on function private.round_distance_km(double precision) to authenticated;

-- ---------------------------------------------------------------------------
-- nearby_pets: the Discover page.
-- Center defaults to the caller's home location; pass lat/lng to search from
-- where they are now. With my_pet_id, results include a compatibility score.
-- ---------------------------------------------------------------------------

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
  compatibility       integer
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
    case when my_pet_id is not null then private.compatibility(mine, p) end
  from public.pets p
  join public.profiles o on o.id = p.owner_id
  where o.id <> auth.uid()
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

revoke execute on function public.nearby_pets(
  double precision, double precision, double precision, uuid,
  public.pet_species[], public.pet_size[], public.energy_level[], public.pet_temperament[],
  integer, integer, boolean, integer, integer
) from public, anon;
grant execute on function public.nearby_pets(
  double precision, double precision, double precision, uuid,
  public.pet_species[], public.pet_size[], public.energy_level[], public.pet_temperament[],
  integer, integer, boolean, integer, integer
) to authenticated;
