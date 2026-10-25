-- Admin helpers for the moderation dashboard.
-- is_admin itself stays unreadable by clients; this only answers for the caller.

create or replace function public.am_i_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.is_admin();
$$;

revoke execute on function public.am_i_admin() from public, anon;
grant execute on function public.am_i_admin() to authenticated;

-- Basic dashboard numbers. Admins only.
create or replace function public.admin_stats()
returns table (
  total_users           integer,
  verified_users        integer,
  pending_verifications integer,
  open_reports          integer,
  pets                  integer,
  messages_last_7_days  integer
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not private.is_admin() then
    raise exception 'Only admins can view stats' using errcode = '42501';
  end if;

  return query
  select
    (select count(*)::int from public.profiles),
    (select count(*)::int from public.profiles where verification_status = 'verified'),
    (select count(*)::int from public.verifications where status = 'pending'),
    (select count(*)::int from public.reports where status = 'open'),
    (select count(*)::int from public.pets),
    (select count(*)::int from public.messages where created_at > now() - interval '7 days');
end;
$$;

revoke execute on function public.admin_stats() from public, anon;
grant execute on function public.admin_stats() to authenticated;
