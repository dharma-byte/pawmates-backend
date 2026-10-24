-- Moderation: blocks, reports and bans.
--
-- Blocking works in both directions: neither user sees the other's profile
-- or pets, and they cannot send Sniff requests or messages to each other.
-- Reports go to an admin queue; admins resolve them and can ban users.

-- ---------------------------------------------------------------------------
-- Blocks
-- ---------------------------------------------------------------------------

create table public.blocks (
  blocker_id uuid not null default auth.uid()
               references public.profiles (id) on delete cascade,
  blocked_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);

create index blocks_blocked_idx on public.blocks (blocked_id);

create or replace function private.is_blocked_between(a uuid, b uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.blocks
    where (blocker_id = a and blocked_id = b)
       or (blocker_id = b and blocked_id = a)
  );
$$;

grant execute on function private.is_blocked_between(uuid, uuid) to authenticated;

-- Blocking someone also ends any Sniff request or Pawmate connection.
create or replace function private.blocks_after_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.connections
  where least(requester_id, addressee_id) = least(new.blocker_id, new.blocked_id)
    and greatest(requester_id, addressee_id) = greatest(new.blocker_id, new.blocked_id);
  return new;
end;
$$;

create trigger blocks_after_insert
  after insert on public.blocks
  for each row execute function private.blocks_after_insert();

revoke all on public.blocks from anon, authenticated;
grant select, delete on public.blocks to authenticated;
grant insert (blocked_id) on public.blocks to authenticated;

alter table public.blocks enable row level security;

-- Users see only who they blocked, never who blocked them.
create policy "Users see who they blocked"
  on public.blocks for select
  to authenticated
  using (blocker_id = auth.uid());

create policy "Users block others"
  on public.blocks for insert
  to authenticated
  with check (blocker_id = auth.uid());

create policy "Users unblock others"
  on public.blocks for delete
  to authenticated
  using (blocker_id = auth.uid());

-- ---------------------------------------------------------------------------
-- Apply blocks to existing rules
-- ---------------------------------------------------------------------------

drop policy "Verified users read verified profiles" on public.profiles;
create policy "Verified users read verified profiles"
  on public.profiles for select
  to authenticated
  using (
    verification_status = 'verified'
    and private.is_verified()
    and not private.is_blocked_between(auth.uid(), id)
  );

drop policy "Verified users read pets of verified owners" on public.pets;
create policy "Verified users read pets of verified owners"
  on public.pets for select
  to authenticated
  using (
    private.is_verified()
    and not private.is_blocked_between(auth.uid(), owner_id)
    and exists (
      select 1 from public.profiles
      where id = pets.owner_id and verification_status = 'verified'
    )
  );

drop policy "Verified users send Sniff requests to verified users" on public.connections;
create policy "Verified users send Sniff requests to verified users"
  on public.connections for insert
  to authenticated
  with check (
    requester_id = auth.uid()
    and status = 'pending'
    and private.is_verified()
    and not private.is_blocked_between(auth.uid(), addressee_id)
    and exists (
      select 1 from public.profiles
      where id = addressee_id and verification_status = 'verified'
    )
    and (pet_id is null or exists (
      select 1 from public.pets where id = pet_id and owner_id = auth.uid()
    ))
    and (target_pet_id is null or exists (
      select 1 from public.pets where id = target_pet_id and owner_id = addressee_id
    ))
  );

-- Chat: blocked users cannot open or post in a direct chat with each other.
create or replace function private.can_message(other uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.is_verified()
    and not private.is_blocked_between(auth.uid(), other)
    and exists (
      select 1 from public.profiles p
      where p.id = other
        and p.verification_status = 'verified'
        and (p.message_privacy = 'everyone' or private.are_pawmates(auth.uid(), other))
    );
$$;

-- ---------------------------------------------------------------------------
-- Bans
-- A banned user loses verification and cannot apply again.
-- ---------------------------------------------------------------------------

alter table public.profiles add column banned_at timestamptz;
alter table public.profiles add column ban_reason text;

-- security definer: users cannot read banned_at themselves.
create or replace function private.can_request_verification()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid()
      and verification_status in ('unverified', 'rejected')
      and banned_at is null
  );
$$;

grant execute on function private.can_request_verification() to authenticated;

drop policy "Unverified users submit a verification request" on public.verifications;
create policy "Unverified users submit a verification request"
  on public.verifications for insert
  to authenticated
  with check (
    user_id = auth.uid()
    and status = 'pending'
    and private.can_request_verification()
  );

create or replace function public.ban_user(target uuid, reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.is_admin() then
    raise exception 'Only admins can ban users' using errcode = '42501';
  end if;
  if target = auth.uid() then
    raise exception 'Admins cannot ban themselves';
  end if;

  update public.profiles
  set banned_at = now(), ban_reason = reason,
      verification_status = 'rejected', verified_at = null
  where id = target;
end;
$$;

create or replace function public.unban_user(target uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.is_admin() then
    raise exception 'Only admins can unban users' using errcode = '42501';
  end if;

  update public.profiles
  set banned_at = null, ban_reason = null, verification_status = 'unverified'
  where id = target;
end;
$$;

revoke execute on function public.ban_user(uuid, text) from public, anon;
revoke execute on function public.unban_user(uuid) from public, anon;
grant execute on function public.ban_user(uuid, text) to authenticated;
grant execute on function public.unban_user(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Reports
-- ---------------------------------------------------------------------------

create type public.report_target as enum (
  'profile', 'pet', 'message', 'group', 'event', 'post', 'comment'
);
create type public.report_reason as enum (
  'spam', 'harassment', 'inappropriate', 'fake_profile',
  'animal_welfare', 'scam', 'unsafe_meetup', 'other'
);
create type public.report_status as enum ('open', 'resolved', 'dismissed');

create table public.reports (
  id          uuid primary key default gen_random_uuid(),
  reporter_id uuid not null default auth.uid()
                references public.profiles (id) on delete cascade,
  target_type public.report_target not null,
  target_id   uuid not null,
  reason      public.report_reason not null,
  details     text check (char_length(details) <= 1000),
  status      public.report_status not null default 'open',
  resolved_by uuid references public.profiles (id) on delete set null,
  resolved_at timestamptz,
  admin_notes text check (char_length(admin_notes) <= 1000),
  created_at  timestamptz not null default now()
);

-- One open report per user per target.
create unique index reports_one_open_idx
  on public.reports (reporter_id, target_type, target_id) where status = 'open';
create index reports_queue_idx on public.reports (status, created_at);
create index reports_target_idx on public.reports (target_type, target_id);

-- Rate limit: 10 reports per user per hour.
create or replace function private.reports_rate_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (
    select count(*) from public.reports
    where reporter_id = new.reporter_id and created_at > now() - interval '1 hour'
  ) >= 10 then
    raise exception 'Report limit reached, try again later' using errcode = 'P0001';
  end if;
  return new;
end;
$$;

create trigger reports_rate_limit
  before insert on public.reports
  for each row execute function private.reports_rate_limit();

create or replace function public.resolve_report(
  report_id uuid,
  decision public.report_status,
  notes text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.is_admin() then
    raise exception 'Only admins can resolve reports' using errcode = '42501';
  end if;
  if decision = 'open' then
    raise exception 'Decision must be resolved or dismissed';
  end if;

  update public.reports
  set status = decision, resolved_by = auth.uid(), resolved_at = now(), admin_notes = notes
  where id = report_id and status = 'open';

  if not found then
    raise exception 'No open report with id %', report_id;
  end if;
end;
$$;

revoke execute on function public.resolve_report(uuid, public.report_status, text) from public, anon;
grant execute on function public.resolve_report(uuid, public.report_status, text) to authenticated;

revoke all on public.reports from anon, authenticated;
grant select on public.reports to authenticated;
grant insert (target_type, target_id, reason, details) on public.reports to authenticated;

alter table public.reports enable row level security;

create policy "Users read their own reports"
  on public.reports for select
  to authenticated
  using (reporter_id = auth.uid());

create policy "Admins read all reports"
  on public.reports for select
  to authenticated
  using (private.is_admin());

create policy "Users file reports"
  on public.reports for insert
  to authenticated
  with check (reporter_id = auth.uid() and status = 'open');

-- Admins can read a message only when it has been reported.
create policy "Admins read reported messages"
  on public.messages for select
  to authenticated
  using (
    private.is_admin()
    and exists (
      select 1 from public.reports r
      where r.target_type = 'message' and r.target_id = messages.id
    )
  );
