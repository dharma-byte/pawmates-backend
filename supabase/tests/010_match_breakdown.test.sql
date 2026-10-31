begin;
create extension if not exists pgtap with schema extensions;
select plan(7);

-- Start from an empty database: dev data from manual testing must not leak into
-- counts. Everything is rolled back at the end, so real local data is untouched.
delete from auth.users;

insert into auth.users (id, email, email_confirmed_at) values
  ('11111111-1111-1111-1111-111111111111', 'alice@test.dev', now()),
  ('22222222-2222-2222-2222-222222222222', 'bob@test.dev',   now());
update public.profiles set verification_status = 'verified';
update public.profiles set location = extensions.st_point(77.6408, 12.9784)::extensions.geography
  where id = '11111111-1111-1111-1111-111111111111';
update public.profiles set location = extensions.st_point(77.6408, 12.9964)::extensions.geography
  where id = '22222222-2222-2222-2222-222222222222';

insert into public.pets (id, owner_id, name, species, size, energy, play_style, temperament, good_with_cats) values
  ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Bruno', 'dog', 'medium', 'high', 'chaser', 'friendly', false),
  ('bbbbbbbb-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'Luna', 'dog', 'medium', 'high', 'chaser', 'friendly', null),
  ('bbbbbbbb-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222', 'Whiskers', 'cat', 'small', 'low', 'gentle', 'shy', null);

set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

select is(
  (public.compatibility_breakdown('aaaaaaaa-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000001') ->> 'total')::int,
  100,
  'Identical play profiles total 100'
);

select is(
  public.compatibility_breakdown('aaaaaaaa-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000001') -> 'size',
  '{"max": 30, "points": 30}'::jsonb,
  'Breakdown shows size points out of 30'
);

select is(
  (public.compatibility_breakdown('aaaaaaaa-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000002') ->> 'total')::int,
  public.compatibility_score('aaaaaaaa-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000002'),
  'The breakdown total always equals the score'
);

select ok(
  (public.compatibility_breakdown('aaaaaaaa-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000002') -> 'notes')
    ? 'The dog is not good with cats',
  'Explains the dog-cat penalty'
);

select ok(
  (select compatibility < 20 from public.nearby_pets(radius_km => 5, my_pet_id => 'aaaaaaaa-0000-0000-0000-000000000001')
     where name = 'Whiskers'),
  'Scores in nearby_pets are unchanged by the refactor'
);

select ok(
  (select approx_lat is not null and approx_lng is not null
     from public.nearby_pets(radius_km => 5) where name = 'Luna'),
  'nearby_pets returns map coordinates'
);

-- Map points are the fuzzed public point, never the exact home.
reset role;
create temporary table pin (approx_lat double precision, approx_lng double precision);
grant all on pin to authenticated;
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
insert into pin
  select approx_lat, approx_lng from public.nearby_pets(radius_km => 5) where name = 'Luna';
reset role;
select ok(
  (select extensions.st_distance(
            extensions.st_point(pin.approx_lng, pin.approx_lat)::extensions.geography,
            (select location from public.profiles where id = '22222222-2222-2222-2222-222222222222'))
     between 499 and 1001
   from pin),
  'Map pins sit 500 m to 1 km from the real home'
);

select * from finish();
rollback;
