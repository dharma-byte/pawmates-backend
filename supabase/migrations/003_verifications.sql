-- Verification requests: a clear profile photo plus a photo of the owner
-- with their pet, reviewed by an admin.
--
-- Flow: unverified -> (submit) pending -> (admin) verified | rejected
--       needs_info sends the user back to unverified to resubmit.
-- Photos live in a private Storage bucket (added in the storage migration).

create type public.verification_method as enum ('email', 'photo', 'phone', 'id');
create type public.verification_request_status as enum ('pending', 'approved', 'rejected', 'needs_info');

create table public.verifications (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid not null references public.profiles (id) on delete cascade,
  method             public.verification_method not null default 'photo',
  profile_photo_path text not null,
  pet_photo_path     text not null,
  status             public.verification_request_status not null default 'pending',
  reviewed_by        uuid references public.profiles (id) on delete set null,
  reviewed_at        timestamptz,
  notes              text check (char_length(notes) <= 1000),
  created_at         timestamptz not null default now()
);

-- At most one open request per user.
create unique index verifications_one_pending_idx
  on public.verifications (user_id) where status = 'pending';
create index verifications_status_idx on public.verifications (status, created_at);

-- Submitting a request moves the profile to pending.
create or replace function private.verifications_after_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.profiles
  set verification_status = 'pending', verified_at = null
  where id = new.user_id;
  return new;
end;
$$;

create trigger verifications_after_insert
  after insert on public.verifications
  for each row execute function private.verifications_after_insert();

-- Admin review. Called from the admin dashboard via supabase.rpc().
create or replace function public.review_verification(
  request_id uuid,
  decision public.verification_request_status,
  review_notes text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  req public.verifications;
begin
  if not private.is_admin() then
    raise exception 'Only admins can review verifications' using errcode = '42501';
  end if;

  if decision = 'pending' then
    raise exception 'Decision must be approved, rejected or needs_info';
  end if;

  select * into req from public.verifications where id = request_id for update;
  if not found or req.status <> 'pending' then
    raise exception 'No pending verification request with id %', request_id;
  end if;

  if decision = 'approved' and not exists (
    select 1 from auth.users where id = req.user_id and email_confirmed_at is not null
  ) then
    raise exception 'User has not confirmed their email yet';
  end if;

  update public.verifications
  set status = decision, reviewed_by = auth.uid(), reviewed_at = now(), notes = review_notes
  where id = request_id;

  update public.profiles
  set verification_status = case decision
        when 'approved' then 'verified'::public.verification_status
        when 'rejected' then 'rejected'::public.verification_status
        else 'unverified'::public.verification_status
      end,
      verified_at = case when decision = 'approved' then now() end
  where id = req.user_id;
end;
$$;

revoke execute on function public.review_verification(uuid, public.verification_request_status, text) from public, anon;
grant execute on function public.review_verification(uuid, public.verification_request_status, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Privileges and Row Level Security
-- ---------------------------------------------------------------------------

revoke all on public.verifications from anon, authenticated;
grant select on public.verifications to authenticated;
grant insert (method, profile_photo_path, pet_photo_path) on public.verifications to authenticated;

alter table public.verifications enable row level security;

-- user_id defaults to the caller, so clients never send it.
alter table public.verifications alter column user_id set default auth.uid();

create policy "Users read their own verification requests"
  on public.verifications for select
  to authenticated
  using (user_id = auth.uid());

create policy "Admins read all verification requests"
  on public.verifications for select
  to authenticated
  using (private.is_admin());

create policy "Unverified users submit a verification request"
  on public.verifications for insert
  to authenticated
  with check (
    user_id = auth.uid()
    and status = 'pending'
    and exists (
      select 1 from public.profiles
      where id = auth.uid() and verification_status in ('unverified', 'rejected')
    )
  );
