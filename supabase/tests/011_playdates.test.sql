begin;
create extension if not exists pgtap with schema extensions;
select plan(21);

-- Start from an empty database: dev data from manual testing must not leak into
-- counts. Everything is rolled back at the end, so real local data is untouched.
delete from auth.users;

-- alice + bob are Pawmates with a chat; dave is a verified outsider.
insert into auth.users (id, email, email_confirmed_at) values
  ('11111111-1111-1111-1111-111111111111', 'alice@test.dev', now()),
  ('22222222-2222-2222-2222-222222222222', 'bob@test.dev',   now()),
  ('55555555-5555-5555-5555-555555555555', 'dave@test.dev',  now());
update public.profiles set verification_status = 'verified';
update public.profiles set location = extensions.st_point(77.6408, 12.9784)::extensions.geography
  where id = '11111111-1111-1111-1111-111111111111';
update public.profiles set location = extensions.st_point(77.6408, 12.9964)::extensions.geography
  where id = '22222222-2222-2222-2222-222222222222';
insert into public.pets (id, owner_id, name, species) values
  ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Bruno', 'dog'),
  ('bbbbbbbb-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'Luna', 'dog');
insert into public.connections (requester_id, addressee_id, status) values
  ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', 'accepted');

create temporary table ids (name text primary key, id uuid);
grant all on ids to authenticated;

-- ---------------------------------------------------------------- alice plans
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
insert into ids values ('chat', public.get_or_create_direct_conversation('22222222-2222-2222-2222-222222222222'));

select ok(
  (select lat between 12.97 and 13.01 from public.playdate_midpoint((select id from ids where name = 'chat'))),
  'Midpoint lies between the two members'
);

select throws_ok(
  format($$ select public.create_playdate('%s', now() + interval '5 minutes', 60, 12.98, 77.64, 'Park', 'Park Road') $$,
         (select id from ids where name = 'chat')),
  'P0001', 'Pick a time between 15 minutes and 90 days from now',
  'A playdate must be at least 15 minutes ahead'
);

select throws_ok(
  format($$ select public.create_playdate('%s', now() + interval '1 day', 60, 12.98, 77.64, 'Park', '  ') $$,
         (select id from ids where name = 'chat')),
  'P0001', 'Choose where to meet',
  'A playdate needs an address'
);

select throws_ok(
  format($$ select public.create_playdate('%s', now() + interval '1 day', 60, 12.98, 77.64, 'Park', 'Road', null, '{bbbbbbbb-0000-0000-0000-000000000001}') $$,
         (select id from ids where name = 'chat')),
  'P0001', null,
  'You can only bring your own pets'
);

insert into ids select 'pd', public.create_playdate(
  (select id from ids where name = 'chat'), now() + interval '1 day', 90, 12.9871, 77.6408,
  'Defence Colony Park', '100 Feet Rd, Indiranagar', 'Zoomies at the park?', '{aaaaaaaa-0000-0000-0000-000000000001}');

select isnt((select id from ids where name = 'pd'), null, 'Alice plans a playdate from chat');

select is(
  (select type::text || ':' || (metadata ->> 'event_id') from public.messages
     where conversation_id = (select id from ids where name = 'chat') order by created_at desc limit 1),
  'invite:' || (select id from ids where name = 'pd'),
  'An invite card is posted into the chat'
);

select is(
  (select status::text from public.event_attendees
     where event_id = (select id from ids where name = 'pd') and user_id = '22222222-2222-2222-2222-222222222222'),
  'invited',
  'Bob is invited'
);

select throws_ok(
  format($$ select public.respond_to_playdate('%s', true) $$, (select id from ids where name = 'pd')),
  '42501', null,
  'The host cannot answer their own invite'
);

select ok(
  (select lat between 12.98 and 12.99 from public.event_location((select id from ids where name = 'pd'))),
  'Participants can see the meeting point'
);

-- ---------------------------------------------------------------- outsider
set local request.jwt.claims = '{"sub":"55555555-5555-5555-5555-555555555555"}';

select is((select count(*)::int from public.events), 0, 'Outsiders cannot see the playdate');
select is((select count(*)::int from public.event_location((select id from ids where name = 'pd'))), 0,
  'Outsiders cannot see the meeting point');
select throws_ok(
  format($$ select public.respond_to_playdate('%s', true) $$, (select id from ids where name = 'pd')),
  '42501', null,
  'Outsiders cannot answer the invite'
);
select is((select count(*)::int from public.playdate_midpoint((select id from ids where name = 'chat'))), 0,
  'Outsiders get no midpoint for a chat they are not in');

-- ---------------------------------------------------------------- bob accepts
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222"}';

select lives_ok(
  format($$ select public.respond_to_playdate('%s', true, '{bbbbbbbb-0000-0000-0000-000000000001}') $$,
         (select id from ids where name = 'pd')),
  'Bob accepts and brings Luna'
);

select is(
  (select status::text from public.event_attendees
     where event_id = (select id from ids where name = 'pd') and user_id = auth.uid()),
  'going',
  'Bob is now going'
);

select throws_ok(
  format($$ select public.review_playdate('%s', 'aaaaaaaa-0000-0000-0000-000000000001', 5) $$,
         (select id from ids where name = 'pd')),
  'P0001', 'You can review a playdate after it ends',
  'No reviews before the playdate ends'
);

-- ---------------------------------------------------------------- after the playdate
reset role;
update public.events set starts_at = now() - interval '3 hours', ends_at = now() - interval '1 hour'
  where id = (select id from ids where name = 'pd');
set local role authenticated;
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222"}';

select is(
  (select pet_name from public.my_pending_reviews()),
  'Bruno',
  'Bob is asked how Bruno got along'
);

select lives_ok(
  format($$ select public.review_playdate('%s', 'aaaaaaaa-0000-0000-0000-000000000001', 5, 'Lovely boy') $$,
         (select id from ids where name = 'pd')),
  'Bob reviews Bruno'
);

select throws_ok(
  format($$ select public.review_playdate('%s', 'bbbbbbbb-0000-0000-0000-000000000001', 5) $$,
         (select id from ids where name = 'pd')),
  'P0001', null,
  'You cannot review your own pet'
);

set local request.jwt.claims = '{"sub":"55555555-5555-5555-5555-555555555555"}';

select is(
  (select good_playmate from public.pet_playmate_stats('aaaaaaaa-0000-0000-0000-000000000001')),
  true,
  'Bruno is a Good playmate, visible to other members'
);
select is((select count(*)::int from public.playdate_reviews), 0, 'Review comments stay private');

select * from finish();
rollback;
