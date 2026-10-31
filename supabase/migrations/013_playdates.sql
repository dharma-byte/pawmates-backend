-- Playdates (and, later, larger events), RSVPs and post-playdate reviews.
--
-- A playdate is planned from a direct chat: create_playdate() creates the
-- event, adds both people as attendees and posts an invite card into the
-- conversation. Location and address are required for every event. Only the
-- people involved can see a playdate. After it ends, attendees review how the
-- other pet got along; good reviews earn a "Good playmate" badge.

create type public.event_type as enum ('playdate', 'event');
create type public.event_status as enum ('scheduled', 'cancelled');
create type public.rsvp_status as enum ('invited', 'going', 'maybe', 'not_going', 'waitlist');

create table public.events (
  id              uuid primary key default gen_random_uuid(),
  host_id         uuid not null references public.profiles (id) on delete cascade,
  group_id        uuid,  -- foreign key added with groups
  conversation_id uuid references public.conversations (id) on delete set null,
  type            public.event_type not null,
  status          public.event_status not null default 'scheduled',
  title           text not null check (char_length(title) between 1 and 120),
  description     text check (char_length(description) <= 1000),
  starts_at       timestamptz not null,
  ends_at         timestamptz not null,
  location        extensions.geography(point, 4326) not null,
  address         text not null check (char_length(btrim(address)) > 0 and char_length(address) <= 300),
  place_name      text check (char_length(place_name) <= 120),
  capacity        integer check (capacity > 0),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  check (ends_at > starts_at),
  check (ends_at <= starts_at + interval '12 hours')
);

create index events_location_idx on public.events using gist (location);
create index events_starts_at_idx on public.events (starts_at);
create index events_conversation_idx on public.events (conversation_id);

create trigger events_set_updated_at
  before update on public.events
  for each row execute function private.set_updated_at();

create table public.event_attendees (
  event_id     uuid not null references public.events (id) on delete cascade,
  user_id      uuid not null references public.profiles (id) on delete cascade,
  status       public.rsvp_status not null,
  pet_ids      uuid[] not null default '{}',
  responded_at timestamptz,
  created_at   timestamptz not null default now(),
  primary key (event_id, user_id)
);

create index event_attendees_user_idx on public.event_attendees (user_id, status);

create table public.playdate_reviews (
  id          uuid primary key default gen_random_uuid(),
  event_id    uuid not null references public.events (id) on delete cascade,
  reviewer_id uuid not null references public.profiles (id) on delete cascade,
  pet_id      uuid not null references public.pets (id) on delete cascade,
  rating      integer not null check (rating between 1 and 5),
  comment     text check (char_length(comment) <= 500),
  created_at  timestamptz not null default now(),
  unique (event_id, reviewer_id, pet_id)
);

create index playdate_reviews_pet_idx on public.playdate_reviews (pet_id);

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

create or replace function private.is_event_participant(event uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.events where id = event and host_id = auth.uid())
      or exists (select 1 from public.event_attendees where event_id = event and user_id = auth.uid());
$$;

grant execute on function private.is_event_participant(uuid) to authenticated;

-- Post a message into a conversation on the caller's behalf.
create or replace function private.post_event_message(conv uuid, msg_body text, event uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.messages (conversation_id, sender_id, type, body, metadata)
  values (conv, auth.uid(), 'invite', msg_body, jsonb_build_object('event_id', event));
$$;

-- ---------------------------------------------------------------------------
-- Playdate RPCs
-- ---------------------------------------------------------------------------

-- Halfway point between both members of a direct chat, from their FUZZED
-- public points, for suggesting meeting spots. Never an exact location.
create or replace function public.playdate_midpoint(conv uuid)
returns table (lat double precision, lng double precision)
language sql
stable
security definer
set search_path = ''
as $$
  select extensions.st_y(mid), extensions.st_x(mid)
  from (
    select extensions.st_centroid(extensions.st_collect(p.public_location::extensions.geometry)) as mid
    from public.conversations c
    join public.profiles p on p.id in (c.user_low, c.user_high)
    where c.id = conv
      and c.type = 'direct'
      and private.is_conversation_member(conv)
      and p.public_location is not null
    having count(*) = 2
  ) m;
$$;

create or replace function public.create_playdate(
  conv            uuid,
  starts_at       timestamptz,
  duration_minutes integer,
  lat             double precision,
  lng             double precision,
  place_name      text,
  address         text,
  note            text default null,
  my_pet_ids      uuid[] default '{}'
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  me      uuid := auth.uid();
  other   uuid;
  new_id  uuid;
begin
  select case when c.user_low = me then c.user_high else c.user_low end into other
  from public.conversations c
  where c.id = conv and c.type = 'direct' and me in (c.user_low, c.user_high);

  if other is null then
    raise exception 'Playdates can be planned only from a direct chat you are in' using errcode = '42501';
  end if;
  if not private.can_post(conv) then
    raise exception 'You can''t plan a playdate with this member right now' using errcode = '42501';
  end if;
  if starts_at < now() + interval '15 minutes' or starts_at > now() + interval '90 days' then
    raise exception 'Pick a time between 15 minutes and 90 days from now' using errcode = 'P0001';
  end if;
  if duration_minutes is null or duration_minutes not between 15 and 480 then
    raise exception 'A playdate lasts between 15 minutes and 8 hours' using errcode = 'P0001';
  end if;
  if lat is null or lng is null or coalesce(btrim(address), '') = '' then
    raise exception 'Choose where to meet' using errcode = 'P0001';
  end if;
  if exists (select 1 from unnest(my_pet_ids) pid
             where not exists (select 1 from public.pets where id = pid and owner_id = me)) then
    raise exception 'my_pet_ids must be your own pets';
  end if;

  insert into public.events (host_id, conversation_id, type, title, description, starts_at, ends_at,
                             location, address, place_name)
  values (me, conv, 'playdate', 'Playdate at ' || coalesce(nullif(btrim(place_name), ''), 'the park'),
          nullif(btrim(note), ''), starts_at, starts_at + make_interval(mins => duration_minutes),
          extensions.st_point(lng, lat)::extensions.geography, btrim(address), nullif(btrim(place_name), ''))
  returning id into new_id;

  insert into public.event_attendees (event_id, user_id, status, pet_ids, responded_at)
  values (new_id, me, 'going', my_pet_ids, now()),
         (new_id, other, 'invited', '{}', null);

  perform private.post_event_message(conv, coalesce(nullif(btrim(note), ''), 'Playdate invite'), new_id);
  return new_id;
end;
$$;

create or replace function public.respond_to_playdate(event uuid, accept boolean, my_pet_ids uuid[] default '{}')
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  ev public.events;
begin
  select * into ev from public.events where id = event;
  if not found or ev.type <> 'playdate' or not private.is_event_participant(event) or ev.host_id = auth.uid() then
    raise exception 'No playdate invite for you with id %', event using errcode = '42501';
  end if;
  if ev.status = 'cancelled' or ev.starts_at <= now() then
    raise exception 'This playdate can no longer be answered' using errcode = 'P0001';
  end if;
  if exists (select 1 from unnest(my_pet_ids) pid
             where not exists (select 1 from public.pets where id = pid and owner_id = auth.uid())) then
    raise exception 'my_pet_ids must be your own pets';
  end if;

  update public.event_attendees
  set status = case when accept then 'going'::public.rsvp_status else 'not_going'::public.rsvp_status end,
      pet_ids = case when accept then my_pet_ids else '{}' end,
      responded_at = now()
  where event_id = event and user_id = auth.uid();

  if ev.conversation_id is not null then
    perform private.post_event_message(
      ev.conversation_id,
      case when accept then 'Accepted the playdate 🎉' else 'Can''t make this playdate' end,
      event);
  end if;
end;
$$;

create or replace function public.cancel_playdate(event uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  ev public.events;
begin
  select * into ev from public.events where id = event and host_id = auth.uid();
  if not found then
    raise exception 'Only the host can cancel this playdate' using errcode = '42501';
  end if;
  if ev.status = 'cancelled' then
    return;
  end if;

  update public.events set status = 'cancelled' where id = event;
  if ev.conversation_id is not null then
    perform private.post_event_message(ev.conversation_id, 'Cancelled the playdate', event);
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Reviews
-- ---------------------------------------------------------------------------

-- Review another attendee's pet after a playdate you both went to.
create or replace function public.review_playdate(event uuid, pet uuid, rating integer, comment text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  ev public.events;
begin
  select * into ev from public.events where id = event;
  if not found or not exists (
    select 1 from public.event_attendees
    where event_id = event and user_id = auth.uid() and status = 'going'
  ) then
    raise exception 'Only people who went can review this playdate' using errcode = '42501';
  end if;
  if ev.status = 'cancelled' or ev.ends_at > now() then
    raise exception 'You can review a playdate after it ends' using errcode = 'P0001';
  end if;
  if not exists (
    select 1 from public.event_attendees a
    where a.event_id = event and a.user_id <> auth.uid() and a.status = 'going' and pet = any (a.pet_ids)
  ) then
    raise exception 'That pet wasn''t at this playdate' using errcode = 'P0001';
  end if;

  insert into public.playdate_reviews (event_id, reviewer_id, pet_id, rating, comment)
  values (event, auth.uid(), pet, rating, nullif(btrim(comment), ''));
end;
$$;

-- Public summary for a pet's profile. Individual reviews stay private.
-- "Good playmate": at least one review and an average of 4 or more.
create or replace function public.pet_playmate_stats(pet uuid)
returns table (reviews integer, average_rating numeric, good_playmate boolean)
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::integer,
         round(avg(r.rating), 1),
         count(*) >= 1 and avg(r.rating) >= 4
  from public.playdate_reviews r
  where r.pet_id = pet and private.is_verified();
$$;

-- Finished playdates (last 14 days) where I still owe the other pets a review.
create or replace function public.my_pending_reviews()
returns table (event_id uuid, title text, ended_at timestamptz, pet_id uuid, pet_name text, pet_photo text)
language sql
stable
security definer
set search_path = ''
as $$
  select e.id, e.title, e.ends_at, p.id, p.name, p.photos[1]
  from public.events e
  join public.event_attendees mine on mine.event_id = e.id and mine.user_id = auth.uid() and mine.status = 'going'
  join public.event_attendees theirs on theirs.event_id = e.id and theirs.user_id <> auth.uid() and theirs.status = 'going'
  join public.pets p on p.id = any (theirs.pet_ids)
  where e.status = 'scheduled'
    and e.ends_at <= now()
    and e.ends_at > now() - interval '14 days'
    and not exists (
      select 1 from public.playdate_reviews r
      where r.event_id = e.id and r.reviewer_id = auth.uid() and r.pet_id = p.id
    )
  order by e.ends_at desc;
$$;

revoke execute on function public.playdate_midpoint(uuid) from public, anon;
revoke execute on function public.create_playdate(uuid, timestamptz, integer, double precision, double precision, text, text, text, uuid[]) from public, anon;
revoke execute on function public.respond_to_playdate(uuid, boolean, uuid[]) from public, anon;
revoke execute on function public.cancel_playdate(uuid) from public, anon;
revoke execute on function public.review_playdate(uuid, uuid, integer, text) from public, anon;
revoke execute on function public.pet_playmate_stats(uuid) from public, anon;
revoke execute on function public.my_pending_reviews() from public, anon;
grant execute on function public.playdate_midpoint(uuid) to authenticated;
grant execute on function public.create_playdate(uuid, timestamptz, integer, double precision, double precision, text, text, text, uuid[]) to authenticated;
grant execute on function public.respond_to_playdate(uuid, boolean, uuid[]) to authenticated;
grant execute on function public.cancel_playdate(uuid) to authenticated;
grant execute on function public.review_playdate(uuid, uuid, integer, text) to authenticated;
grant execute on function public.pet_playmate_stats(uuid) to authenticated;
grant execute on function public.my_pending_reviews() to authenticated;

-- ---------------------------------------------------------------------------
-- Privileges and Row Level Security: reads only; all writes go through RPCs.
-- ---------------------------------------------------------------------------

revoke all on public.events from anon, authenticated;
revoke all on public.event_attendees from anon, authenticated;
revoke all on public.playdate_reviews from anon, authenticated;

grant select (
  id, host_id, group_id, conversation_id, type, status, title, description, starts_at, ends_at,
  address, place_name, capacity, created_at
) on public.events to authenticated;
grant select on public.event_attendees to authenticated;
grant select on public.playdate_reviews to authenticated;

alter table public.events enable row level security;
alter table public.event_attendees enable row level security;
alter table public.playdate_reviews enable row level security;

create policy "Participants read their events"
  on public.events for select
  to authenticated
  using (private.is_event_participant(id));

create policy "Participants see who is attending"
  on public.event_attendees for select
  to authenticated
  using (private.is_event_participant(event_id));

-- A review is visible to its author and to the reviewed pet's owner.
create policy "Reviewers and pet owners read reviews"
  on public.playdate_reviews for select
  to authenticated
  using (
    reviewer_id = auth.uid()
    or exists (select 1 from public.pets where id = playdate_reviews.pet_id and owner_id = auth.uid())
  );

-- The map point for an event (column privileges hide the raw geography).
create or replace function public.event_location(event uuid)
returns table (lat double precision, lng double precision)
language sql
stable
security definer
set search_path = ''
as $$
  select extensions.st_y(location::extensions.geometry), extensions.st_x(location::extensions.geometry)
  from public.events
  where id = event and private.is_event_participant(event);
$$;

revoke execute on function public.event_location(uuid) from public, anon;
grant execute on function public.event_location(uuid) to authenticated;

-- Attendee changes stream to open chats so invite cards update live.
alter publication supabase_realtime add table public.event_attendees;
