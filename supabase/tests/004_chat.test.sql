begin;
create extension if not exists pgtap with schema extensions;
select plan(18);

-- Start from an empty database: dev data from manual testing must not leak into
-- counts. Everything is rolled back at the end, so real local data is untouched.
delete from auth.users;

-- Fixtures: alice + bob are Pawmates; dave is verified but not connected;
-- erin is verified and accepts messages from everyone.
insert into auth.users (id, email, email_confirmed_at) values
  ('11111111-1111-1111-1111-111111111111', 'alice@test.dev', now()),
  ('22222222-2222-2222-2222-222222222222', 'bob@test.dev',   now()),
  ('55555555-5555-5555-5555-555555555555', 'dave@test.dev',  now()),
  ('66666666-6666-6666-6666-666666666666', 'erin@test.dev',  now());

update public.profiles set verification_status = 'verified', message_privacy = 'connections';
update public.profiles set message_privacy = 'everyone'
  where id = '66666666-6666-6666-6666-666666666666';

insert into public.connections (requester_id, addressee_id, status) values
  ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', 'accepted');

create temporary table ids (name text primary key, id uuid);
grant all on ids to authenticated;

-- ---------------------------------------------------------------- as alice
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

insert into ids values ('ab', public.get_or_create_direct_conversation('22222222-2222-2222-2222-222222222222'));

select isnt((select id from ids where name = 'ab'), null, 'Pawmates can open a direct chat');

select is(
  public.get_or_create_direct_conversation('22222222-2222-2222-2222-222222222222'),
  (select id from ids where name = 'ab'),
  'Opening the same chat again returns the existing conversation'
);

select throws_ok(
  $$ select public.get_or_create_direct_conversation('55555555-5555-5555-5555-555555555555') $$,
  '42501',
  null,
  'Cannot open a chat with a non-Pawmate who only accepts connections'
);

select lives_ok(
  $$ select public.get_or_create_direct_conversation('66666666-6666-6666-6666-666666666666') $$,
  'Can open a chat with someone who accepts messages from everyone'
);

select lives_ok(
  $$ insert into public.messages (conversation_id, body)
       values ((select id from ids where name = 'ab'), 'Hi Bob! Park on Saturday?') $$,
  'A member sends a text message'
);

select throws_ok(
  $$ insert into public.messages (conversation_id, body)
       values ((select id from ids where name = 'ab'), '   ') $$,
  '23514',
  null,
  'Empty text messages are rejected'
);

select lives_ok(
  $$ insert into public.messages (conversation_id, type, body, location)
       values ((select id from ids where name = 'ab'), 'location', 'Meet here',
               extensions.st_point(77.6408, 12.9784)::extensions.geography) $$,
  'A member shares a meeting-point location pin'
);

-- ---------------------------------------------------------------- as bob
-- now() is fixed inside a test transaction, so backdate Bob's last read.
reset role;
update public.conversation_members set last_read_at = now() - interval '1 minute'
  where user_id = '22222222-2222-2222-2222-222222222222';
set local role authenticated;
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222"}';

select is(
  (select unread_count from public.get_my_conversations()
     where conversation_id = (select id from ids where name = 'ab')),
  2,
  'Bob has 2 unread messages'
);

select public.mark_conversation_read((select id from ids where name = 'ab'));

select is(
  (select unread_count from public.get_my_conversations()
     where conversation_id = (select id from ids where name = 'ab')),
  0,
  'Marking the conversation read clears the unread count'
);

update public.messages set body = 'edited by bob' where sender_id <> auth.uid();
select is(
  (select count(*)::int from public.messages where body = 'edited by bob'),
  0,
  'Users cannot edit other people''s messages'
);

-- ---------------------------------------------------------------- as dave (outsider)
set local request.jwt.claims = '{"sub":"55555555-5555-5555-5555-555555555555"}';

select is((select count(*)::int from public.messages), 0, 'Outsiders cannot read messages');
select is((select count(*)::int from public.conversations), 0, 'Outsiders cannot see conversations');

select throws_ok(
  $$ insert into public.messages (conversation_id, body)
       values ((select id from ids where name = 'ab'), 'let me in') $$,
  '42501',
  null,
  'Outsiders cannot post into a conversation'
);

select ok(
  not private.can_use_chat_topic('chat:' || (select id from ids where name = 'ab')),
  'Outsiders cannot join the typing/presence channel'
);

-- ---------------------------------------------------------------- edits and deletes as alice
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

select ok(
  private.can_use_chat_topic('chat:' || (select id from ids where name = 'ab')),
  'Members can join the typing/presence channel'
);

update public.messages set body = 'Hi Bob! Park on Sunday?' where type = 'text';
select isnt(
  (select edited_at from public.messages where type = 'text'),
  null,
  'Editing a message stamps edited_at'
);

update public.messages set deleted_at = now() where type = 'location';
select is(
  (select location from public.messages where type = 'location'),
  null,
  'Deleting a message clears its content'
);

-- Unfriending stops new direct messages in an existing chat.
reset role;
delete from public.connections;
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

select throws_ok(
  $$ insert into public.messages (conversation_id, body)
       values ((select id from ids where name = 'ab'), 'still there?') $$,
  '42501',
  null,
  'After removing a Pawmate, direct messages are blocked'
);

select * from finish();
rollback;
