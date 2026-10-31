-- Groups: breed clubs, neighbourhood groups and interest groups, each with a
-- group chat.
--
-- Groups are open: any verified member can find one and join it. Joining a
-- group adds you to its chat; leaving removes you. A group's map point is its
-- creator's FUZZED public point, so distances never reveal a home. All writes
-- go through RPCs; clients only read.

create type public.group_kind as enum ('breed', 'area', 'interest');

create table public.groups (
  id           uuid primary key default gen_random_uuid(),
  name         text not null check (char_length(btrim(name)) between 3 and 60),
  description  text check (char_length(description) <= 1000),
  kind         public.group_kind not null,
  species      public.pet_species,
  breed        text check (char_length(breed) <= 60),
  area_name    text check (char_length(area_name) <= 120),
  location     extensions.geography(point, 4326),
  created_by   uuid references public.profiles (id) on delete set null,
  member_count integer not null default 0,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  check (kind <> 'breed' or breed is not null)
);

create unique index groups_name_idx on public.groups (lower(btrim(name)));
create index groups_location_idx on public.groups using gist (location);

create trigger groups_set_updated_at
  before update on public.groups
  for each row execute function private.set_updated_at();

create table public.group_members (
  group_id  uuid not null references public.groups (id) on delete cascade,
  user_id   uuid not null references public.profiles (id) on delete cascade,
  role      text not null default 'member' check (role in ('owner', 'admin', 'member')),
  joined_at timestamptz not null default now(),
  primary key (group_id, user_id)
);

create index group_members_user_idx on public.group_members (user_id);

-- The chat and events migrations left these columns waiting for groups.
alter table public.conversations
  add constraint conversations_group_id_fkey
  foreign key (group_id) references public.groups (id) on delete cascade;
alter table public.events
  add constraint events_group_id_fkey
  foreign key (group_id) references public.groups (id) on delete cascade;

create index events_group_idx on public.events (group_id, starts_at);

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- My role in a group, or null if I'm not a member.
create or replace function private.group_role(g uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select role from public.group_members where group_id = g and user_id = auth.uid();
$$;

create or replace function private.is_group_member(g uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.group_role(g) is not null;
$$;

grant execute on function private.group_role(uuid) to authenticated;
grant execute on function private.is_group_member(uuid) to authenticated;

-- Membership drives the member count and the group chat:
--   join   -> counted, added to the chat
--   leave  -> uncounted, removed from the chat; if the owner left, the
--             longest-standing admin (else member) becomes owner; an empty
--             group is deleted.
create or replace function private.group_members_after_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  conv uuid;
begin
  if tg_op = 'INSERT' then
    update public.groups set member_count = member_count + 1 where id = new.group_id;
    select id into conv from public.conversations where type = 'group' and group_id = new.group_id;
    if conv is not null then
      insert into public.conversation_members (conversation_id, user_id)
      values (conv, new.user_id)
      on conflict do nothing;
    end if;
    return new;
  end if;

  update public.groups set member_count = member_count - 1 where id = old.group_id;
  delete from public.conversation_members cm
  using public.conversations c
  where c.id = cm.conversation_id and c.type = 'group' and c.group_id = old.group_id
    and cm.user_id = old.user_id;

  if old.role = 'owner' then
    update public.group_members set role = 'owner'
    where (group_id, user_id) = (
      select group_id, user_id from public.group_members
      where group_id = old.group_id
      order by role = 'admin' desc, joined_at
      limit 1
    );
  end if;

  if not exists (select 1 from public.group_members where group_id = old.group_id) then
    delete from public.groups where id = old.group_id;
  end if;
  return old;
end;
$$;

create trigger group_members_after_change
  after insert or delete on public.group_members
  for each row execute function private.group_members_after_change();

-- ---------------------------------------------------------------------------
-- RPCs
-- ---------------------------------------------------------------------------

-- Start a group. Its point and area come from the creator's fuzzed location.
create or replace function public.create_group(
  name        text,
  kind        public.group_kind,
  description text default null,
  species     public.pet_species default null,
  breed       text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  me     uuid := auth.uid();
  new_id uuid;
begin
  if not private.is_verified() then
    raise exception 'Only verified members can start groups' using errcode = '42501';
  end if;
  if (select count(*) from public.groups where created_by = me and created_at > now() - interval '1 day') >= 3 then
    raise exception 'You can start up to 3 groups a day' using errcode = 'P0001';
  end if;

  insert into public.groups (name, description, kind, species, breed, area_name, location, created_by)
  select btrim(create_group.name), nullif(btrim(create_group.description), ''), create_group.kind,
         create_group.species, nullif(btrim(create_group.breed), ''), p.area_name, p.public_location, me
  from public.profiles p
  where p.id = me
  returning id into new_id;

  -- The chat first, so the owner's membership trigger adds them to it.
  insert into public.conversations (type, group_id) values ('group', new_id);
  insert into public.group_members (group_id, user_id, role) values (new_id, me, 'owner');
  return new_id;
end;
$$;

create or replace function public.update_group(g uuid, name text, description text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if coalesce(private.group_role(g), '') not in ('owner', 'admin') then
    raise exception 'Only group admins can edit the group' using errcode = '42501';
  end if;
  update public.groups
  set name = btrim(update_group.name), description = nullif(btrim(update_group.description), '')
  where id = g;
end;
$$;

create or replace function public.join_group(g uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  conv uuid;
begin
  if not private.is_verified() then
    raise exception 'Only verified members can join groups' using errcode = '42501';
  end if;
  if not exists (select 1 from public.groups where id = g) then
    raise exception 'Group not found' using errcode = 'P0002';
  end if;

  insert into public.group_members (group_id, user_id) values (g, auth.uid())
  on conflict do nothing;

  select id into conv from public.conversations where type = 'group' and group_id = g;
  return conv;
end;
$$;

create or replace function public.leave_group(g uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  delete from public.group_members where group_id = g and user_id = auth.uid();
$$;

-- Owners remove anyone; admins remove plain members.
create or replace function public.remove_group_member(g uuid, member uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  my_role    text := private.group_role(g);
  their_role text;
begin
  select role into their_role from public.group_members where group_id = g and user_id = member;
  if their_role is null then
    return;
  end if;
  if member = auth.uid()
     or my_role is null
     or my_role = 'member'
     or (my_role = 'admin' and their_role <> 'member') then
    raise exception 'You can''t remove this member' using errcode = '42501';
  end if;
  delete from public.group_members where group_id = g and user_id = member;
end;
$$;

-- Owners promote members to admin or demote admins.
create or replace function public.set_group_admin(g uuid, member uuid, make_admin boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if private.group_role(g) is distinct from 'owner' then
    raise exception 'Only the group owner can change admins' using errcode = '42501';
  end if;
  update public.group_members
  set role = case when make_admin then 'admin' else 'member' end
  where group_id = g and user_id = member and role <> 'owner';
end;
$$;

create or replace function public.delete_group(g uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if private.group_role(g) is distinct from 'owner' and not private.is_admin() then
    raise exception 'Only the group owner can delete the group' using errcode = '42501';
  end if;
  delete from public.groups where id = g;
end;
$$;

-- Find groups: my groups plus groups within radius_km, optionally filtered by
-- text (name, breed, area) and kind. Distance uses fuzzed points only.
create or replace function public.find_groups(
  search      text default null,
  kind_filter public.group_kind default null,
  radius_km   integer default 25
)
returns table (
  id           uuid,
  name         text,
  description  text,
  kind         public.group_kind,
  species      public.pet_species,
  breed        text,
  area_name    text,
  member_count integer,
  distance_km  numeric,
  my_role      text,
  created_at   timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  with me as (
    select public_location as center from public.profiles where id = auth.uid()
  )
  select
    g.id, g.name, g.description, g.kind, g.species, g.breed, g.area_name, g.member_count,
    case when g.location is not null and me.center is not null
         then private.round_distance_km(extensions.st_distance(g.location, me.center)) end,
    gm.role,
    g.created_at
  from public.groups g
  cross join me
  left join public.group_members gm on gm.group_id = g.id and gm.user_id = auth.uid()
  where private.is_verified()
    and (kind_filter is null or g.kind = kind_filter)
    and (
      nullif(btrim(search), '') is null
      or g.name ilike '%' || btrim(search) || '%'
      or g.breed ilike '%' || btrim(search) || '%'
      or g.area_name ilike '%' || btrim(search) || '%'
    )
    and (
      gm.role is not null
      or g.location is null
      or me.center is null
      or extensions.st_dwithin(g.location, me.center, least(greatest(radius_km, 1), 100) * 1000)
    )
  order by gm.role is not null desc,
           case when g.location is not null and me.center is not null
                then extensions.st_distance(g.location, me.center) end nulls last,
           g.member_count desc
  limit 60;
$$;

revoke execute on function public.create_group(text, public.group_kind, text, public.pet_species, text) from public, anon;
revoke execute on function public.update_group(uuid, text, text) from public, anon;
revoke execute on function public.join_group(uuid) from public, anon;
revoke execute on function public.leave_group(uuid) from public, anon;
revoke execute on function public.remove_group_member(uuid, uuid) from public, anon;
revoke execute on function public.set_group_admin(uuid, uuid, boolean) from public, anon;
revoke execute on function public.delete_group(uuid) from public, anon;
revoke execute on function public.find_groups(text, public.group_kind, integer) from public, anon;
grant execute on function public.create_group(text, public.group_kind, text, public.pet_species, text) to authenticated;
grant execute on function public.update_group(uuid, text, text) to authenticated;
grant execute on function public.join_group(uuid) to authenticated;
grant execute on function public.leave_group(uuid) to authenticated;
grant execute on function public.remove_group_member(uuid, uuid) to authenticated;
grant execute on function public.set_group_admin(uuid, uuid, boolean) to authenticated;
grant execute on function public.delete_group(uuid) to authenticated;
grant execute on function public.find_groups(text, public.group_kind, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- Privileges and Row Level Security: reads only.
-- ---------------------------------------------------------------------------

revoke all on public.groups from anon, authenticated;
revoke all on public.group_members from anon, authenticated;

-- No raw location: distances come from find_groups().
grant select (id, name, description, kind, species, breed, area_name, created_by, member_count, created_at)
  on public.groups to authenticated;
grant select on public.group_members to authenticated;

alter table public.groups enable row level security;
alter table public.group_members enable row level security;

create policy "Verified members read groups"
  on public.groups for select
  to authenticated
  using (private.is_verified());

create policy "Members see who is in their groups"
  on public.group_members for select
  to authenticated
  using (user_id = auth.uid() or private.is_group_member(group_id));
