begin;
create extension if not exists pgtap with schema extensions;
select plan(11);

-- Start from an empty database: dev data from manual testing must not leak into
-- counts. Everything is rolled back at the end, so real local data is untouched.
delete from auth.users;

-- Fixtures: alice + bob are Pawmates with a chat; dave outsider; admin.
insert into auth.users (id, email, email_confirmed_at) values
  ('11111111-1111-1111-1111-111111111111', 'alice@test.dev', now()),
  ('22222222-2222-2222-2222-222222222222', 'bob@test.dev',   now()),
  ('44444444-4444-4444-4444-444444444444', 'admin@test.dev', now()),
  ('55555555-5555-5555-5555-555555555555', 'dave@test.dev',  now());

update public.profiles set verification_status = 'verified';
update public.profiles set is_admin = true where id = '44444444-4444-4444-4444-444444444444';
insert into public.connections (requester_id, addressee_id, status) values
  ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', 'accepted');

create temporary table ids (name text primary key, id uuid);
grant all on ids to authenticated;

select is(
  (select count(*)::int from storage.buckets
     where id in ('avatars', 'pet-photos', 'verification-photos', 'chat-images')),
  4,
  'All four buckets exist'
);

select is(
  (select array_agg(id order by id)::text from storage.buckets where public),
  '{avatars,pet-photos}',
  'Only avatars and pet photos are public'
);

-- ---------------------------------------------------------------- as alice
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
insert into ids values ('ab', public.get_or_create_direct_conversation('22222222-2222-2222-2222-222222222222'));

select lives_ok(
  $$ insert into storage.objects (bucket_id, name)
       values ('avatars', '11111111-1111-1111-1111-111111111111/me.webp') $$,
  'Users upload an avatar to their own folder'
);

select throws_ok(
  $$ insert into storage.objects (bucket_id, name)
       values ('pet-photos', '22222222-2222-2222-2222-222222222222/fake.webp') $$,
  '42501',
  null,
  'Users cannot upload into someone else''s folder'
);

select lives_ok(
  $$ insert into storage.objects (bucket_id, name)
       values ('verification-photos', '11111111-1111-1111-1111-111111111111/with-pet.webp') $$,
  'Users upload their own verification photo'
);

select lives_ok(
  format(
    $$ insert into storage.objects (bucket_id, name) values ('chat-images', '%s/park.webp') $$,
    (select id from ids where name = 'ab')
  ),
  'Members upload images into their chat'
);

-- ---------------------------------------------------------------- as dave (outsider)
set local request.jwt.claims = '{"sub":"55555555-5555-5555-5555-555555555555"}';

select is(
  (select count(*)::int from storage.objects where bucket_id = 'verification-photos'),
  0,
  'Other users cannot see verification photos'
);

select is(
  (select count(*)::int from storage.objects where bucket_id = 'chat-images'),
  0,
  'Outsiders cannot see chat images'
);

select throws_ok(
  format(
    $$ insert into storage.objects (bucket_id, name) values ('chat-images', '%s/spam.webp') $$,
    (select id from ids where name = 'ab')
  ),
  '42501',
  null,
  'Outsiders cannot upload into a chat'
);

-- ---------------------------------------------------------------- as bob
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222"}';

select is(
  (select count(*)::int from storage.objects where bucket_id = 'chat-images'),
  1,
  'Chat members can see chat images'
);

-- ---------------------------------------------------------------- as admin
set local request.jwt.claims = '{"sub":"44444444-4444-4444-4444-444444444444"}';

select is(
  (select count(*)::int from storage.objects
     where bucket_id = 'verification-photos' and name like '11111111-%'),
  1,
  'Admins can see verification photos for review'
);

select * from finish();
rollback;
