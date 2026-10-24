begin;
create extension if not exists pgtap with schema extensions;
select plan(10);

-- Fixtures: alice and bob verified, carol unverified.
insert into auth.users (id, email, email_confirmed_at) values
  ('11111111-1111-1111-1111-111111111111', 'alice@test.dev', now()),
  ('22222222-2222-2222-2222-222222222222', 'bob@test.dev',   now()),
  ('33333333-3333-3333-3333-333333333333', 'carol@test.dev', now());

update public.profiles set verification_status = 'verified'
  where id in ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222');

-- ---------------------------------------------------------------- as alice
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

select lives_ok(
  $$ insert into public.pets (name, species, breed, size, energy, play_style, likes)
       values ('Bruno', 'dog', 'Beagle', 'medium', 'high', 'chaser', '{fetch,water}') $$,
  'Owner adds a pet'
);

select is(
  (select owner_id from public.pets where name = 'Bruno'),
  '11111111-1111-1111-1111-111111111111'::uuid,
  'owner_id is taken from the session'
);

select throws_ok(
  $$ insert into public.pets (name, species, photos)
       values ('Too many', 'cat', '{1,2,3,4,5,6,7}') $$,
  '23514',
  null,
  'A pet can have at most 6 photos'
);

select throws_ok(
  $$ update public.pets set owner_id = '22222222-2222-2222-2222-222222222222'
       where name = 'Bruno' $$,
  '42501',
  null,
  'A pet cannot be moved to another owner'
);

-- ---------------------------------------------------------------- as carol (unverified)
set local request.jwt.claims = '{"sub":"33333333-3333-3333-3333-333333333333"}';

select lives_ok(
  $$ insert into public.pets (name, species) values ('Misty', 'cat') $$,
  'An unverified user can still add pets during onboarding'
);

select is(
  (select array_agg(name)::text from public.pets),
  '{Misty}',
  'An unverified user sees only their own pets'
);

-- ---------------------------------------------------------------- as bob (verified)
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222"}';

select is(
  (select array_agg(name)::text from public.pets),
  '{Bruno}',
  'A verified user sees pets of verified owners, not of unverified carol'
);

update public.pets set name = 'Hacked' where name = 'Bruno';
delete from public.pets where name = 'Bruno';

reset role;
select is(
  (select name from public.pets where owner_id = '11111111-1111-1111-1111-111111111111'),
  'Bruno',
  'Other users cannot edit or delete someone else''s pet'
);

-- ---------------------------------------------------------------- deleting
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
delete from public.pets where name = 'Bruno';

select is(
  (select count(*)::int from public.pets),
  0,
  'Owner deletes their own pet'
);

reset role;
delete from auth.users where id = '33333333-3333-3333-3333-333333333333';
select is(
  (select count(*)::int from public.pets where name = 'Misty'),
  0,
  'Deleting an account deletes its pets'
);

select * from finish();
rollback;
