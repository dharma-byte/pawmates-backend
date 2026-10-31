-- In-app notifications and event reminders.
--
-- Triggers write a notification when something happens that a member should
-- know about; clients stream their own rows through Realtime to drive the
-- bell. A pg_cron job sends reminders before playdates and events and clears
-- notifications older than 60 days. Chat messages are not notifications:
-- unread counts already cover them.

create type public.notification_type as enum (
  'sniff_request',      -- someone sent me a Sniff request
  'sniff_accepted',     -- my Sniff request was accepted
  'playdate_invite',    -- I was invited to a playdate
  'event_new',          -- a new event in one of my groups
  'event_cancelled',    -- an event or playdate I was going to was cancelled
  'waitlist_promoted',  -- a spot opened and I'm now going
  'event_reminder'      -- an event or playdate I'm going to starts soon
);

create table public.notifications (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.profiles (id) on delete cascade,
  type       public.notification_type not null,
  actor_id   uuid references public.profiles (id) on delete cascade,
  title      text not null check (char_length(title) <= 200),
  body       text check (char_length(body) <= 500),
  link       text check (link like '/%'),
  -- One notification per key and member (reminders must not repeat).
  dedupe_key text,
  read_at    timestamptz,
  created_at timestamptz not null default now(),
  unique (user_id, dedupe_key)
);

create index notifications_user_created_idx on public.notifications (user_id, created_at desc);

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

create or replace function private.notify(
  recipient uuid,
  kind      public.notification_type,
  title     text,
  body      text,
  link      text,
  actor     uuid default null,
  dedupe    text default null
)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.notifications (user_id, type, actor_id, title, body, link, dedupe_key)
  select recipient, kind, actor, left(title, 200), left(body, 500), link, dedupe
  where recipient is distinct from actor
  on conflict (user_id, dedupe_key) do nothing;
$$;

create or replace function private.display_name(person uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(nullif(btrim(full_name), ''), 'A Pawmates member') from public.profiles where id = person;
$$;

-- "Sat 2 Nov, 7:30 am" in India time, for notification text.
create or replace function private.event_time_label(at timestamptz)
returns text
language sql
immutable
set search_path = ''
as $$
  select btrim(to_char(at at time zone 'Asia/Kolkata', 'Dy FMDD Mon, FMHH12:MI am'));
$$;

-- ---------------------------------------------------------------------------
-- Sniff requests
-- ---------------------------------------------------------------------------

create or replace function private.connections_notify()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  pet_name text;
begin
  if tg_op = 'INSERT' and new.status = 'pending' then
    select name into pet_name from public.pets where id = new.pet_id;
    perform private.notify(
      new.addressee_id, 'sniff_request',
      private.display_name(new.requester_id) || ' sent you a Sniff request',
      coalesce(pet_name || ' wants to meet your pet. ', '') || coalesce('“' || new.message || '”', ''),
      '/requests', new.requester_id, 'sniff:' || new.id);
  elsif tg_op = 'UPDATE' and new.status = 'accepted' and old.status <> 'accepted' then
    perform private.notify(
      new.requester_id, 'sniff_accepted',
      private.display_name(new.addressee_id) || ' accepted your Sniff request',
      'You''re Pawmates now. Say hi and plan a playdate!',
      '/friends', new.addressee_id, 'sniff-accepted:' || new.id);
  end if;
  return new;
end;
$$;

create trigger connections_notify
  after insert or update of status on public.connections
  for each row execute function private.connections_notify();

-- ---------------------------------------------------------------------------
-- Playdates and events
-- ---------------------------------------------------------------------------

-- Where to send people for an event: its chat for playdates, its group page
-- for group events.
create or replace function private.event_link(ev public.events)
returns text
language sql
stable
set search_path = ''
as $$
  select case
    when ev.group_id is not null then '/groups/' || ev.group_id
    when ev.conversation_id is not null then '/chat/' || ev.conversation_id
  end;
$$;

-- New group event: tell the group (except the host).
create or replace function private.events_after_insert_notify()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.type = 'event' and new.group_id is not null then
    perform private.notify(
      gm.user_id, 'event_new',
      'New event in ' || g.name || ': ' || new.title,
      private.event_time_label(new.starts_at) || coalesce(' · ' || new.place_name, ''),
      private.event_link(new), new.host_id, 'event-new:' || new.id)
    from public.group_members gm
    join public.groups g on g.id = gm.group_id
    where gm.group_id = new.group_id;
  end if;
  return new;
end;
$$;

create trigger events_after_insert_notify
  after insert on public.events
  for each row execute function private.events_after_insert_notify();

-- Cancelled: tell everyone who was invited, going, maybe or waiting.
create or replace function private.events_after_cancel_notify()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.notify(
    a.user_id, 'event_cancelled',
    initcap(new.type::text) || ' cancelled: ' || new.title,
    private.display_name(new.host_id) || ' cancelled the ' || new.type::text || ' on '
      || private.event_time_label(new.starts_at) || '.',
    private.event_link(new), new.host_id, 'event-cancelled:' || new.id)
  from public.event_attendees a
  where a.event_id = new.id and a.status in ('invited', 'going', 'maybe', 'waitlist');
  return new;
end;
$$;

create trigger events_after_cancel_notify
  after update of status on public.events
  for each row
  when (new.status = 'cancelled' and old.status <> 'cancelled')
  execute function private.events_after_cancel_notify();

-- Playdate invites and waitlist promotions.
create or replace function private.event_attendees_notify()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  ev public.events;
begin
  select * into ev from public.events where id = new.event_id;

  if tg_op = 'INSERT' and new.status = 'invited' then
    perform private.notify(
      new.user_id, 'playdate_invite',
      private.display_name(ev.host_id) || ' invited you to a playdate',
      private.event_time_label(ev.starts_at) || coalesce(' · ' || ev.place_name, ''),
      private.event_link(ev), ev.host_id, 'invite:' || ev.id);
  elsif tg_op = 'UPDATE' and old.status = 'waitlist' and new.status = 'going' then
    perform private.notify(
      new.user_id, 'waitlist_promoted',
      'A spot opened up: you''re going to ' || ev.title,
      private.event_time_label(ev.starts_at) || coalesce(' · ' || ev.place_name, ''),
      private.event_link(ev), null, 'promoted:' || ev.id);
  end if;
  return new;
end;
$$;

create trigger event_attendees_notify
  after insert or update of status on public.event_attendees
  for each row execute function private.event_attendees_notify();

-- ---------------------------------------------------------------------------
-- Reminders and cleanup (pg_cron, every 10 minutes)
--   "tomorrow"  once, when a scheduled event is 3 to 24 hours away
--   "soon"      once, when it is less than 2 hours away
-- Only people going get reminders.
-- ---------------------------------------------------------------------------

create or replace function private.send_event_reminders()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.notify(
    a.user_id, 'event_reminder',
    case when e.starts_at < now() + interval '2 hours'
         then 'Starting soon: ' || e.title
         else 'Coming up: ' || e.title end,
    private.event_time_label(e.starts_at) || ' · ' || coalesce(e.place_name, e.address)
      || '. Bring water and a leash!',
    private.event_link(e), null,
    case when e.starts_at < now() + interval '2 hours' then 'remind-soon:' else 'remind-day:' end || e.id)
  from public.events e
  join public.event_attendees a on a.event_id = e.id and a.status = 'going'
  where e.status = 'scheduled'
    and e.starts_at > now()
    and (
      e.starts_at < now() + interval '2 hours'
      or e.starts_at between now() + interval '3 hours' and now() + interval '24 hours'
    );

  delete from public.notifications where created_at < now() - interval '60 days';
end;
$$;

select cron.schedule('event-reminders', '*/10 * * * *', 'select private.send_event_reminders()');

-- ---------------------------------------------------------------------------
-- RPCs
-- ---------------------------------------------------------------------------

-- Mark some (or, with no ids, all) of my notifications read.
create or replace function public.mark_notifications_read(ids uuid[] default null)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.notifications
  set read_at = now()
  where user_id = auth.uid()
    and read_at is null
    and (ids is null or id = any (ids));
$$;

revoke execute on function public.mark_notifications_read(uuid[]) from public, anon;
grant execute on function public.mark_notifications_read(uuid[]) to authenticated;

-- ---------------------------------------------------------------------------
-- Privileges and Row Level Security: members read their own; writes are
-- triggers and RPCs only.
-- ---------------------------------------------------------------------------

revoke all on public.notifications from anon, authenticated;
grant select on public.notifications to authenticated;

alter table public.notifications enable row level security;

create policy "Members read their own notifications"
  on public.notifications for select
  to authenticated
  using (user_id = auth.uid());

alter publication supabase_realtime add table public.notifications;
