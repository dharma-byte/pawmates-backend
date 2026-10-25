begin;
create extension if not exists pgtap with schema extensions;
select plan(16);

-- Start from an empty database: dev data from manual testing must not leak into
-- counts. Everything is rolled back at the end, so real local data is untouched.
delete from auth.users;

-- Fixtures: alice (verified), bob (verified), carol (unverified), admin.
insert into auth.users (id, email, email_confirmed_at) values
  ('11111111-1111-1111-1111-111111111111', 'alice@test.dev', now()),
  ('22222222-2222-2222-2222-222222222222', 'bob@test.dev',   now()),
  ('33333333-3333-3333-3333-333333333333', 'carol@test.dev', now()),
  ('44444444-4444-4444-4444-444444444444', 'admin@test.dev', now());

select is(
  (select count(*)::int from public.profiles),
  4,
  'A profile is created for every new auth user'
);

update public.profiles set verification_status = 'verified'
  where id in ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222');
update public.profiles set is_admin = true, verification_status = 'verified'
  where id = '44444444-4444-4444-4444-444444444444';

-- Bengaluru, Indiranagar
update public.profiles
  set location = extensions.st_point(77.6408, 12.9784)::extensions.geography
  where id = '11111111-1111-1111-1111-111111111111';

select ok(
  (select extensions.st_distance(location, public_location) between 499 and 1001
     from public.profiles where id = '11111111-1111-1111-1111-111111111111'),
  'public_location is fuzzed 500 m to 1 km from the exact location'
);

-- ---------------------------------------------------------------- as alice
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

select is(
  (select count(*)::int from public.profiles),
  3,
  'A verified user sees verified profiles only (not unverified carol)'
);

select throws_ok(
  $$ select location from public.profiles $$,
  '42501',
  null,
  'Nobody can select the exact location column'
);

select ok(
  (select lat between 12.97 and 12.99 from public.get_my_location()),
  'Owner reads their own exact location via get_my_location()'
);

select throws_ok(
  $$ update public.profiles set verification_status = 'verified'
       where id = '11111111-1111-1111-1111-111111111111' $$,
  '42501',
  null,
  'Users cannot change their own verification status'
);

select throws_ok(
  $$ update public.profiles set is_admin = true
       where id = '11111111-1111-1111-1111-111111111111' $$,
  '42501',
  null,
  'Users cannot make themselves admin'
);

update public.profiles set bio = 'hacked'
  where id = '22222222-2222-2222-2222-222222222222';
reset role;
select is(
  (select bio from public.profiles where id = '22222222-2222-2222-2222-222222222222'),
  null,
  'Users cannot edit someone else''s profile'
);

-- ---------------------------------------------------------------- as carol (unverified)
set local role authenticated;
set local request.jwt.claims = '{"sub":"33333333-3333-3333-3333-333333333333"}';

select is(
  (select array_agg(id)::text from public.profiles),
  '{33333333-3333-3333-3333-333333333333}',
  'An unverified user sees only their own profile'
);

select lives_ok(
  $$ insert into public.verifications (profile_photo_path, pet_photo_path)
       values ('33333333-3333-3333-3333-333333333333/face.jpg',
               '33333333-3333-3333-3333-333333333333/with-pet.jpg') $$,
  'An unverified user can submit a verification request'
);

select is(
  (select verification_status::text from public.profiles where id = auth.uid()),
  'pending',
  'Submitting moves the profile to pending'
);

select throws_ok(
  $$ insert into public.verifications (profile_photo_path, pet_photo_path)
       values ('33333333-3333-3333-3333-333333333333/face2.jpg',
               '33333333-3333-3333-3333-333333333333/with-pet2.jpg') $$,
  '42501',
  null,
  'A pending user cannot submit a second request'
);

select throws_ok(
  $$ select public.review_verification(
       (select id from public.verifications limit 1), 'approved') $$,
  '42501',
  null,
  'Non-admins cannot review verification requests'
);

-- ---------------------------------------------------------------- as admin
set local request.jwt.claims = '{"sub":"44444444-4444-4444-4444-444444444444"}';

select lives_ok(
  $$ select public.review_verification(
       (select id from public.verifications
          where user_id = '33333333-3333-3333-3333-333333333333'), 'approved') $$,
  'Admin approves the request'
);

reset role;
select is(
  (select verification_status::text from public.profiles
     where id = '33333333-3333-3333-3333-333333333333'),
  'verified',
  'Approval marks the profile verified'
);

-- Changing the profile photo after approval requires re-verification.
set local role authenticated;
set local request.jwt.claims = '{"sub":"33333333-3333-3333-3333-333333333333"}';
update public.profiles set avatar_url = 'carol/new-face.jpg' where id = auth.uid();
reset role;
select is(
  (select verification_status::text from public.profiles
     where id = '33333333-3333-3333-3333-333333333333'),
  'unverified',
  'Changing the profile photo resets verification'
);

select * from finish();
rollback;
