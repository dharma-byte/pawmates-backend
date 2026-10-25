begin;
create extension if not exists pgtap with schema extensions;
select plan(9);

-- Start from an empty database: dev data from manual testing must not leak into
-- counts. Everything is rolled back at the end, so real local data is untouched.
delete from auth.users;

insert into auth.users (id, email, email_confirmed_at) values
  ('11111111-1111-1111-1111-111111111111', 'alice@test.dev', now()),
  ('22222222-2222-2222-2222-222222222222', 'bob@test.dev',   now());
update public.profiles set verification_status = 'verified', full_name = 'Alice'
  where id = '11111111-1111-1111-1111-111111111111';
update public.profiles set verification_status = 'verified', full_name = 'Bob', username = 'bob'
  where id = '22222222-2222-2222-2222-222222222222';
update public.profiles set location = extensions.st_point(77.6408, 12.9784)::extensions.geography
  where id = '11111111-1111-1111-1111-111111111111';
insert into public.pets (owner_id, name, species) values
  ('11111111-1111-1111-1111-111111111111', 'Bruno', 'dog');
insert into public.connections (requester_id, addressee_id, status) values
  ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', 'accepted');

set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

select is((public.export_my_data() -> 'account' ->> 'email'), 'alice@test.dev', 'Export includes the account email');
select is(jsonb_array_length(public.export_my_data() -> 'pets'), 1, 'Export includes my pets');
select ok((public.export_my_data() -> 'profile' -> 'location' ->> 'lat')::float between 12.97 and 12.99,
  'Export includes my exact location as plain numbers');
select is(jsonb_array_length(public.export_my_data() -> 'connections'), 1, 'Export includes my connections');

insert into public.blocks (blocked_id) values ('22222222-2222-2222-2222-222222222222');
select is((select count(*)::int from public.profiles where id = '22222222-2222-2222-2222-222222222222'), 0,
  'A blocked member is hidden from the blocker');
select is((select username from public.my_blocked_users()), 'bob', 'my_blocked_users() still names them');

select lives_ok($$ select public.delete_my_account() $$, 'A member deletes their own account');

reset role;
select is((select count(*)::int from auth.users where id = '11111111-1111-1111-1111-111111111111'), 0,
  'The auth account is gone');
select is((select count(*)::int from public.pets), 0, 'Their pets are deleted with it');

select * from finish();
rollback;
