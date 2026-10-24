-- Storage buckets and access rules. Images only, 5 MB max
-- (the app compresses to ~300 KB before upload).
--
--   avatars              public   <user id>/<file>          profile photos
--   pet-photos           public   <user id>/<file>          pet photos (up to 6 per pet)
--   verification-photos  private  <user id>/<file>          owner + admins only
--   chat-images          private  <conversation id>/<file>  conversation members only
--
-- Public buckets serve files by unguessable URL so feeds and cards load fast;
-- who can find those URLs is still controlled by RLS on profiles and pets.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('avatars',             'avatars',             true,  5242880, '{image/jpeg,image/png,image/webp}'),
  ('pet-photos',          'pet-photos',          true,  5242880, '{image/jpeg,image/png,image/webp}'),
  ('verification-photos', 'verification-photos', false, 5242880, '{image/jpeg,image/png,image/webp}'),
  ('chat-images',         'chat-images',         false, 5242880, '{image/jpeg,image/png,image/webp}')
on conflict (id) do nothing;

-- First folder of an object path, as a conversation id (null if not a uuid).
create or replace function private.path_conversation_id(object_name text)
returns uuid
language plpgsql
immutable
set search_path = ''
as $$
declare
  folder text := split_part(object_name, '/', 1);
begin
  if folder ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return folder::uuid;
  end if;
  return null;
end;
$$;

grant execute on function private.path_conversation_id(text) to authenticated;

-- ---------------------------------------------------------------------------
-- avatars, pet-photos: users manage files in their own folder
-- ---------------------------------------------------------------------------

create policy "Users read their own public images"
  on storage.objects for select
  to authenticated
  using (
    bucket_id in ('avatars', 'pet-photos')
    and split_part(name, '/', 1) = auth.uid()::text
  );

create policy "Users upload public images to their own folder"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id in ('avatars', 'pet-photos')
    and split_part(name, '/', 1) = auth.uid()::text
  );

create policy "Users replace their own public images"
  on storage.objects for update
  to authenticated
  using (
    bucket_id in ('avatars', 'pet-photos')
    and split_part(name, '/', 1) = auth.uid()::text
  );

create policy "Users delete their own public images"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id in ('avatars', 'pet-photos')
    and split_part(name, '/', 1) = auth.uid()::text
  );

-- ---------------------------------------------------------------------------
-- verification-photos: upload once, readable by the owner and admins only.
-- No update or delete, so evidence stays intact while under review.
-- ---------------------------------------------------------------------------

create policy "Users upload verification photos to their own folder"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'verification-photos'
    and split_part(name, '/', 1) = auth.uid()::text
  );

create policy "Owners and admins read verification photos"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'verification-photos'
    and (split_part(name, '/', 1) = auth.uid()::text or private.is_admin())
  );

-- ---------------------------------------------------------------------------
-- chat-images: members of the conversation only
-- ---------------------------------------------------------------------------

create policy "Members upload chat images"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'chat-images'
    and private.can_post(private.path_conversation_id(name))
  );

create policy "Members read chat images"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'chat-images'
    and private.is_conversation_member(private.path_conversation_id(name))
  );

-- ---------------------------------------------------------------------------
-- Verification requests must point at the user's own uploaded photos.
-- ---------------------------------------------------------------------------

drop policy "Unverified users submit a verification request" on public.verifications;
create policy "Unverified users submit a verification request"
  on public.verifications for insert
  to authenticated
  with check (
    user_id = auth.uid()
    and status = 'pending'
    and private.can_request_verification()
    and split_part(profile_photo_path, '/', 1) = auth.uid()::text
    and split_part(pet_photo_path, '/', 1) = auth.uid()::text
  );
