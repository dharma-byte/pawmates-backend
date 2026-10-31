begin;
create extension if not exists pgtap with schema extensions;
select plan(17);

-- Start from an empty database (rolled back at the end).
delete from auth.users;

-- alice loses Bruno; bob lives nearby, erin far away, nora is unverified;
-- carol has blocked alice.
insert into auth.users (id, email, email_confirmed_at) values
  ('11111111-1111-1111-1111-111111111111', 'alice@test.dev', now()),
  ('22222222-2222-2222-2222-222222222222', 'bob@test.dev',   now()),
  ('33333333-3333-3333-3333-333333333333', 'carol@test.dev', now()),
  ('44444444-4444-4444-4444-444444444444', 'erin@test.dev',  now()),
  ('66666666-6666-6666-6666-666666666666', 'nora@test.dev',  now());
update public.profiles set verification_status = 'verified',
  location = extensions.st_point(77.6408, 12.9784)::extensions.geography
  where id <> '66666666-6666-6666-6666-666666666666';
update public.profiles set location = extensions.st_point(72.8777, 19.0760)::extensions.geography  -- Mumbai
  where id = '44444444-4444-4444-4444-444444444444';
update public.profiles set location = extensions.st_point(77.6408, 12.9784)::extensions.geography
  where id = '66666666-6666-6666-6666-666666666666';
update public.profiles set full_name = 'Alice' where id = '11111111-1111-1111-1111-111111111111';
update public.profiles set full_name = 'Bob', message_privacy = 'connections' where id = '22222222-2222-2222-2222-222222222222';
update public.profiles set message_privacy = 'connections' where id = '11111111-1111-1111-1111-111111111111';
insert into public.pets (id, owner_id, name, species, breed) values
  ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Bruno', 'dog', 'Beagle'),
  ('bbbbbbbb-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'Luna', 'dog', null);
insert into public.blocks (blocker_id, blocked_id) values
  ('33333333-3333-3333-3333-333333333333', '11111111-1111-1111-1111-111111111111');

create temporary table ids (name text primary key, id uuid);
grant all on ids to authenticated;

set local role authenticated;

-- --------------------------------------------------------------- reporting
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222"}';
select throws_ok(
  $$ select public.report_lost_pet('aaaaaaaa-0000-0000-0000-000000000001', now(), 12.97, 77.64, 'Park') $$,
  '42501', null,
  'Only the owner can report a pet lost'
);

set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
insert into ids select 'r', public.report_lost_pet(
  'aaaaaaaa-0000-0000-0000-000000000001', now() - interval '1 hour', 12.9790, 77.6410,
  '100 Feet Road', 'Red collar, friendly but shy', 5);
select isnt((select id from ids where name = 'r'), null, 'Alice reports Bruno lost');

select throws_ok(
  $$ select public.report_lost_pet('aaaaaaaa-0000-0000-0000-000000000001', now(), 12.97, 77.64, 'Park') $$,
  'P0001', 'Bruno is already reported lost',
  'One open report per pet'
);

select throws_ok(
  $$ select location from public.lost_sightings $$,
  '42501', null,
  'Raw sighting points are not readable'
);

-- ------------------------------------------------------------------ alerts
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222"}';
select is(
  (select title from public.notifications where type = 'lost_nearby'),
  'Lost dog nearby: Bruno (Beagle)',
  'Members nearby are alerted'
);
select is(
  (select pet_name || ':' || sightings || ':' || mine from public.lost_pets_nearby()),
  'Bruno:0:false',
  'Nearby members see the lost dog'
);
select is(
  (select count(*)::int from public.lost_report_points((select id from ids where name = 'r'))),
  1,
  'The last-seen spot is on the map'
);

set local request.jwt.claims = '{"sub":"44444444-4444-4444-4444-444444444444"}';
select is((select count(*)::int from public.notifications), 0, 'Members far away are not alerted');

set local request.jwt.claims = '{"sub":"33333333-3333-3333-3333-333333333333"}';
select is((select count(*)::int from public.notifications), 0, 'Blocked members are not alerted');
select is((select count(*)::int from public.lost_pets_nearby()), 0, 'Blocked members do not see the report');

set local request.jwt.claims = '{"sub":"66666666-6666-6666-6666-666666666666"}';
select is((select count(*)::int from public.lost_reports), 0, 'Unverified members cannot see reports');

-- --------------------------------------------------------------- sightings
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222"}';
select throws_ok(
  format($$ select public.get_or_create_direct_conversation('%s') $$, '11111111-1111-1111-1111-111111111111'),
  '42501', null,
  'Strangers cannot message before a sighting'
);
select lives_ok(
  format($$ select public.add_lost_sighting('%s', now() - interval '10 minutes', 12.9801, 77.6420, 'Near the bakery', 'Heading towards the park') $$,
         (select id from ids where name = 'r')),
  'Bob reports a sighting'
);
select lives_ok(
  format($$ select public.get_or_create_direct_conversation('%s') $$, '11111111-1111-1111-1111-111111111111'),
  'A sighting lets the finder and the owner message each other'
);

set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
select is(
  (select title from public.notifications where type = 'lost_sighting'),
  'Bob saw Bruno',
  'The owner hears about the sighting'
);

-- ------------------------------------------------------------------- found
select public.close_lost_report((select id from ids where name = 'r'));

set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222"}';
select is(
  (select title from public.notifications where type = 'lost_found'),
  'Good news: Bruno is home!',
  'People who helped hear the good news'
);
select throws_ok(
  format($$ select public.add_lost_sighting('%s', now(), 12.98, 77.64) $$, (select id from ids where name = 'r')),
  'P0001', 'This lost pet report is closed',
  'Closed reports take no more sightings'
);

select * from finish();
rollback;
