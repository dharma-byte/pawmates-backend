begin;
create extension if not exists pgtap with schema extensions;
select plan(5);

-- Start from an empty database: dev data from manual testing must not leak into
-- counts. Everything is rolled back at the end, so real local data is untouched.
delete from auth.users;

insert into auth.users (id, email, email_confirmed_at) values
  ('11111111-1111-1111-1111-111111111111', 'alice@test.dev', now()),
  ('44444444-4444-4444-4444-444444444444', 'admin@test.dev', now());
update public.profiles set verification_status = 'verified';
update public.profiles set is_admin = true where id = '44444444-4444-4444-4444-444444444444';

set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

select is(public.am_i_admin(), false, 'A regular user is not an admin');
select throws_ok($$ select is_admin from public.profiles $$, '42501', null, 'is_admin stays unreadable');
select throws_ok($$ select * from public.admin_stats() $$, '42501', null, 'Regular users cannot view stats');

set local request.jwt.claims = '{"sub":"44444444-4444-4444-4444-444444444444"}';

select is(public.am_i_admin(), true, 'An admin is recognised');
select is((select verified_users from public.admin_stats()), 2, 'Admins see dashboard numbers');

select * from finish();
rollback;
