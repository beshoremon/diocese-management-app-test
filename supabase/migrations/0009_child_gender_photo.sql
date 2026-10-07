-- =====================================================================
-- 0009: Add-child module fields
--       gender (boy/girl) + photo_url (webp stored in photos bucket)
-- =====================================================================

alter table public.children
  add column if not exists gender text check (gender in ('boy', 'girl')),
  add column if not exists photo_url text;

comment on column public.children.gender is 'نوع المخدوم: boy = ولد، girl = بنت';
comment on column public.children.photo_url is 'صورة المخدوم (webp) من bucket الصور العام';
