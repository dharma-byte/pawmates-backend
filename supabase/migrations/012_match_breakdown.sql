-- "Why this match?" and the Discover map.
--
-- 1. private.compatibility_parts() returns the score's breakdown; the score
--    itself is now computed from it, so the number and its explanation can
--    never disagree. Rules are unchanged from 009_discovery.sql.
-- 2. nearby_pets() also returns the owner's FUZZED public point (already
--    500 m to 1 km from home) so Discover can pin pets on a map.

create or replace function private.compatibility_parts(a public.pets, b public.pets)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  size_rank   constant text[] := '{small,medium,large,giant}';
  energy_rank constant text[] := '{low,medium,high}';
  gap         integer;
  size_pts    numeric;
  energy_pts  numeric;
  play_pts    numeric;
  temper_pts  numeric;
  multiplier  numeric := 1;
  notes       text[] := '{}';
  dog_ok_cats boolean;
begin
  -- Size: 30 for the same size, less per step apart. Unknown scores half.
  if a.size is null or b.size is null then
    size_pts := 15;
  else
    gap := abs(array_position(size_rank, a.size::text) - array_position(size_rank, b.size::text));
    size_pts := (array[30, 18, 6, 0])[gap + 1];
  end if;

  -- Energy: 30 for a match, 15 one step apart, 0 for low vs high.
  if a.energy is null or b.energy is null then
    energy_pts := 15;
  else
    gap := abs(array_position(energy_rank, a.energy::text) - array_position(energy_rank, b.energy::text));
    energy_pts := (array[30, 15, 0])[gap + 1];
  end if;

  -- Play style: same style 25; chaser + wrestler 15; gentle with rough 5.
  if a.play_style is null or b.play_style is null then
    play_pts := 12;
  elsif a.play_style = b.play_style then
    play_pts := 25;
  elsif 'gentle' in (a.play_style::text, b.play_style::text) then
    play_pts := 5;
  else
    play_pts := 15;
  end if;

  -- Temperament: reactive pets are a poor default match for anyone.
  if a.temperament is null or b.temperament is null then
    temper_pts := 7;
  elsif 'reactive' in (a.temperament::text, b.temperament::text) then
    temper_pts := 0;
    notes := array_append(notes, 'One of them can be reactive with other pets');
  elsif a.temperament = 'friendly' and b.temperament = 'friendly' then
    temper_pts := 15;
  elsif a.temperament = 'shy' and b.temperament = 'shy' then
    temper_pts := 8;
  else
    temper_pts := 10;
  end if;

  -- Dog meets cat: respect the dog's good_with_cats.
  if (a.species = 'dog' and b.species = 'cat') or (a.species = 'cat' and b.species = 'dog') then
    dog_ok_cats := case when a.species = 'dog' then a.good_with_cats else b.good_with_cats end;
    if dog_ok_cats is false then
      multiplier := multiplier * 0.3;
      notes := array_append(notes, 'The dog is not good with cats');
    elsif dog_ok_cats is null then
      multiplier := multiplier * 0.7;
      notes := array_append(notes, 'Not sure if the dog is good with cats');
    end if;
  elsif a.species <> b.species then
    multiplier := multiplier * 0.6;
    notes := array_append(notes, 'Different species');
  end if;

  -- A dog that is not good with small dogs, meeting a small dog.
  if a.species = 'dog' and b.species = 'dog'
     and ((b.size = 'small' and a.good_with_small_dogs is false)
          or (a.size = 'small' and b.good_with_small_dogs is false)) then
    multiplier := multiplier * 0.5;
    notes := array_append(notes, 'One of them is not good with small dogs');
  end if;

  return jsonb_build_object(
    'size', jsonb_build_object('points', size_pts, 'max', 30),
    'energy', jsonb_build_object('points', energy_pts, 'max', 30),
    'play_style', jsonb_build_object('points', play_pts, 'max', 25),
    'temperament', jsonb_build_object('points', temper_pts, 'max', 15),
    'multiplier', multiplier,
    'notes', to_jsonb(notes),
    'total', round((size_pts + energy_pts + play_pts + temper_pts) * multiplier)::integer
  );
end;
$$;

grant execute on function private.compatibility_parts(public.pets, public.pets) to authenticated;

-- The score is the breakdown's total: one source of truth.
create or replace function private.compatibility(a public.pets, b public.pets)
returns integer
language sql
immutable
set search_path = ''
as $$
  select (private.compatibility_parts(a, b) ->> 'total')::integer;
$$;

-- Breakdown for two pets the caller can see (RLS applies). Null if not visible.
create or replace function public.compatibility_breakdown(pet_a uuid, pet_b uuid)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select private.compatibility_parts(a, b)
  from public.pets a, public.pets b
  where a.id = pet_a and b.id = pet_b;
$$;

revoke execute on function public.compatibility_breakdown(uuid, uuid) from public, anon;
grant execute on function public.compatibility_breakdown(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- nearby_pets with map coordinates. The return type changes, so the function
-- is dropped and recreated; the body is otherwise as in 009_discovery.sql.
-- ---------------------------------------------------------------------------

drop function public.nearby_pets(
  double precision, double precision, double precision, uuid,
  public.pet_species[], public.pet_size[], public.energy_level[], public.pet_temperament[],
  integer, integer, boolean, integer, integer
);

create function public.nearby_pets(
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
