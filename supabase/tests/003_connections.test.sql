begin;
create extension if not exists pgtap with schema extensions;
select plan(12);

-- Start from an empty database: dev data from manual testing must not leak into
-- counts. Everything is rolled back at the end, so real local data is untouched.
delete from auth.users;

-- Fixtures: alice, bob, dave verified; carol unverified.
insert into auth.users (id, email, email_confirmed_at) values
  ('11111111-1111-1111-1111-111111111111', 'alice@test.dev', now()),
  ('22222222-2222-2222-2222-222222222222', 'bob@test.dev',   now()),
  ('33333333-3333-3333-3333-333333333333', 'carol@test.dev', now()),
  ('55555555-5555-5555-5555-555555555555', 'dave@test.dev',  now());

update public.profiles set verification_status = 'verified'
  where id <> '33333333-3333-3333-3333-333333333333';

insert into public.pets (id, owner_id, name, species) values
  ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Bruno', 'dog'),
  ('bbbbbbbb-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'Luna',  'dog');

-- ---------------------------------------------------------------- as alice
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

select lives_ok(
  $$ insert into public.connections (addressee_id, pet_id, target_pet_id, message)
       values ('22222222-2222-2222-2222-222222222222',
               'aaaaaaaa-0000-0000-0000-000000000001',
               'bbbbbbbb-0000-0000-0000-000000000001',
               'Bruno would love a playdate!') $$,
  'Alice sends Bob a Sniff request from Bruno to Luna'
);

select throws_ok(
  $$ insert into public.connections (addressee_id, pet_id)
       values ('55555555-5555-5555-5555-555555555555',
               'bbbbbbbb-0000-0000-0000-000000000001') $$,
  '42501',
  null,
  'Cannot send a Sniff request from someone else''s pet'
);

select throws_ok(
  $$ insert into public.connections (addressee_id)
       values ('33333333-3333-3333-3333-333333333333') $$,
  '42501',
  null,
  'Cannot send a Sniff request to an unverified user'
);

select throws_ok(
  $$ insert into public.connections (addressee_id)
       values ('11111111-1111-1111-1111-111111111111') $$,
  '23514',
  null,
  'Cannot send a Sniff request to yourself'
);

select throws_ok(
  $$ select public.respond_to_sniff(
       (select id from public.connections limit 1), true) $$,
  'P0001',
  null,
  'The requester cannot accept their own request'
);

-- ---------------------------------------------------------------- as bob
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222"}';

select throws_ok(
  $$ insert into public.connections (addressee_id)
       values ('11111111-1111-1111-1111-111111111111') $$,
  '23505',
  null,
  'Only one connection per pair, in either direction'
);

select is(
  (select (public.respond_to_sniff(
     (select id from public.connections limit 1), true)).status::text),
  'accepted',
  'Bob accepts the Sniff request'
);

select ok(
  private.are_pawmates('11111111-1111-1111-1111-111111111111',
                       '22222222-2222-2222-2222-222222222222'),
  'Alice and Bob are now Pawmates'
);

-- ---------------------------------------------------------------- as dave
set local request.jwt.claims = '{"sub":"55555555-5555-5555-5555-555555555555"}';

select is(
  (select count(*)::int from public.connections),
  0,
  'Users cannot see connections they are not part of'
);

-- ---------------------------------------------------------------- as carol (unverified)
set local request.jwt.claims = '{"sub":"33333333-3333-3333-3333-333333333333"}';

select throws_ok(
  $$ insert into public.connections (addressee_id)
       values ('55555555-5555-5555-5555-555555555555') $$,
  '42501',
  null,
  'Unverified users cannot send Sniff requests'
);

-- ---------------------------------------------------------------- rate limit
reset role;
insert into auth.users (id, email, email_confirmed_at)
  select ('99999999-0000-0000-0000-0000000000' || lpad(g::text, 2, '0'))::uuid,
         'bulk' || g || '@test.dev', now()
  from generate_series(1, 20) g;
update public.profiles set verification_status = 'verified';

set local role authenticated;
set local request.jwt.claims = '{"sub":"55555555-5555-5555-5555-555555555555"}';

select lives_ok(
  $$ insert into public.connections (addressee_id)
       select id from public.profiles where id::text like '99999999-%' $$,
  'Up to 20 Sniff requests per day are allowed'
);

select throws_ok(
  $$ insert into public.connections (addressee_id)
       values ('11111111-1111-1111-1111-111111111111') $$,
  'P0001',
  'Sniff request limit reached, try again tomorrow',
  'The 21st Sniff request in 24 hours is blocked'
);

select * from finish();
rollback;
