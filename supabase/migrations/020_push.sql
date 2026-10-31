-- Phone and browser push notifications.
--
-- Members opt in per device; each device's Web Push subscription is stored
-- here. When a notification row is created, a trigger posts it (with the
-- member's subscriptions) to the website's /api/push endpoint over pg_net,
-- and the website delivers it through the browser's push service. Expired
-- subscriptions are removed again through remove_push_subscriptions().
--
-- Per environment, two Vault secrets switch this on (nothing is sent until
-- both exist, so tests and unconfigured environments are unaffected):
--   push_endpoint_url    e.g. https://pawmates-web-phi.vercel.app/api/push
--   push_webhook_secret  a long random string, also set as PUSH_WEBHOOK_SECRET
--                        on the website

create extension if not exists pg_net;

create table public.push_subscriptions (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.profiles (id) on delete cascade,
  endpoint   text not null unique check (endpoint like 'https://%' and char_length(endpoint) <= 1000),
  p256dh     text not null check (char_length(p256dh) <= 200),
  auth       text not null check (char_length(auth) <= 100),
  user_agent text check (char_length(user_agent) <= 300),
  created_at timestamptz not null default now()
);

create index push_subscriptions_user_idx on public.push_subscriptions (user_id);

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

create or replace function private.vault_secret(secret_name text)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select decrypted_secret from vault.decrypted_secrets where name = secret_name limit 1;
$$;

-- Never lets a push problem block the notification itself.
create or replace function private.notifications_push()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  url    text;
  secret text;
  subs   jsonb;
begin
  begin
    url := private.vault_secret('push_endpoint_url');
    secret := private.vault_secret('push_webhook_secret');
    if url is null or secret is null then
      return new;
    end if;

    select jsonb_agg(jsonb_build_object('endpoint', s.endpoint, 'keys', jsonb_build_object('p256dh', s.p256dh, 'auth', s.auth)))
    into subs
    from public.push_subscriptions s
    where s.user_id = new.user_id;
    if subs is null then
      return new;
    end if;

    perform net.http_post(
      url := url,
      body := jsonb_build_object(
        'subscriptions', subs,
        'notification', jsonb_build_object(
          'id', new.id, 'type', new.type, 'title', new.title, 'body', new.body, 'link', new.link)),
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', secret),
      timeout_milliseconds := 5000);
  exception when others then
    raise warning 'push not sent for notification %: %', new.id, sqlerrm;
  end;
  return new;
end;
$$;

create trigger notifications_push
  after insert on public.notifications
  for each row execute function private.notifications_push();

-- ---------------------------------------------------------------------------
-- RPCs
-- ---------------------------------------------------------------------------

-- Save this device for the signed-in member. A device that was signed in as
-- someone else moves to the current member.
create or replace function public.save_push_subscription(
  endpoint   text,
  p256dh     text,
  auth_key   text,
  user_agent text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'Sign in to turn on notifications' using errcode = '42501';
  end if;
  if (select count(*) from public.push_subscriptions where user_id = auth.uid()) >= 10 then
    delete from public.push_subscriptions
    where id = (select id from public.push_subscriptions where user_id = auth.uid() order by created_at limit 1);
  end if;

  insert into public.push_subscriptions (user_id, endpoint, p256dh, auth, user_agent)
  values (auth.uid(), save_push_subscription.endpoint, save_push_subscription.p256dh,
          save_push_subscription.auth_key, left(save_push_subscription.user_agent, 300))
  on conflict on constraint push_subscriptions_endpoint_key do update
  set user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth,
      user_agent = excluded.user_agent, created_at = now();
end;
$$;

create or replace function public.delete_push_subscription(endpoint text)
returns void
language sql
security definer
set search_path = ''
as $$
  delete from public.push_subscriptions
  where push_subscriptions.endpoint = delete_push_subscription.endpoint and user_id = auth.uid();
$$;

-- Called by the website (no member session) to drop subscriptions the push
-- service reported as gone. Guarded by the shared secret.
create or replace function public.remove_push_subscriptions(secret text, endpoints text[])
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  removed integer;
begin
  if secret is null or secret is distinct from private.vault_secret('push_webhook_secret') then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  delete from public.push_subscriptions where endpoint = any (endpoints);
  get diagnostics removed = row_count;
  return removed;
end;
$$;

revoke execute on function public.save_push_subscription(text, text, text, text) from public, anon;
revoke execute on function public.delete_push_subscription(text) from public, anon;
revoke execute on function public.remove_push_subscriptions(text, text[]) from public;
grant execute on function public.save_push_subscription(text, text, text, text) to authenticated;
grant execute on function public.delete_push_subscription(text) to authenticated;
grant execute on function public.remove_push_subscriptions(text, text[]) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Privileges and Row Level Security: members see their own devices; writes
-- go through the RPCs.
-- ---------------------------------------------------------------------------

revoke all on public.push_subscriptions from anon, authenticated;
grant select (id, endpoint, user_agent, created_at) on public.push_subscriptions to authenticated;

alter table public.push_subscriptions enable row level security;

create policy "Members see their own devices"
  on public.push_subscriptions for select
  to authenticated
  using (user_id = auth.uid());
