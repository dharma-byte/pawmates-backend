begin;
create extension if not exists pgtap with schema extensions;
select plan(20);

-- Start from an empty database (rolled back at the end).
delete from auth.users;

-- alice, bob, carol are verified and live close together; erin is far away;
-- nora is not verified yet.
insert into auth.users (id, email, email_confirmed_at) values
  ('11111111-1111-1111-1111-111111111111', 'alice@test.dev', now()),
  ('22222222-2222-2222-2222-222222222222', 'bob@test.dev',   now()),
  ('33333333-3333-3333-3333-333333333333', 'carol@test.dev', now()),
  ('44444444-4444-4444-4444-444444444444', 'erin@test.dev',  now()),
  ('66666666-6666-6666-6666-666666666666', 'nora@test.dev',  now());
update public.profiles set verification_status = 'verified', area_name = 'Indiranagar'
  where id <> '66666666-6666-6666-6666-666666666666';
update public.profiles set location = extensions.st_point(77.6408, 12.9784)::extensions.geography
  where id <> '44444444-4444-4444-4444-444444444444';
update public.profiles set location = extensions.st_point(72.8777, 19.0760)::extensions.geography  -- Mumbai
  where id = '44444444-4444-4444-4444-444444444444';

create temporary table ids (name text primary key, id uuid);
grant all on ids to authenticated;

-- ------------------------------------------------------------ alice starts one
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

select throws_ok(
  $$ select public.create_group('Indie Beagles', 'breed') $$,
  '23514', null,
  'A breed club needs a breed'
);

insert into ids select 'g', public.create_group('Indiranagar Beagles', 'breed', 'Weekend sniffs', 'dog', 'Beagle');

select is(
  (select role from public.group_members where group_id = (select id from ids where name = 'g')),
  'owner',
  'The creator owns the group'
);

select is(
  (select area_name || ':' || member_count from public.groups where id = (select id from ids where name = 'g')),
  'Indiranagar:1',
  'The group takes the creator''s area and counts one member'
);

insert into ids select 'chat', id from public.conversations where group_id = (select id from ids where name = 'g');
select ok(
  exists (select 1 from public.conversation_members
          where conversation_id = (select id from ids where name = 'chat')
            and user_id = '11111111-1111-1111-1111-111111111111'),
  'The owner is in the group chat'
);

select throws_ok(
  $$ select public.create_group('indiranagar beagles ', 'interest') $$,
  '23505', null,
  'Group names are unique, ignoring case and spaces'
);

select throws_ok(
  $$ select location from public.groups $$,
  '42501', null,
  'The raw group point is not readable'
);

-- --------------------------------------------------------------- bob joins
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222"}';

select is(
  (select count(*)::int from public.find_groups('beagle')),
  1,
  'Nearby members find the group by breed'
);

select is(
  public.join_group((select id from ids where name = 'g')),
  (select id from ids where name = 'chat'),
  'Joining returns the group chat'
);

select is(
  (select count(*)::int from public.conversation_members where conversation_id = (select id from ids where name = 'chat')),
  2,
  'Joining adds bob to the chat'
);

select lives_ok(
  format($$ insert into public.messages (conversation_id, body) values ('%s', 'Hi beagle folks!') $$,
         (select id from ids where name = 'chat')),
  'Members post in the group chat'
);

select throws_ok(
  format($$ select public.remove_group_member('%s', '11111111-1111-1111-1111-111111111111') $$,
         (select id from ids where name = 'g')),
  '42501', null,
  'Plain members cannot remove others'
);

-- -------------------------------------------------- outsiders and far away
set local request.jwt.claims = '{"sub":"44444444-4444-4444-4444-444444444444"}';
select is((select count(*)::int from public.find_groups()), 0, 'Groups far away are not suggested');
select is(
  (select count(*)::int from public.messages where conversation_id = (select id from ids where name = 'chat')),
  0,
  'Non-members cannot read the group chat'
);

set local request.jwt.claims = '{"sub":"66666666-6666-6666-6666-666666666666"}';
select throws_ok(
  format($$ select public.join_group('%s') $$, (select id from ids where name = 'g')),
  '42501', null,
  'Unverified members cannot join'
);
select is((select count(*)::int from public.groups), 0, 'Unverified members cannot see groups');

-- ------------------------------------------------------ admins and leaving
set local request.jwt.claims = '{"sub":"33333333-3333-3333-3333-333333333333"}';
select public.join_group((select id from ids where name = 'g'));

set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
select public.set_group_admin((select id from ids where name = 'g'), '33333333-3333-3333-3333-333333333333', true);
select public.leave_group((select id from ids where name = 'g'));

set local request.jwt.claims = '{"sub":"33333333-3333-3333-3333-333333333333"}';
select is(
  (select role from public.group_members
   where group_id = (select id from ids where name = 'g') and user_id = '33333333-3333-3333-3333-333333333333'),
  'owner',
  'When the owner leaves, the admin takes over'
);
select is(
  (select member_count from public.groups where id = (select id from ids where name = 'g')),
  2,
  'The member count follows leaves'
);
select lives_ok(
  format($$ select public.remove_group_member('%s', '22222222-2222-2222-2222-222222222222') $$,
         (select id from ids where name = 'g')),
  'The new owner removes a member'
);
select is(
  (select count(*)::int from public.conversation_members where conversation_id = (select id from ids where name = 'chat')),
  1,
  'Removed members leave the chat too'
);

select public.leave_group((select id from ids where name = 'g'));
reset role;
select is((select count(*)::int from public.groups), 0, 'An empty group is deleted');

select * from finish();
rollback;
