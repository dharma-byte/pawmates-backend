begin;
create extension if not exists pgtap with schema extensions;
select plan(2);

-- Start from an empty database: dev data from manual testing must not leak into
-- counts. Everything is rolled back at the end, so real local data is untouched.
delete from auth.users;

-- An admin searching near an unverified (pending) member.
insert into auth.users (id, email, email_confirmed_at) values
  ('44444444-4444-4444-4444-444444444444', 'admin@test.dev', now()),
  ('33333333-3333-3333-3333-333333333333', 'carol@test.dev', now());
update public.profiles set verification_status = 'verified', is_admin = true
  where id = '44444444-4444-4444-4444-444444444444';
update public.profiles set verification_status = 'pending'
  where id = '33333333-3333-3333-3333-333333333333';
update public.profiles set location = extensions.st_point(77.6408, 12.9784)::extensions.geography;
insert into public.pets (owner_id, name, species) values
  ('33333333-3333-3333-3333-333333333333', 'Rocky', 'dog');

set local role authenticated;
set local request.jwt.claims = '{"sub":"44444444-4444-4444-4444-444444444444"}';

select is((select count(*)::int from public.pets where name = 'Rocky'), 1,
  'Admins can still read the pending member''s pet for moderation');
select is((select count(*)::int from public.nearby_pets(radius_km => 5)), 0,
  'But Discover never lists unverified members, even for admins');

select * from finish();
rollback;
