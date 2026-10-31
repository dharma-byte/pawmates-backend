-- Lost & Found: report a lost dog, alert verified members nearby, collect
-- sightings, and close the report when the dog is home.
--
-- The last-seen spot and sightings are places a dog was seen (streets,
-- parks), shown exactly so neighbours can search. Owners are told in the app
-- not to use their home address. Who gets alerted is decided with fuzzed
-- public points, as everywhere else. The owner and anyone who reported a
-- sighting can message each other even if they are not Pawmates.

alter type public.notification_type add value if not exists 'lost_nearby';     -- a dog was lost near me
alter type public.notification_type add value if not exists 'lost_sighting';   -- someone saw my lost dog
alter type public.notification_type add value if not exists 'lost_found';      -- a dog I helped look for is home

create type public.lost_status as enum ('lost', 'found', 'closed');

create table public.lost_reports (
  id                 uuid primary key default gen_random_uuid(),
  owner_id           uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  pet_id             uuid not null references public.pets (id) on delete cascade,
  status             public.lost_status not null default 'lost',
  last_seen_at       timestamptz not null,
  last_seen_location extensions.geography(point, 4326) not null,
  last_seen_place    text not null check (char_length(btrim(last_seen_place)) between 1 and 300),
  description        text check (char_length(description) <= 1000),
  alert_radius_km    integer not null default 5 check (alert_radius_km between 1 and 15),
  found_at           timestamptz,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

-- One open report per pet.
create unique index lost_reports_open_pet_idx on public.lost_reports (pet_id) where status = 'lost';
create index lost_reports_location_idx on public.lost_reports using gist (last_seen_location);
create index lost_reports_status_idx on public.lost_reports (status, created_at desc);

create trigger lost_reports_set_updated_at
  before update on public.lost_reports
  for each row execute function private.set_updated_at();

create table public.lost_sightings (
  id          uuid primary key default gen_random_uuid(),
  report_id   uuid not null references public.lost_reports (id) on delete cascade,
  reporter_id uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  seen_at     timestamptz not null,
  location    extensions.geography(point, 4326) not null,
  place       text check (char_length(place) <= 300),
  note        text check (char_length(note) <= 500),
  created_at  timestamptz not null default now()
);

create index lost_sightings_report_idx on public.lost_sightings (report_id, seen_at desc);

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Did `a` report a sighting for one of `b`'s lost dogs, or the other way round?
create or replace function private.lost_contact(a uuid, b uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.lost_sightings s
    join public.lost_reports r on r.id = s.report_id
    where (r.owner_id = a and s.reporter_id = b) or (r.owner_id = b and s.reporter_id = a)
  );
$$;

grant execute on function private.lost_contact(uuid, uuid) to authenticated;

-- Chat: Pawmates, people who accept messages from everyone, and now a lost
-- dog's owner and the people who reported sightings of it.
create or replace function private.can_message(other uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.is_verified()
    and not private.is_blocked_between(auth.uid(), other)
    and exists (
      select 1 from public.profiles p
      where p.id = other
        and p.verification_status = 'verified'
        and (p.message_privacy = 'everyone'
             or private.are_pawmates(auth.uid(), other)
             or private.lost_contact(auth.uid(), other))
    );
$$;

create or replace function private.lost_pet_name(report uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select p.name from public.lost_reports r join public.pets p on p.id = r.pet_id where r.id = report;
$$;

-- ---------------------------------------------------------------------------
-- RPCs
-- ---------------------------------------------------------------------------

-- Report one of my pets lost and alert verified members within the radius
-- (nearest 500, by their fuzzed point). Returns the report id.
create or replace function public.report_lost_pet(
  pet              uuid,
  last_seen_at     timestamptz,
  lat              double precision,
  lng              double precision,
  last_seen_place  text,
  description      text default null,
  alert_radius_km  integer default 5
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  me      uuid := auth.uid();
  pet_row public.pets;
  spot    extensions.geography := extensions.st_point(lng, lat)::extensions.geography;
  new_id  uuid;
begin
  if not private.is_verified() then
    raise exception 'Only verified members can report a lost pet' using errcode = '42501';
  end if;
  select * into pet_row from public.pets where id = pet and owner_id = me;
  if not found then
    raise exception 'You can only report your own pet' using errcode = '42501';
  end if;
  if last_seen_at > now() + interval '5 minutes' or last_seen_at < now() - interval '30 days' then
    raise exception 'Last seen must be within the past 30 days' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.lost_reports where pet_id = pet and status = 'lost') then
    raise exception '% is already reported lost', pet_row.name using errcode = 'P0001';
  end if;

  insert into public.lost_reports (owner_id, pet_id, last_seen_at, last_seen_location, last_seen_place, description, alert_radius_km)
  values (me, pet, last_seen_at, spot, btrim(last_seen_place), nullif(btrim(description), ''),
          least(greatest(alert_radius_km, 1), 15))
  returning id into new_id;

  perform private.notify(
    p.id, 'lost_nearby',
    'Lost ' || pet_row.species::text || ' nearby: ' || pet_row.name
      || coalesce(' (' || pet_row.breed || ')', ''),
    'Last seen ' || private.event_time_label(last_seen_at) || ' near ' || btrim(last_seen_place)
      || '. Keep an eye out and tap to report a sighting.',
    '/lost/' || new_id, me, 'lost:' || new_id)
  from (
    select pr.id from public.profiles pr
    where pr.id <> me
      and pr.verification_status = 'verified'
      and pr.public_location is not null
      and extensions.st_dwithin(pr.public_location, spot, least(greatest(alert_radius_km, 1), 15) * 1000)
      and not private.is_blocked_between(me, pr.id)
    order by pr.public_location operator(extensions.<->) spot
    limit 500
  ) p;

  return new_id;
end;
$$;

-- Report a sighting. The owner is notified straight away.
create or replace function public.add_lost_sighting(
  report  uuid,
  seen_at timestamptz,
  lat     double precision,
  lng     double precision,
  place   text default null,
  note    text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  me     uuid := auth.uid();
  r      public.lost_reports;
  new_id uuid;
begin
  if not private.is_verified() then
    raise exception 'Only verified members can report sightings' using errcode = '42501';
  end if;
  select * into r from public.lost_reports where id = report;
  if not found or r.status <> 'lost' or private.is_blocked_between(me, r.owner_id) then
    raise exception 'This lost pet report is closed' using errcode = 'P0001';
  end if;
  if seen_at > now() + interval '5 minutes' or seen_at < r.last_seen_at - interval '1 day' then
    raise exception 'Pick when you saw the pet (after it went missing)' using errcode = 'P0001';
  end if;
  if (select count(*) from public.lost_sightings where reporter_id = me and created_at > now() - interval '1 hour') >= 10 then
    raise exception 'You have reported a lot of sightings recently, please wait a bit' using errcode = 'P0001';
  end if;

  insert into public.lost_sightings (report_id, reporter_id, seen_at, location, place, note)
  values (report, me, seen_at, extensions.st_point(lng, lat)::extensions.geography,
          nullif(btrim(place), ''), nullif(btrim(note), ''))
  returning id into new_id;

  perform private.notify(
    r.owner_id, 'lost_sighting',
    private.display_name(me) || ' saw ' || private.lost_pet_name(report),
    private.event_time_label(seen_at) || coalesce(' near ' || nullif(btrim(place), ''), '')
      || coalesce('. “' || nullif(btrim(note), '') || '”', ''),
    '/lost/' || report, me, 'sighting:' || new_id);
  return new_id;
end;
$$;

-- The owner marks the pet found (or closes the report); everyone who
-- reported a sighting hears the good news.
create or replace function public.close_lost_report(report uuid, found_home boolean default true)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  r public.lost_reports;
begin
  select * into r from public.lost_reports where id = report and owner_id = auth.uid();
  if not found then
    raise exception 'Only the owner can close this report' using errcode = '42501';
  end if;
  if r.status <> 'lost' then
    return;
  end if;

  update public.lost_reports
  set status = case when close_lost_report.found_home then 'found'::public.lost_status else 'closed'::public.lost_status end,
      found_at = case when close_lost_report.found_home then now() end
  where id = report;

  if close_lost_report.found_home then
    perform private.notify(
      s.reporter_id, 'lost_found',
      'Good news: ' || private.lost_pet_name(report) || ' is home!',
      'Thank you for keeping an eye out and reporting what you saw.',
      '/lost/' || report, r.owner_id, 'found:' || report)
    from (select distinct reporter_id from public.lost_sightings where report_id = report) s;
  end if;
end;
$$;

-- Lost (and recently found) pets near me, plus my own reports.
create or replace function public.lost_pets_nearby(radius_km integer default 15)
returns table (
  id              uuid,
  pet_id          uuid,
  pet_name        text,
  species         public.pet_species,
  breed           text,
  photo           text,
  owner_id        uuid,
  owner_name      text,
  status          public.lost_status,
  last_seen_at    timestamptz,
  last_seen_place text,
  description     text,
  found_at        timestamptz,
  created_at      timestamptz,
  distance_km     numeric,
  sightings       integer,
  mine            boolean
)
language sql
stable
security definer
set search_path = ''
as $$
  with me as (select public_location as center from public.profiles where id = auth.uid())
  select r.id, p.id, p.name, p.species, p.breed, p.photos[1], r.owner_id, o.full_name, r.status,
         r.last_seen_at, r.last_seen_place, r.description, r.found_at, r.created_at,
         case when me.center is not null
              then private.round_distance_km(extensions.st_distance(r.last_seen_location, me.center)) end,
         (select count(*)::int from public.lost_sightings s where s.report_id = r.id),
         r.owner_id = auth.uid()
  from public.lost_reports r
  join public.pets p on p.id = r.pet_id
  join public.profiles o on o.id = r.owner_id
  cross join me
  where private.is_verified()
    and not private.is_blocked_between(auth.uid(), r.owner_id)
    and (r.status = 'lost' or (r.status = 'found' and r.found_at > now() - interval '3 days') or r.owner_id = auth.uid())
    and (
      r.owner_id = auth.uid()
      or me.center is null
      or extensions.st_dwithin(r.last_seen_location, me.center, least(greatest(radius_km, 1), 50) * 1000)
    )
  order by r.status = 'lost' desc, r.created_at desc
  limit 50;
$$;

-- Map points for one report: the last-seen spot and every sighting.
create or replace function public.lost_report_points(report uuid)
returns table (kind text, sighting_id uuid, lat double precision, lng double precision, seen_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select 'last_seen', null::uuid,
         extensions.st_y(r.last_seen_location::extensions.geometry), extensions.st_x(r.last_seen_location::extensions.geometry),
         r.last_seen_at
  from public.lost_reports r
  where r.id = report and private.is_verified() and not private.is_blocked_between(auth.uid(), r.owner_id)
  union all
  select 'sighting', s.id,
         extensions.st_y(s.location::extensions.geometry), extensions.st_x(s.location::extensions.geometry),
         s.seen_at
  from public.lost_sightings s
  join public.lost_reports r on r.id = s.report_id
  where s.report_id = report and private.is_verified() and not private.is_blocked_between(auth.uid(), r.owner_id)
  order by 5;
$$;

revoke execute on function public.report_lost_pet(uuid, timestamptz, double precision, double precision, text, text, integer) from public, anon;
revoke execute on function public.add_lost_sighting(uuid, timestamptz, double precision, double precision, text, text) from public, anon;
revoke execute on function public.close_lost_report(uuid, boolean) from public, anon;
revoke execute on function public.lost_pets_nearby(integer) from public, anon;
revoke execute on function public.lost_report_points(uuid) from public, anon;
grant execute on function public.report_lost_pet(uuid, timestamptz, double precision, double precision, text, text, integer) to authenticated;
grant execute on function public.add_lost_sighting(uuid, timestamptz, double precision, double precision, text, text) to authenticated;
grant execute on function public.close_lost_report(uuid, boolean) to authenticated;
grant execute on function public.lost_pets_nearby(integer) to authenticated;
grant execute on function public.lost_report_points(uuid) to authenticated;

-- Reports left open for 30 days close on their own (daily).
select cron.schedule('close-stale-lost-reports', '15 3 * * *',
  $$update public.lost_reports set status = 'closed' where status = 'lost' and created_at < now() - interval '30 days'$$);

-- ---------------------------------------------------------------------------
-- Privileges and Row Level Security: reads only; points come from the RPC.
-- ---------------------------------------------------------------------------

revoke all on public.lost_reports from anon, authenticated;
revoke all on public.lost_sightings from anon, authenticated;

grant select (id, owner_id, pet_id, status, last_seen_at, last_seen_place, description, alert_radius_km, found_at, created_at)
  on public.lost_reports to authenticated;
grant select (id, report_id, reporter_id, seen_at, place, note, created_at)
  on public.lost_sightings to authenticated;

alter table public.lost_reports enable row level security;
alter table public.lost_sightings enable row level security;

create policy "Verified members read lost reports"
  on public.lost_reports for select
  to authenticated
  using (private.is_verified() and not private.is_blocked_between(auth.uid(), owner_id));

create policy "Verified members read sightings"
  on public.lost_sightings for select
  to authenticated
  using (
    private.is_verified()
    and exists (
      select 1 from public.lost_reports r
      where r.id = report_id and not private.is_blocked_between(auth.uid(), r.owner_id)
    )
  );

-- New sightings stream to the open report page.
alter publication supabase_realtime add table public.lost_sightings;
