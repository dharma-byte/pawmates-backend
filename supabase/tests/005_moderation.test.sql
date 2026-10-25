begin;
create extension if not exists pgtap with schema extensions;
select plan(15);

-- Start from an empty database: dev data from manual testing must not leak into
-- counts. Everything is rolled back at the end, so real local data is untouched.
delete from auth.users;

-- Fixtures: alice + bob are Pawmates with a chat; admin; all verified.
insert into auth.users (id, email, email_confirmed_at) values
  ('11111111-1111-1111-1111-111111111111', 'alice@test.dev', now()),
  ('22222222-2222-2222-2222-222222222222', 'bob@test.dev',   now()),
  ('44444444-4444-4444-4444-444444444444', 'admin@test.dev', now());

update public.profiles set verification_status = 'verified';
update public.profiles set is_admin = true where id = '44444444-4444-4444-4444-444444444444';

insert into public.pets (owner_id, name, species) values
  ('22222222-2222-2222-2222-222222222222', 'Luna', 'dog');
insert into public.connections (requester_id, addressee_id, status) values
  ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', 'accepted');

create temporary table ids (name text primary key, id uuid);
grant all on ids to authenticated;

set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
insert into ids values ('ab', public.get_or_create_direct_conversation('22222222-2222-2222-2222-222222222222'));

-- ---------------------------------------------------------------- bob blocks alice
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222"}';

insert into public.messages (conversation_id, body)
  values ((select id from ids where name = 'ab'), 'You are a terrible person');
insert into ids select 'msg', id from public.messages limit 1;

select lives_ok(
  $$ insert into public.blocks (blocked_id) values ('11111111-1111-1111-1111-111111111111') $$,
  'Bob blocks Alice'
);

reset role;
select is(
  (select count(*)::int from public.connections),
  0,
  'Blocking removes the Pawmate connection'
);

set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

select is((select count(*)::int from public.blocks), 0, 'Alice cannot see that Bob blocked her');

select is(
  (select count(*)::int from public.profiles where id = '22222222-2222-2222-2222-222222222222'),
  0,
  'Alice can no longer see Bob''s profile'
);

select is((select count(*)::int from public.pets), 0, 'Alice can no longer see Bob''s pets');

select throws_ok(
  $$ insert into public.connections (addressee_id)
       values ('22222222-2222-2222-2222-222222222222') $$,
  '42501',
  null,
  'Alice cannot send Bob a Sniff request'
);

select throws_ok(
  $$ insert into public.messages (conversation_id, body)
       values ((select id from ids where name = 'ab'), 'why?') $$,
  '42501',
  null,
  'Alice cannot message Bob'
);

-- ---------------------------------------------------------------- alice reports bob's message
select lives_ok(
  $$ insert into public.reports (target_type, target_id, reason, details)
       values ('message', (select id from ids where name = 'msg'), 'harassment', 'Insulting me') $$,
  'Alice reports a message'
);

select throws_ok(
  $$ insert into public.reports (target_type, target_id, reason)
       values ('message', (select id from ids where name = 'msg'), 'harassment') $$,
  '23505',
  null,
  'The same user cannot file a duplicate open report'
);

select throws_ok(
  $$ select public.ban_user('22222222-2222-2222-2222-222222222222', 'test') $$,
  '42501',
  null,
  'Non-admins cannot ban users'
);

-- ---------------------------------------------------------------- admin
set local request.jwt.claims = '{"sub":"44444444-4444-4444-4444-444444444444"}';

select is(
  (select count(*)::int from public.reports where status = 'open'),
  1,
  'Admin sees the report queue'
);

select is(
  (select body from public.messages where id = (select id from ids where name = 'msg')),
  'You are a terrible person',
  'Admin can read the reported message'
);

select lives_ok(
  $$ select public.ban_user('22222222-2222-2222-2222-222222222222', 'Harassment') $$,
  'Admin bans Bob'
);

select lives_ok(
  $$ select public.resolve_report((select id from public.reports limit 1), 'resolved', 'User banned') $$,
  'Admin resolves the report'
);

-- ---------------------------------------------------------------- banned bob
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222"}';

select throws_ok(
  $$ insert into public.verifications (profile_photo_path, pet_photo_path)
       values ('22222222-2222-2222-2222-222222222222/a.jpg',
               '22222222-2222-2222-2222-222222222222/b.jpg') $$,
  '42501',
  null,
  'A banned user cannot apply for verification again'
);

select * from finish();
rollback;
