-- Sniff requests and Pawmates (accepted connections).
--
-- A verified user sends a Sniff request to another verified user, optionally
-- from one of their pets to one of the other user's pets. When accepted,
-- both owners are Pawmates and chat unlocks (chat migration).
-- Blocking is handled separately by the blocks table (moderation migration).

create type public.connection_status as enum ('pending', 'accepted', 'declined');

create table public.connections (
  id            uuid primary key default gen_random_uuid(),
  requester_id  uuid not null default auth.uid()
                  references public.profiles (id) on delete cascade,
  addressee_id  uuid not null references public.profiles (id) on delete cascade,
  pet_id        uuid references public.pets (id) on delete set null,
  target_pet_id uuid references public.pets (id) on delete set null,
  message       text check (char_length(message) <= 300),
  status        public.connection_status not null default 'pending',
  responded_at  timestamptz,
  created_at    timestamptz not null default now(),
  check (requester_id <> addressee_id)
);

-- One connection per pair of users, whichever direction it was sent.
create unique index connections_pair_idx on public.connections (
  least(requester_id, addressee_id), greatest(requester_id, addressee_id)
);
create index connections_addressee_idx on public.connections (addressee_id, status);
create index connections_requester_idx on public.connections (requester_id, status);

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

create or replace function private.are_pawmates(a uuid, b uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.connections
    where status = 'accepted'
      and least(requester_id, addressee_id) = least(a, b)
      and greatest(requester_id, addressee_id) = greatest(a, b)
  );
$$;

grant execute on function private.are_pawmates(uuid, uuid) to authenticated;

-- Rate limit: at most 20 Sniff requests per user per 24 hours.
create or replace function private.connections_rate_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (
    select count(*) from public.connections
    where requester_id = new.requester_id
      and created_at > now() - interval '24 hours'
  ) >= 20 then
    raise exception 'Sniff request limit reached, try again tomorrow'
      using errcode = 'P0001';
  end if;
  return new;
end;
$$;

create trigger connections_rate_limit
  before insert on public.connections
  for each row execute function private.connections_rate_limit();

-- Addressee accepts or declines a pending request.
create or replace function public.respond_to_sniff(connection_id uuid, accept boolean)
returns public.connections
language plpgsql
security definer
set search_path = ''
as $$
declare
  result public.connections;
begin
  update public.connections
  set status = case when accept then 'accepted'::public.connection_status
                    else 'declined'::public.connection_status end,
      responded_at = now()
  where id = connection_id
    and addressee_id = auth.uid()
    and status = 'pending'
  returning * into result;

  if not found then
    raise exception 'No pending Sniff request with id % for you', connection_id;
  end if;

  return result;
end;
$$;

revoke execute on function public.respond_to_sniff(uuid, boolean) from public, anon;
grant execute on function public.respond_to_sniff(uuid, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- Privileges and Row Level Security
-- Status changes go through respond_to_sniff(); there is no direct UPDATE.
-- ---------------------------------------------------------------------------

revoke all on public.connections from anon, authenticated;
grant select, delete on public.connections to authenticated;
grant insert (addressee_id, pet_id, target_pet_id, message) on public.connections to authenticated;

alter table public.connections enable row level security;

create policy "Users read connections they are part of"
  on public.connections for select
  to authenticated
  using (auth.uid() in (requester_id, addressee_id));

create policy "Verified users send Sniff requests to verified users"
  on public.connections for insert
  to authenticated
  with check (
    requester_id = auth.uid()
    and status = 'pending'
    and private.is_verified()
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

-- Requester cancels a pending request; either side removes a Pawmate.
create policy "Users cancel requests or remove Pawmates"
  on public.connections for delete
  to authenticated
  using (
    (requester_id = auth.uid() and status = 'pending')
    or (auth.uid() in (requester_id, addressee_id) and status = 'accepted')
  );
