-- Account self-service: data export, account deletion, managing blocks.
-- Account deletion and export are required under GDPR and India's DPDP Act.

-- Everything we hold about the caller, as one JSON document.
create or replace function public.export_my_data()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'exported_at', now(),
    'account', (
      select jsonb_build_object('email', u.email, 'created_at', u.created_at, 'last_sign_in_at', u.last_sign_in_at)
      from auth.users u where u.id = auth.uid()
    ),
    'profile', (
      select to_jsonb(p) - 'public_location' - 'location'
        || jsonb_build_object('location', (select to_jsonb(l) from public.get_my_location() l))
      from public.profiles p where p.id = auth.uid()
    ),
    'pets', coalesce((select jsonb_agg(to_jsonb(pt)) from public.pets pt where pt.owner_id = auth.uid()), '[]'),
    'verifications', coalesce((
      select jsonb_agg(jsonb_build_object('status', v.status, 'created_at', v.created_at, 'notes', v.notes))
      from public.verifications v where v.user_id = auth.uid()
    ), '[]'),
    'connections', coalesce((
      select jsonb_agg(jsonb_build_object(
        'with', case when c.requester_id = auth.uid() then c.addressee_id else c.requester_id end,
        'direction', case when c.requester_id = auth.uid() then 'sent' else 'received' end,
        'status', c.status, 'message', c.message, 'created_at', c.created_at))
      from public.connections c where auth.uid() in (c.requester_id, c.addressee_id)
    ), '[]'),
    'messages_sent', coalesce((
      select jsonb_agg(jsonb_build_object(
        'conversation_id', m.conversation_id, 'type', m.type, 'body', m.body,
        'created_at', m.created_at, 'deleted_at', m.deleted_at) order by m.created_at)
      from public.messages m where m.sender_id = auth.uid()
    ), '[]'),
    'blocks', coalesce((
      select jsonb_agg(jsonb_build_object('blocked_id', b.blocked_id, 'created_at', b.created_at))
      from public.blocks b where b.blocker_id = auth.uid()
    ), '[]'),
    'reports_filed', coalesce((
      select jsonb_agg(jsonb_build_object('target_type', r.target_type, 'reason', r.reason,
        'status', r.status, 'created_at', r.created_at))
      from public.reports r where r.reporter_id = auth.uid()
    ), '[]')
  );
$$;

-- Permanently delete the caller's account. Cascades to profile, pets,
-- verifications, connections, chat memberships, messages, blocks and reports.
-- The app removes the member's storage files first.
create or replace function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'Not signed in' using errcode = '42501';
  end if;
  delete from auth.users where id = auth.uid();
end;
$$;

-- People I blocked. Blocks hide profiles in both directions, so this is
-- the only way to see who to unblock.
create or replace function public.my_blocked_users()
returns table (user_id uuid, full_name text, username text, avatar_url text, blocked_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select p.id, p.full_name, p.username, p.avatar_url, b.created_at
  from public.blocks b
  join public.profiles p on p.id = b.blocked_id
  where b.blocker_id = auth.uid()
  order by b.created_at desc;
$$;

revoke execute on function public.export_my_data() from public, anon;
revoke execute on function public.delete_my_account() from public, anon;
revoke execute on function public.my_blocked_users() from public, anon;
grant execute on function public.export_my_data() to authenticated;
grant execute on function public.delete_my_account() to authenticated;
grant execute on function public.my_blocked_users() to authenticated;

-- Members may delete their own verification photos (account deletion).
create policy "Users delete their own verification photos"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'verification-photos'
    and split_part(name, '/', 1) = auth.uid()::text
  );
