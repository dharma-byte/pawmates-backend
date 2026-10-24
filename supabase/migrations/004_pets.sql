-- Pet profiles: multiple pets per owner, each with its own page.
-- Visible to verified users when the owner is verified; owners manage their own.

create type public.pet_species as enum ('dog', 'cat', 'bird', 'rabbit', 'other');
create type public.pet_gender as enum ('male', 'female', 'unknown');
create type public.pet_size as enum ('small', 'medium', 'large', 'giant');
create type public.energy_level as enum ('low', 'medium', 'high');
create type public.pet_temperament as enum ('friendly', 'shy', 'reactive');
create type public.play_style as enum ('chaser', 'wrestler', 'gentle');

create table public.pets (
  id                   uuid primary key default gen_random_uuid(),
  owner_id             uuid not null default auth.uid()
                         references public.profiles (id) on delete cascade,
  name                 text not null check (char_length(name) between 1 and 40),
  species              public.pet_species not null,
  breed                text check (char_length(breed) <= 60),
  birth_date           date check (birth_date <= current_date),
  gender               public.pet_gender not null default 'unknown',
  size                 public.pet_size,
  weight_kg            numeric(5, 2) check (weight_kg > 0 and weight_kg < 200),
  energy               public.energy_level,
  temperament          public.pet_temperament,
  play_style           public.play_style,
  good_with_kids       boolean,
  good_with_cats       boolean,
  good_with_small_dogs boolean,
  vaccinated           boolean not null default false,
  vaccinated_on        date check (vaccinated_on <= current_date),
  neutered             boolean,
  allergies            text check (char_length(allergies) <= 300),
  special_needs        text check (char_length(special_needs) <= 300),
  photos               text[] not null default '{}' check (cardinality(photos) <= 6),
  likes                text[] not null default '{}' check (cardinality(likes) <= 15),
  dislikes             text[] not null default '{}' check (cardinality(dislikes) <= 15),
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);

create index pets_owner_id_idx on public.pets (owner_id);
create index pets_species_idx on public.pets (species);

create trigger pets_set_updated_at
  before update on public.pets
  for each row execute function private.set_updated_at();

-- ---------------------------------------------------------------------------
-- Privileges: owner_id is set from the session and can never be changed.
-- ---------------------------------------------------------------------------

revoke all on public.pets from anon, authenticated;
grant select, delete on public.pets to authenticated;
grant insert (
  name, species, breed, birth_date, gender, size, weight_kg, energy, temperament,
  play_style, good_with_kids, good_with_cats, good_with_small_dogs, vaccinated,
  vaccinated_on, neutered, allergies, special_needs, photos, likes, dislikes
) on public.pets to authenticated;
grant update (
  name, species, breed, birth_date, gender, size, weight_kg, energy, temperament,
  play_style, good_with_kids, good_with_cats, good_with_small_dogs, vaccinated,
  vaccinated_on, neutered, allergies, special_needs, photos, likes, dislikes
) on public.pets to authenticated;

-- ---------------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------------

alter table public.pets enable row level security;

create policy "Owners read their own pets"
  on public.pets for select
  to authenticated
  using (owner_id = auth.uid());

create policy "Verified users read pets of verified owners"
  on public.pets for select
  to authenticated
  using (
    private.is_verified()
    and exists (
      select 1 from public.profiles
      where id = pets.owner_id and verification_status = 'verified'
    )
  );

create policy "Admins read all pets"
  on public.pets for select
  to authenticated
  using (private.is_admin());

create policy "Owners add pets"
  on public.pets for insert
  to authenticated
  with check (owner_id = auth.uid());

create policy "Owners update their pets"
  on public.pets for update
  to authenticated
  using (owner_id = auth.uid())
  with check (owner_id = auth.uid());

create policy "Owners delete their pets"
  on public.pets for delete
  to authenticated
  using (owner_id = auth.uid());
