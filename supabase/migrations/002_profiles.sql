-- Profiles: one row per auth user, created automatically on sign-up.
--
-- Location privacy:
--   location         exact point, never readable by other users (column privileges)
--   public_location  exact point moved 500 m to 1 km in a random direction (trigger)
-- Clients write `location`; the database derives `public_location`.

create type public.verification_status as enum ('unverified', 'pending', 'verified', 'rejected');
create type public.message_privacy as enum ('everyone', 'connections');

create table public.profiles (
  id                  uuid primary key references auth.users (id) on delete cascade,
  username            text unique
                        check (username ~ '^[a-z0-9_]{3,30}$'),
  full_name           text check (char_length(full_name) <= 80),
  avatar_url          text,
  bio                 text check (char_length(bio) <= 500),
  area_name           text check (char_length(area_name) <= 120),
  languages           text[] not null default '{}',
  interests           text[] not null default '{}',
  location            extensions.geography(point, 4326),
  public_location     extensions.geography(point, 4326),
  verification_status public.verification_status not null default 'unverified',
  verified_at         timestamptz,
  is_admin            boolean not null default false,
  show_online         boolean not null default true,
  show_area           boolean not null default true,
  message_privacy     public.message_privacy not null default 'everyone',
  onboarded_at        timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

create index profiles_location_idx on public.profiles using gist (location);
create index profiles_public_location_idx on public.profiles using gist (public_location);
create index profiles_verified_idx on public.profiles (id) where verification_status = 'verified';

-- ---------------------------------------------------------------------------
-- Helpers used by RLS policies across all tables.
-- security definer so they can read profiles without recursing into RLS.
-- ---------------------------------------------------------------------------

create or replace function private.is_verified()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and verification_status = 'verified'
  );
$$;

create or replace function private.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and is_admin
  );
$$;

grant execute on function private.is_verified() to authenticated;
grant execute on function private.is_admin() to authenticated;

-- Move a point 500 m to 1 km in a random direction.
create or replace function private.fuzz_point(p extensions.geography)
returns extensions.geography
language sql
volatile
set search_path = ''
as $$
  select extensions.st_project(p, 500 + random() * 500, radians(random() * 360));
$$;

-- ---------------------------------------------------------------------------
-- Triggers
-- ---------------------------------------------------------------------------

-- Create an empty profile for every new auth user.
create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id) values (new.id);
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function private.handle_new_user();

-- Derive public_location, and send users back to verification
-- when they change their profile photo.
create or replace function private.profiles_before_write()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.location is null then
    new.public_location = null;
  elsif tg_op = 'INSERT' or new.location is distinct from old.location then
    new.public_location = private.fuzz_point(new.location);
  end if;

  if tg_op = 'UPDATE'
     and new.avatar_url is distinct from old.avatar_url
     and old.verification_status = 'verified' then
    new.verification_status = 'unverified';
    new.verified_at = null;
  end if;

  return new;
end;
$$;

create trigger profiles_before_write
  before insert or update on public.profiles
  for each row execute function private.profiles_before_write();

create trigger profiles_set_updated_at
  before update on public.profiles
  for each row execute function private.set_updated_at();

-- ---------------------------------------------------------------------------
-- Privileges: column-level, so other users can never read `location`
-- and nobody can promote themselves to verified or admin.
-- ---------------------------------------------------------------------------

revoke all on public.profiles from anon, authenticated;

grant select (
  id, username, full_name, avatar_url, bio, area_name, languages, interests,
  public_location, verification_status, verified_at, show_online, show_area,
  message_privacy, onboarded_at, created_at
) on public.profiles to authenticated;

grant update (
  username, full_name, avatar_url, bio, area_name, languages, interests,
  location, show_online, show_area, message_privacy, onboarded_at
) on public.profiles to authenticated;

-- Owners read their own exact location through this function only.
create or replace function public.get_my_location()
returns table (lat double precision, lng double precision, area_name text)
language sql
stable
security definer
set search_path = ''
as $$
  select extensions.st_y(location::extensions.geometry),
         extensions.st_x(location::extensions.geometry),
         area_name
  from public.profiles
  where id = auth.uid();
$$;

revoke execute on function public.get_my_location() from public, anon;
grant execute on function public.get_my_location() to authenticated;

-- ---------------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------------

alter table public.profiles enable row level security;

create policy "Users read their own profile"
  on public.profiles for select
  to authenticated
  using (id = auth.uid());

create policy "Verified users read verified profiles"
  on public.profiles for select
  to authenticated
  using (verification_status = 'verified' and private.is_verified());

create policy "Admins read all profiles"
  on public.profiles for select
  to authenticated
  using (private.is_admin());

create policy "Users update their own profile"
  on public.profiles for update
  to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());
