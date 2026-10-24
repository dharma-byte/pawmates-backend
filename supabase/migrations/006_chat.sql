-- Real-time chat: conversations, members (read receipts, mute) and messages.
--
-- Direct chats open between Pawmates, or with anyone whose message_privacy
-- is 'everyone'. Group and event conversations are created by the groups and
-- events migrations. New messages reach clients through Supabase Realtime;
-- typing and presence use private Realtime channels named chat:<conversation id>.

create type public.conversation_type as enum ('direct', 'group', 'event');
create type public.message_type as enum ('text', 'image', 'location', 'invite');

create table public.conversations (
  id              uuid primary key default gen_random_uuid(),
  type            public.conversation_type not null,
  group_id        uuid,  -- foreign key added in the groups migration
  event_id        uuid,  -- foreign key added in the events migration
  -- For direct chats: the two members, lowest id first, so each pair has one chat.
  user_low        uuid references public.profiles (id) on delete cascade,
  user_high       uuid references public.profiles (id) on delete cascade,
  last_message_at timestamptz,
  created_at      timestamptz not null default now(),
  check (
    (type = 'direct' and user_low < user_high and group_id is null and event_id is null)
    or (type = 'group' and group_id is not null and user_low is null)
    or (type = 'event' and event_id is not null and user_low is null)
  )
);

create unique index conversations_direct_pair_idx
  on public.conversations (user_low, user_high) where type = 'direct';
create unique index conversations_group_idx on public.conversations (group_id) where type = 'group';
create unique index conversations_event_idx on public.conversations (event_id) where type = 'event';

create table public.conversation_members (
  conversation_id uuid not null references public.conversations (id) on delete cascade,
  user_id         uuid not null references public.profiles (id) on delete cascade,
  role            text not null default 'member' check (role in ('member', 'admin')),
  last_read_at    timestamptz not null default now(),
  muted           boolean not null default false,
  joined_at       timestamptz not null default now(),
  primary key (conversation_id, user_id)
);

create index conversation_members_user_idx on public.conversation_members (user_id);

create table public.messages (
  id              uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations (id) on delete cascade,
  sender_id       uuid not null default auth.uid()
                    references public.profiles (id) on delete cascade,
  type            public.message_type not null default 'text',
  body            text check (char_length(body) <= 4000),
  attachment_url  text,
  location        extensions.geography(point, 4326),
  metadata        jsonb not null default '{}',
  edited_at       timestamptz,
  deleted_at      timestamptz,
  created_at      timestamptz not null default now(),
  check (
    deleted_at is not null
    or (type = 'text' and char_length(btrim(body)) > 0)
    or (type = 'image' and attachment_url is not null)
    or (type = 'location' and location is not null)
    or (type = 'invite' and metadata <> '{}')
  )
);

create index messages_conversation_created_idx
  on public.messages (conversation_id, created_at desc);

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

create or replace function private.is_conversation_member(conv uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.conversation_members
    where conversation_id = conv and user_id = auth.uid()
  );
$$;

-- Can the current user message `other`? Pawmates always can; otherwise only
-- if `other` accepts messages from everyone. (Blocks are added later.)
create or replace function private.can_message(other uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.is_verified()
    and exists (
      select 1 from public.profiles p
      where p.id = other
        and p.verification_status = 'verified'
        and (p.message_privacy = 'everyone' or private.are_pawmates(auth.uid(), other))
    );
$$;

-- Can the current user post in this conversation right now?
create or replace function private.can_post(conv uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.is_conversation_member(conv)
    and private.is_verified()
    and coalesce((
      select private.can_message(
        case when c.user_low = auth.uid() then c.user_high else c.user_low end
      )
      from public.conversations c
      where c.id = conv and c.type = 'direct'
    ), true);
$$;

grant execute on function private.is_conversation_member(uuid) to authenticated;
grant execute on function private.can_message(uuid) to authenticated;
grant execute on function private.can_post(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- RPCs
-- ---------------------------------------------------------------------------

-- Open (or reuse) the direct chat with another user. Returns its id.
create or replace function public.get_or_create_direct_conversation(other_user uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  me   uuid := auth.uid();
  low  uuid := least(me, other_user);
  high uuid := greatest(me, other_user);
  conv uuid;
begin
  if me is null or other_user = me then
    raise exception 'Invalid chat partner';
  end if;

  select id into conv from public.conversations
  where type = 'direct' and user_low = low and user_high = high;

  if conv is not null then
    return conv;
  end if;

  if not private.can_message(other_user) then
    raise exception 'You can only message your Pawmates or users who accept messages from everyone'
      using errcode = '42501';
  end if;

  insert into public.conversations (type, user_low, user_high)
  values ('direct', low, high)
  returning id into conv;

  insert into public.conversation_members (conversation_id, user_id)
  values (conv, me), (conv, other_user);

  return conv;
end;
$$;

-- Inbox: my conversations with unread counts and the latest message.
create or replace function public.get_my_conversations()
returns table (
  conversation_id   uuid,
  type              public.conversation_type,
  other_user_id     uuid,
  group_id          uuid,
  event_id          uuid,
  last_message_at   timestamptz,
  last_message_body text,
  last_message_type public.message_type,
  unread_count      integer,
  muted             boolean
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    c.id,
    c.type,
    case when c.type = 'direct'
         then case when c.user_low = auth.uid() then c.user_high else c.user_low end
    end,
    c.group_id,
    c.event_id,
    c.last_message_at,
    last_msg.body,
    last_msg.type,
    (
      select count(*)::int from public.messages m
      where m.conversation_id = c.id
        and m.created_at > cm.last_read_at
        and m.sender_id <> auth.uid()
        and m.deleted_at is null
    ),
    cm.muted
  from public.conversation_members cm
  join public.conversations c on c.id = cm.conversation_id
  left join lateral (
    select m.body, m.type from public.messages m
    where m.conversation_id = c.id and m.deleted_at is null
    order by m.created_at desc
    limit 1
  ) last_msg on true
  where cm.user_id = auth.uid()
  order by c.last_message_at desc nulls last;
$$;

-- Mark a conversation as read up to now (drives read receipts and unread counts).
create or replace function public.mark_conversation_read(conv uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.conversation_members
  set last_read_at = now()
  where conversation_id = conv and user_id = auth.uid();
$$;

revoke execute on function public.get_or_create_direct_conversation(uuid) from public, anon;
revoke execute on function public.get_my_conversations() from public, anon;
revoke execute on function public.mark_conversation_read(uuid) from public, anon;
grant execute on function public.get_or_create_direct_conversation(uuid) to authenticated;
grant execute on function public.get_my_conversations() to authenticated;
grant execute on function public.mark_conversation_read(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Triggers
-- ---------------------------------------------------------------------------

-- Rate limit: 30 messages per user per minute.
create or replace function private.messages_before_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (
    select count(*) from public.messages
    where sender_id = new.sender_id and created_at > now() - interval '1 minute'
  ) >= 30 then
    raise exception 'You are sending messages too fast, slow down'
      using errcode = 'P0001';
  end if;
  return new;
end;
$$;

create trigger messages_before_insert
  before insert on public.messages
  for each row execute function private.messages_before_insert();

-- Bump the conversation and mark it read for the sender.
create or replace function private.messages_after_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.conversations set last_message_at = new.created_at
  where id = new.conversation_id;

  update public.conversation_members set last_read_at = new.created_at
  where conversation_id = new.conversation_id and user_id = new.sender_id;

  return new;
end;
$$;

create trigger messages_after_insert
  after insert on public.messages
  for each row execute function private.messages_after_insert();

-- Edits stamp edited_at; deletes are soft and clear the content.
create or replace function private.messages_before_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.deleted_at is not null and old.deleted_at is null then
    new.deleted_at = now();
    new.body = null;
    new.attachment_url = null;
    new.location = null;
    new.metadata = '{}';
  elsif new.body is distinct from old.body then
    if old.type <> 'text' or old.deleted_at is not null then
      raise exception 'Only text messages can be edited';
    end if;
    new.edited_at = now();
  end if;
  return new;
end;
$$;

create trigger messages_before_update
  before update on public.messages
  for each row execute function private.messages_before_update();

-- ---------------------------------------------------------------------------
-- Privileges and Row Level Security
-- Conversations and memberships are created only through RPCs.
-- ---------------------------------------------------------------------------

revoke all on public.conversations from anon, authenticated;
revoke all on public.conversation_members from anon, authenticated;
revoke all on public.messages from anon, authenticated;

grant select on public.conversations to authenticated;
grant select on public.conversation_members to authenticated;
grant update (muted) on public.conversation_members to authenticated;
grant select on public.messages to authenticated;
grant insert (conversation_id, type, body, attachment_url, location, metadata)
  on public.messages to authenticated;
grant update (body, deleted_at) on public.messages to authenticated;

alter table public.conversations enable row level security;
alter table public.conversation_members enable row level security;
alter table public.messages enable row level security;

create policy "Members read their conversations"
  on public.conversations for select
  to authenticated
  using (private.is_conversation_member(id));

create policy "Members see who is in their conversations"
  on public.conversation_members for select
  to authenticated
  using (private.is_conversation_member(conversation_id));

create policy "Users mute or unmute their own membership"
  on public.conversation_members for update
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create policy "Members read messages"
  on public.messages for select
  to authenticated
  using (private.is_conversation_member(conversation_id));

create policy "Members send messages"
  on public.messages for insert
  to authenticated
  with check (sender_id = auth.uid() and private.can_post(conversation_id));

create policy "Senders edit or delete their own messages"
  on public.messages for update
  to authenticated
  using (sender_id = auth.uid())
  with check (sender_id = auth.uid());

-- ---------------------------------------------------------------------------
-- Realtime
-- ---------------------------------------------------------------------------

-- Stream new and changed rows to subscribed clients (RLS still applies).
alter publication supabase_realtime add table public.messages;
alter publication supabase_realtime add table public.conversation_members;

-- Private broadcast/presence channels `chat:<conversation id>`:
-- only members may listen (typing, online) or send (typing).
create or replace function private.can_use_chat_topic(topic text)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if topic !~ '^chat:[0-9a-f-]{36}$' then
    return false;
  end if;
  return private.is_conversation_member(substring(topic from 6)::uuid);
end;
$$;

grant execute on function private.can_use_chat_topic(text) to authenticated;

create policy "Chat members receive typing and presence"
  on realtime.messages for select
  to authenticated
  using (private.can_use_chat_topic(realtime.topic()));

create policy "Chat members send typing and presence"
  on realtime.messages for insert
  to authenticated
  with check (private.can_use_chat_topic(realtime.topic()));
