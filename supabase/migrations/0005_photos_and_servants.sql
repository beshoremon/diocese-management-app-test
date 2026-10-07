-- 0005: photos for servants/services/classes + servant suspension
-- Run each statement in Supabase SQL editor (alter type must commit before use).

-- 1) New status value for suspending a servant (إيقاف)
alter type public.approval_status add value if not exists 'suspended';

-- 2) Photo columns
alter table public.profiles add column if not exists photo_url text;
alter table public.services add column if not exists photo_url text;
alter table public.classes  add column if not exists photo_url text;

-- 3) Generic photos bucket (servant/service/class photos)
insert into storage.buckets (id, name, public) values ('photos', 'photos', true)
on conflict (id) do nothing;

create policy "photos_public_read" on storage.objects for select using (bucket_id = 'photos');
create policy "photos_auth_write" on storage.objects for insert with check (
  bucket_id = 'photos' and auth.role() = 'authenticated'
);
create policy "photos_auth_update" on storage.objects for update using (
  bucket_id = 'photos' and auth.role() = 'authenticated'
);
create policy "photos_auth_delete" on storage.objects for delete using (
  bucket_id = 'photos' and auth.role() = 'authenticated'
);

-- 4) Service manager may also delete servants within his service
drop policy if exists profiles_delete on public.profiles;
create policy profiles_delete on public.profiles for delete using (
  public.is_owner()
  or (public.my_role() = 'church_manager' and church_id = public.my_church())
  or (public.my_role() = 'service_manager' and service_id = public.my_service())
);
