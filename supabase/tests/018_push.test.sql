begin;
create extension if not exists pgtap with schema extensions;
select plan(10);

-- Start from an empty database (rolled back at the end).
delete from auth.users;
delete from vault.secrets where name in ('push_endpoint_url', 'push_webhook_secret');

insert into auth.users (id, email, email_confirmed_at) values
  ('11111111-1111-1111-1111-111111111111', 'alice@test.dev', now()),
  ('22222222-2222-2222-2222-222222222222', 'bob@test.dev',   now());
update public.profiles set verification_status = 'verified';

create temporary table queued (n bigint);
grant all on queued to authenticated;
insert into queued select count(*) from net.http_request_queue;

-- ------------------------------------------------------------------ devices
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
select lives_ok(
  $$ select public.save_push_subscription('https://push.example.com/abc', 'p256-key', 'auth-key', 'Test browser') $$,
  'Alice turns on notifications on a device'
);
select is((select count(*)::int from public.push_subscriptions), 1, 'Alice sees her device');
select throws_ok($$ select p256dh from public.push_subscriptions $$, '42501', null, 'Device keys are not readable');

set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222"}';
select is((select count(*)::int from public.push_subscriptions), 0, 'Bob cannot see Alice''s devices');

-- -------------------------------------------------- not configured: no push
reset role;
select private.notify('11111111-1111-1111-1111-111111111111', 'event_reminder', 'Walk soon', 'Bring water', '/home');
select is(
  (select count(*) from net.http_request_queue) - (select n from queued),
  0::bigint,
  'Without the Vault secrets nothing is sent'
);

-- ------------------------------------------------------- configured: queued
select vault.create_secret('http://example.invalid/api/push', 'push_endpoint_url');
select vault.create_secret('test-secret', 'push_webhook_secret');
select private.notify('11111111-1111-1111-1111-111111111111', 'event_reminder', 'Walk now', 'See you there', '/home');
select is(
  (select count(*) from net.http_request_queue) - (select n from queued),
  1::bigint,
  'A notification for a member with a device queues one push request'
);
select private.notify('22222222-2222-2222-2222-222222222222', 'event_reminder', 'Walk now', null, '/home');
select is(
  (select count(*) from net.http_request_queue) - (select n from queued),
  1::bigint,
  'Members without devices get no push request'
);

-- ------------------------------------------------------------------ cleanup
set local role anon;
select throws_ok(
  $$ select public.remove_push_subscriptions('wrong', array['https://push.example.com/abc']) $$,
  '42501', null,
  'Removing expired devices needs the shared secret'
);
select is(
  public.remove_push_subscriptions('test-secret', array['https://push.example.com/abc']),
  1,
  'The website removes a device the push service reported gone'
);

-- ------------------------------------------------- switching account moves it
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
select public.save_push_subscription('https://push.example.com/shared', 'k', 'a');
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222"}';
select public.save_push_subscription('https://push.example.com/shared', 'k', 'a');
select is((select count(*)::int from public.push_subscriptions), 1, 'A device signed in as Bob now belongs to Bob');

select * from finish();
rollback;
