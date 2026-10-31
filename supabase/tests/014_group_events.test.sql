begin;
create extension if not exists pgtap with schema extensions;
select plan(17);

-- Start from an empty database (rolled back at the end).
delete from auth.users;

-- alice runs a group; bob, carol and dave are verified neighbours (not members).
insert into auth.users (id, email, email_confirmed_at) values
  ('11111111-1111-1111-1111-111111111111', 'alice@test.dev', now()),
  ('22222222-2222-2222-2222-222222222222', 'bob@test.dev',   now()),
  ('33333333-3333-3333-3333-333333333333', 'carol@test.dev', now()),
  ('55555555-5555-5555-5555-555555555555', 'dave@test.dev',  now());
update public.profiles set verification_status = 'verified',
  location = extensions.st_point(77.6408, 12.9784)::extensions.geography;
insert into public.pets (id, owner_id, name, species) values
  ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Bruno', 'dog'),
  ('bbbbbbbb-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'Luna', 'dog');

create temporary table ids (name text primary key, id uuid);
grant all on ids to authenticated;

set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
insert into ids select 'g', public.create_group('Cubbon Walkers', 'area');
insert into ids select 'chat', id from public.conversations where group_id = (select id from ids where name = 'g');

-- --------------------------------------------------------------- hosting
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222"}';
select throws_ok(
  format($$ select public.create_group_event('%s', 'Walk', now() + interval '1 day', 60, 12.97, 77.59, 'Cubbon Park', 'Kasturba Rd') $$,
         (select id from ids where name = 'g')),
  '42501', null,
  'Only members host events'
);

set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
select throws_ok(
  format($$ select public.create_group_event('%s', 'Walk', now() + interval '10 minutes', 60, 12.97, 77.59, 'Cubbon Park', 'Kasturba Rd') $$,
         (select id from ids where name = 'g')),
  'P0001', null,
  'Events start at least 30 minutes ahead'
);

insert into ids select 'ev', public.create_group_event(
  (select id from ids where name = 'g'), 'Sunday pack walk', now() + interval '2 days', 90,
  12.9763, 77.5929, 'Cubbon Park', 'Kasturba Rd, Bengaluru', 'Leashes on, treats welcome', 2,
  '{aaaaaaaa-0000-0000-0000-000000000001}');

select is(
  (select status::text from public.event_attendees
   where event_id = (select id from ids where name = 'ev') and user_id = '11111111-1111-1111-1111-111111111111'),
  'going',
  'The host is going'
);

select is(
  (select type::text || ':' || body from public.messages
   where conversation_id = (select id from ids where name = 'chat') order by created_at desc limit 1),
  'invite:New event: Sunday pack walk',
  'The event is announced in the group chat'
);

-- ---------------------------------------------------- RSVPs and waitlist
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222"}';
select is(
  (select count(*)::int from public.upcoming_events()),
  1,
  'Neighbours see the event before joining'
);
select ok(
  (select lat between 12.97 and 12.98 from public.event_location((select id from ids where name = 'ev'))),
  'Verified members see where the event is'
);
select is(
  public.rsvp_event((select id from ids where name = 'ev'), 'going', '{bbbbbbbb-0000-0000-0000-000000000001}')::text,
  'going',
  'Bob is going'
);
select ok(
  private.is_group_member((select id from ids where name = 'g')),
  'RSVPing joins the group'
);

set local request.jwt.claims = '{"sub":"33333333-3333-3333-3333-333333333333"}';
select is(public.rsvp_event((select id from ids where name = 'ev'), 'going')::text, 'waitlist', 'A full event waitlists carol');

set local request.jwt.claims = '{"sub":"55555555-5555-5555-5555-555555555555"}';
select is(public.rsvp_event((select id from ids where name = 'ev'), 'going')::text, 'waitlist', 'Dave waits behind carol');

set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222"}';
select is(public.rsvp_event((select id from ids where name = 'ev'), 'not_going')::text, 'not_going', 'Bob drops out');

set local request.jwt.claims = '{"sub":"33333333-3333-3333-3333-333333333333"}';
select is(
  (select my_status::text || ':' || going_count || ':' || waitlist_count from public.upcoming_events()),
  'going:2:1',
  'Carol moves up from the waitlist; dave still waits'
);
select is(public.rsvp_event((select id from ids where name = 'ev'), 'going')::text, 'going', 'Answering going again keeps her spot');

set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
select throws_ok(
  format($$ select public.rsvp_event('%s', 'not_going') $$, (select id from ids where name = 'ev')),
  'P0001', null,
  'Hosts cancel instead of RSVPing no'
);

-- ------------------------------------------------------------ cancelling
set local request.jwt.claims = '{"sub":"55555555-5555-5555-5555-555555555555"}';
select throws_ok(
  format($$ select public.cancel_event('%s') $$, (select id from ids where name = 'ev')),
  '42501', null,
  'Guests cannot cancel'
);

set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
select public.cancel_event((select id from ids where name = 'ev'));
select is(
  (select status::text from public.upcoming_events()),
  'cancelled',
  'The host cancels the event'
);

set local request.jwt.claims = '{"sub":"55555555-5555-5555-5555-555555555555"}';
select throws_ok(
  format($$ select public.rsvp_event('%s', 'going') $$, (select id from ids where name = 'ev')),
  'P0001', null,
  'A cancelled event takes no RSVPs'
);

select * from finish();
rollback;
