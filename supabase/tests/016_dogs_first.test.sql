begin;
create extension if not exists pgtap with schema extensions;
select plan(3);

delete from auth.users;
insert into auth.users (id, email, email_confirmed_at) values
  ('11111111-1111-1111-1111-111111111111', 'alice@test.dev', now());

set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

select lives_ok($$ insert into public.pets (name, species) values ('Bruno', 'dog') $$, 'Dogs can join');
select lives_ok($$ insert into public.pets (name, species) values ('Misty', 'cat') $$, 'Cats can join');
select throws_ok(
  $$ insert into public.pets (name, species) values ('Kiwi', 'bird') $$,
  '23514', null,
  'Birds and other pets cannot be added'
);

select * from finish();
rollback;
