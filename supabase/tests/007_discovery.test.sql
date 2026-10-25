begin;
create extension if not exists pgtap with schema extensions;
select plan(14);

-- Start from an empty database: dev data from manual testing must not leak into
-- counts. Everything is rolled back at the end, so real local data is untouched.
delete from auth.users;

-- Fixtures around Indiranagar, Bengaluru (12.9784, 77.6408):
--   alice  home         verified, searcher
--   bob    ~2 km north  verified
--   dave   ~15 km north verified
--   carol  ~1 km north  unverified
--   erin   ~1 km south  verified, has blocked alice
insert into auth.users (id, email, email_confirmed_at) values
  ('11111111-1111-1111-1111-111111111111', 'alice@test.dev', now()),
  ('22222222-2222-2222-2222-222222222222', 'bob@test.dev',   now()),
  ('33333333-3333-3333-3333-333333333333', 'carol@test.dev', now()),
  ('55555555-5555-5555-5555-555555555555', 'dave@test.dev',  now()),
  ('66666666-6666-6666-6666-666666666666', 'erin@test.dev',  now());

update public.profiles set verification_status = 'verified', area_name = 'Indiranagar'
  where id <> '33333333-3333-3333-3333-333333333333';

update public.profiles p set location = extensions.st_point(77.6408, v.lat)::extensions.geography
from (values
  ('11111111-1111-1111-1111-111111111111'::uuid, 12.9784),
  ('22222222-2222-2222-2222-222222222222'::uuid, 12.9964),
  ('33333333-3333-3333-3333-333333333333'::uuid, 12.9874),
  ('55555555-5555-5555-5555-555555555555'::uuid, 13.1134),
  ('66666666-6666-6666-6666-666666666666'::uuid, 12.9694)
) v(id, lat)
where p.id = v.id;

update public.profiles set show_area = false where id = '55555555-5555-5555-5555-555555555555';

insert into public.pets (id, owner_id, name, species, size, energy, play_style, temperament,
                         good_with_cats, good_with_small_dogs, vaccinated, birth_date) values
  ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   'Bruno', 'dog', 'medium', 'high', 'chaser', 'friendly', false, true, true, '2023-01-01'),
  ('bbbbbbbb-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222',
   'Luna', 'dog', 'medium', 'high', 'chaser', 'friendly', true, true, true, '2022-06-01'),
  ('bbbbbbbb-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222',
   'Whiskers', 'cat', 'small', 'low', 'gentle', 'shy', null, null, false, '2020-01-01'),
  ('cccccccc-0000-0000-0000-000000000001', '33333333-3333-3333-3333-333333333333',
   'Ghost', 'dog', 'medium', 'high', 'chaser', 'friendly', null, null, true, null),
  ('dddddddd-0000-0000-0000-000000000001', '55555555-5555-5555-5555-555555555555',
   'Rex', 'dog', 'giant', 'low', 'wrestler', 'reactive', null, null, true, '2019-01-01'),
  ('eeeeeeee-0000-0000-0000-000000000001', '66666666-6666-6666-6666-666666666666',
   'Hidden', 'dog', 'medium', 'high', 'chaser', 'friendly', null, null, true, null);

insert into public.blocks (blocker_id, blocked_id) values
  ('66666666-6666-6666-6666-666666666666', '11111111-1111-1111-1111-111111111111');

-- ---------------------------------------------------------------- as alice
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

select is(
  (select array_agg(name order by name)::text from public.nearby_pets(radius_km => 5)),
  '{Luna,Whiskers}',
  'Within 5 km: Bob''s pets only (not own, unverified, blocked or far away)'
);

select is(
  (select array_agg(name order by name)::text from public.nearby_pets(radius_km => 25)),
  '{Luna,Rex,Whiskers}',
  'Within 25 km also includes Dave''s pet'
);

select is(
  (select array_agg(name)::text from public.nearby_pets(radius_km => 25)),
  '{Luna,Whiskers,Rex}',
  'Results are sorted nearest first'
);

select ok(
  (select approx_distance_km between 1 and 3.5
     from public.nearby_pets(radius_km => 5) where name = 'Luna'),
  'Distance is approximate (about 2 km)'
);

select ok(
  (select approx_distance_km * 2 = round(approx_distance_km * 2)
     from public.nearby_pets(radius_km => 5) where name = 'Luna'),
  'Distances under 10 km are rounded to 0.5 km'
);

select is(
  (select array_agg(name)::text
     from public.nearby_pets(radius_km => 25, species_filter => '{cat}')),
  '{Whiskers}',
  'Species filter'
);

select is(
  (select array_agg(name order by name)::text
     from public.nearby_pets(radius_km => 25, vaccinated_only => true)),
  '{Luna,Rex}',
  'Vaccinated-only filter'
);

select is(
  (select array_agg(name)::text
     from public.nearby_pets(radius_km => 25, min_age_months => 60)),
  '{Whiskers,Rex}',
  'Minimum age filter'
);

select is(
  (select area_name from public.nearby_pets(radius_km => 25) where name = 'Rex'),
  null,
  'Area name is hidden when the owner turns show_area off'
);

select is(
  (select compatibility from public.nearby_pets(
     radius_km => 5, my_pet_id => 'aaaaaaaa-0000-0000-0000-000000000001') where name = 'Luna'),
  100,
  'Identical size, energy, play style and temperament score 100'
);

select ok(
  (select compatibility < 20 from public.nearby_pets(
     radius_km => 5, my_pet_id => 'aaaaaaaa-0000-0000-0000-000000000001') where name = 'Whiskers'),
  'A dog that is not good with cats scores low with a cat'
);

select is(
  public.compatibility_score('aaaaaaaa-0000-0000-0000-000000000001', 'cccccccc-0000-0000-0000-000000000001'),
  null,
  'compatibility_score returns nothing for pets the caller cannot see'
);

select throws_ok(
  $$ select * from public.nearby_pets(my_pet_id => 'bbbbbbbb-0000-0000-0000-000000000001') $$,
  'P0001',
  'my_pet_id must be one of your pets',
  'my_pet_id must belong to the caller'
);

-- ---------------------------------------------------------------- as carol (unverified)
set local request.jwt.claims = '{"sub":"33333333-3333-3333-3333-333333333333"}';

select throws_ok(
  $$ select * from public.nearby_pets() $$,
  '42501',
  null,
  'Unverified users cannot discover pets'
);

select * from finish();
rollback;
