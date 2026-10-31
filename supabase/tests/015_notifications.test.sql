begin;
create extension if not exists pgtap with schema extensions;
select plan(13);

-- Start from an empty database (rolled back at the end).
delete from auth.users;

insert into auth.users (id, email, email_confirmed_at) values
  ('11111111-1111-1111-1111-111111111111', 'alice@test.dev', now()),
  ('22222222-2222-2222-2222-222222222222', 'bob@test.dev',   now()),
  ('33333333-3333-3333-3333-333333333333', 'carol@test.dev', now());
update public.profiles set verification_status = 'verified',
  location = extensions.st_point(77.6408, 12.9784)::extensions.geography;
update public.profiles set full_name = 'Alice' where id = '11111111-1111-1111-1111-111111111111';
update public.profiles set full_name = 'Bob'   where id = '22222222-2222-2222-2222-222222222222';
insert into public.pets (id, owner_id, name, species) values
  ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Bruno', 'dog');

create temporary table ids (name text primary key, id uuid);
grant all on ids to authenticated;

set local role authenticated;

-- ------------------------------------------------------------- Sniff requests
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
insert into public.connections (addressee_id, pet_id, message)
values ('22222222-2222-2222-2222-222222222222', 'aaaaaaaa-0000-0000-0000-000000000001', 'Walk?');

select is(
  (select count(*)::int from public.notifications),
  0,
  'Senders get no notification for their own request'
);

set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222"}';
select is(
  (select type::text || '|' || title || '|' || link from public.notifications),
  'sniff_request|Alice sent you a Sniff request|/requests',
  'The addressee is told about the Sniff request'
);
select public.respond_to_sniff((select id from public.connections limit 1), true);

set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
select is(
  (select title from public.notifications where type = 'sniff_accepted'),
  'Bob accepted your Sniff request',
  'The sender hears it was accepted'
);

set local request.jwt.claims = '{"sub":"33333333-3333-3333-3333-333333333333"}';
select is((select count(*)::int from public.notifications), 0, 'Members never see others'' notifications');

-- ------------------------------------------------------------- group events
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
insert into ids select 'g', public.create_group('Morning Walkers', 'area');
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222"}';
select public.join_group((select id from ids where name = 'g'));
set local request.jwt.claims = '{"sub":"33333333-3333-3333-3333-333333333333"}';
select public.join_group((select id from ids where name = 'g'));

set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
insert into ids select 'ev', public.create_group_event(
  (select id from ids where name = 'g'), 'Park day', now() + interval '2 days', 60,
  12.97, 77.59, 'Cubbon Park', 'Kasturba Rd', null, 2);
select is((select count(*)::int from public.notifications where type = 'event_new'), 0, 'The host is not told about their own event');

set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222"}';
select is(
  (select title || '|' || link from public.notifications where type = 'event_new'),
  'New event in Morning Walkers: Park day|/groups/' || (select id from ids where name = 'g'),
  'Group members are told about new events'
);

-- Capacity 2: alice + bob going, carol waits; bob drops out, carol moves up.
select public.rsvp_event((select id from ids where name = 'ev'), 'going');
set local request.jwt.claims = '{"sub":"33333333-3333-3333-3333-333333333333"}';
select public.rsvp_event((select id from ids where name = 'ev'), 'going');
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222"}';
select public.rsvp_event((select id from ids where name = 'ev'), 'not_going');

set local request.jwt.claims = '{"sub":"33333333-3333-3333-3333-333333333333"}';
select is(
  (select title from public.notifications where type = 'waitlist_promoted'),
  'A spot opened up: you''re going to Park day',
  'Promotion from the waitlist is announced'
);

-- --------------------------------------------------------------- reminders
reset role;
update public.events set starts_at = now() + interval '90 minutes', ends_at = now() + interval '150 minutes'
  where id = (select id from ids where name = 'ev');
select private.send_event_reminders();
select private.send_event_reminders();

select is(
  (select count(*)::int from public.notifications where type = 'event_reminder'),
  2,
  'Going attendees (host and carol) get one reminder each, even if the job runs twice'
);
select is(
  (select count(*)::int from public.notifications
   where type = 'event_reminder' and user_id = '22222222-2222-2222-2222-222222222222'),
  0,
  'People not going get no reminder'
);
select ok(
  (select title like 'Starting soon:%' from public.notifications where type = 'event_reminder' limit 1),
  'Reminders under 2 hours say it starts soon'
);

-- ---------------------------------------------------------------- cancelling
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
select public.cancel_event((select id from ids where name = 'ev'));

set local request.jwt.claims = '{"sub":"33333333-3333-3333-3333-333333333333"}';
select is(
  (select title from public.notifications where type = 'event_cancelled'),
  'Event cancelled: Park day',
  'Attendees hear about cancellations'
);

-- ---------------------------------------------------------------- reading
select public.mark_notifications_read();
select is(
  (select count(*)::int from public.notifications where read_at is null),
  0,
  'Mark all read'
);
select throws_ok(
  $$ update public.notifications set title = 'x' $$,
  '42501', null,
  'Notifications cannot be edited by members'
);

select * from finish();
rollback;
