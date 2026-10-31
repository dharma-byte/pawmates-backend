-- Group events: walks, meetups and park days hosted inside a group.
--
-- Any group member can host. The event is announced with a card in the group
-- chat. Group events are public to verified members (groups are open), and
-- RSVPing joins the group. When an event has a capacity, extra "going" RSVPs
-- go to a waitlist, and the first person waiting moves up when a spot frees.
-- Playdates (013) stay private to their two participants.

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Can the current user see this event? Participants always; any verified
-- member for group events.
create or replace function private.can_see_event(event uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.is_event_participant(event)
      or (private.is_verified()
          and exists (select 1 from public.events where id = event and group_id is not null));
$$;

grant execute on function private.can_see_event(uuid) to authenticated;

-- Fill free spots from the waitlist, oldest RSVP first.
create or replace function private.promote_waitlist(event uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  cap   integer;
  going integer;
begin
  select capacity into cap from public.events where id = event;
  if cap is null then
    update public.event_attendees set status = 'going'
    where event_id = event and status = 'waitlist';
    return;
  end if;

  select count(*) into going from public.event_attendees where event_id = event and status = 'going';
  update public.event_attendees set status = 'going'
  where event_id = event and user_id in (
    select user_id from public.event_attendees
    where event_id = event and status = 'waitlist'
    order by responded_at, created_at
    limit greatest(cap - going, 0)
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- RPCs
-- ---------------------------------------------------------------------------

create or replace function public.create_group_event(
  g                uuid,
  title            text,
  starts_at        timestamptz,
  duration_minutes integer,
  lat              double precision,
  lng              double precision,
  place_name       text,
  address          text,
  description      text default null,
  capacity         integer default null,
  my_pet_ids       uuid[] default '{}'
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  me     uuid := auth.uid();
  conv   uuid;
  new_id uuid;
begin
  if not private.is_verified() or not private.is_group_member(g) then
    raise exception 'Join the group to host an event in it' using errcode = '42501';
  end if;
  if starts_at < now() + interval '30 minutes' or starts_at > now() + interval '180 days' then
    raise exception 'Pick a start time between 30 minutes and 6 months from now' using errcode = 'P0001';
  end if;
  if duration_minutes not between 15 and 480 then
    raise exception 'Events last between 15 minutes and 8 hours' using errcode = 'P0001';
  end if;
  if capacity is not null and capacity not between 2 and 500 then
    raise exception 'Capacity must be between 2 and 500' using errcode = 'P0001';
  end if;
  if (select count(*) from public.events e where e.host_id = me and e.type = 'event'
        and e.created_at > now() - interval '1 day') >= 5 then
    raise exception 'You can create up to 5 events a day' using errcode = 'P0001';
  end if;
  if exists (select 1 from unnest(my_pet_ids) pid
             where not exists (select 1 from public.pets where id = pid and owner_id = me)) then
    raise exception 'my_pet_ids must be your own pets';
  end if;

  select id into conv from public.conversations where type = 'group' and group_id = g;

  insert into public.events (
    host_id, group_id, conversation_id, type, title, description, starts_at, ends_at,
    location, address, place_name, capacity
  ) values (
    me, g, conv, 'event', btrim(title), nullif(btrim(description), ''), starts_at,
    starts_at + make_interval(mins => duration_minutes),
    extensions.st_point(lng, lat)::extensions.geography,
    btrim(address), nullif(btrim(place_name), ''), capacity
  )
  returning id into new_id;

  insert into public.event_attendees (event_id, user_id, status, pet_ids, responded_at)
  values (new_id, me, 'going', my_pet_ids, now());

  if conv is not null then
    perform private.post_event_message(conv, 'New event: ' || btrim(title), new_id);
  end if;
  return new_id;
end;
$$;

-- RSVP going, maybe or not going. Joins the group if needed. Going past
-- capacity puts you on the waitlist. Returns your resulting status.
create or replace function public.rsvp_event(event uuid, answer public.rsvp_status, my_pet_ids uuid[] default '{}')
returns public.rsvp_status
language plpgsql
security definer
set search_path = ''
as $$
declare
  me     uuid := auth.uid();
  ev     public.events;
  result public.rsvp_status := answer;
  was    public.rsvp_status;
begin
  if answer not in ('going', 'maybe', 'not_going') then
    raise exception 'Answer going, maybe or not_going';
  end if;
  select * into ev from public.events where id = event and type = 'event' and group_id is not null;
  if not found or not private.is_verified() then
    raise exception 'Event not found' using errcode = 'P0002';
  end if;
  if ev.status = 'cancelled' or ev.ends_at <= now() then
    raise exception 'This event is no longer taking RSVPs' using errcode = 'P0001';
  end if;
  if ev.host_id = me then
    raise exception 'You''re hosting this event. Cancel it instead if you can''t go.' using errcode = 'P0001';
  end if;
  if exists (select 1 from unnest(my_pet_ids) pid
             where not exists (select 1 from public.pets where id = pid and owner_id = me)) then
    raise exception 'my_pet_ids must be your own pets';
  end if;

  insert into public.group_members (group_id, user_id) values (ev.group_id, me)
  on conflict do nothing;

  select status into was from public.event_attendees where event_id = event and user_id = me;
  if answer = 'going' and was is distinct from 'going' and ev.capacity is not null
     and (select count(*) from public.event_attendees where event_id = event and status = 'going') >= ev.capacity then
    result := 'waitlist';
  end if;
  if answer = 'going' and was in ('going', 'waitlist') then
    result := was;  -- keep my place
  end if;

  insert into public.event_attendees (event_id, user_id, status, pet_ids, responded_at)
  values (event, me, result, case when answer = 'not_going' then '{}' else my_pet_ids end, clock_timestamp())
  on conflict (event_id, user_id) do update
  set status = excluded.status,
      pet_ids = excluded.pet_ids,
      responded_at = case when public.event_attendees.status = excluded.status
                          then public.event_attendees.responded_at else excluded.responded_at end;

  if was = 'going' and result <> 'going' then
    perform private.promote_waitlist(event);
  end if;
  return result;
end;
$$;

-- The host or a group admin cancels; the group chat is told.
create or replace function public.cancel_event(event uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  ev public.events;
begin
  select * into ev from public.events where id = event and type = 'event';
  if not found
     or (ev.host_id <> auth.uid() and coalesce(private.group_role(ev.group_id), '') not in ('owner', 'admin')) then
    raise exception 'Only the host or a group admin can cancel this event' using errcode = '42501';
  end if;
  if ev.status = 'cancelled' then
    return;
  end if;

  update public.events set status = 'cancelled' where id = event;
  if ev.conversation_id is not null then
    perform private.post_event_message(ev.conversation_id, 'Cancelled the event: ' || ev.title, event);
  end if;
end;
$$;

-- Upcoming group events: one group's, or those in my groups or within
-- radius_km of me. Counts, my RSVP and a rounded distance included.
create or replace function public.upcoming_events(group_filter uuid default null, radius_km integer default 25)
returns table (
  id            uuid,
  group_id      uuid,
  group_name    text,
  host_id       uuid,
  title         text,
  description   text,
  status        public.event_status,
  starts_at     timestamptz,
  ends_at       timestamptz,
  place_name    text,
  address       text,
  capacity      integer,
  going_count   integer,
  waitlist_count integer,
  my_status     public.rsvp_status,
  distance_km   numeric
)
language sql
stable
security definer
set search_path = ''
as $$
  with me as (
    select public_location as center from public.profiles where id = auth.uid()
  )
  select
    e.id, e.group_id, g.name, e.host_id, e.title, e.description, e.status, e.starts_at, e.ends_at,
    e.place_name, e.address, e.capacity,
    (select count(*)::int from public.event_attendees a where a.event_id = e.id and a.status = 'going'),
    (select count(*)::int from public.event_attendees a where a.event_id = e.id and a.status = 'waitlist'),
    (select a.status from public.event_attendees a where a.event_id = e.id and a.user_id = auth.uid()),
    case when me.center is not null
         then private.round_distance_km(extensions.st_distance(e.location, me.center)) end
  from public.events e
  join public.groups g on g.id = e.group_id
  cross join me
  where private.is_verified()
    and e.type = 'event'
    and e.ends_at > now()
    and not private.is_blocked_between(auth.uid(), e.host_id)
    and (
      (group_filter is not null and e.group_id = group_filter)
      or (group_filter is null and (
            private.is_group_member(e.group_id)
            or me.center is null
            or extensions.st_dwithin(e.location, me.center, least(greatest(radius_km, 1), 100) * 1000)))
    )
  order by e.starts_at
  limit 50;
$$;

-- Events and playdates share one map-point function.
create or replace function public.event_location(event uuid)
returns table (lat double precision, lng double precision)
language sql
stable
security definer
set search_path = ''
as $$
  select extensions.st_y(location::extensions.geometry), extensions.st_x(location::extensions.geometry)
  from public.events
  where id = event and private.can_see_event(event);
$$;

-- Review prompts stay for playdates: a big meetup shouldn't ask for dozens.
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
  where e.type = 'playdate'
    and e.status = 'scheduled'
    and e.ends_at <= now()
    and e.ends_at > now() - interval '14 days'
    and not exists (
      select 1 from public.playdate_reviews r
      where r.event_id = e.id and r.reviewer_id = auth.uid() and r.pet_id = p.id
    )
  order by e.ends_at desc;
$$;

revoke execute on function public.create_group_event(uuid, text, timestamptz, integer, double precision, double precision, text, text, text, integer, uuid[]) from public, anon;
revoke execute on function public.rsvp_event(uuid, public.rsvp_status, uuid[]) from public, anon;
revoke execute on function public.cancel_event(uuid) from public, anon;
revoke execute on function public.upcoming_events(uuid, integer) from public, anon;
grant execute on function public.create_group_event(uuid, text, timestamptz, integer, double precision, double precision, text, text, text, integer, uuid[]) to authenticated;
grant execute on function public.rsvp_event(uuid, public.rsvp_status, uuid[]) to authenticated;
grant execute on function public.cancel_event(uuid) to authenticated;
grant execute on function public.upcoming_events(uuid, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- Row Level Security: group events and their guest lists are visible to
-- verified members; playdates keep their participant-only policies.
-- ---------------------------------------------------------------------------

create policy "Verified members read group events"
  on public.events for select
  to authenticated
  using (group_id is not null and private.is_verified());

create policy "Verified members see group event guests"
  on public.event_attendees for select
  to authenticated
  using (private.can_see_event(event_id));
