-- 0007: add "job" (الوظيفة) field to children
-- Used by the children page job selector/filter.

alter table public.children
  add column if not exists job text;

comment on column public.children.job is 'وظيفة المخدوم (اختياري) — يُستخدم في فلترة صفحة المخدومين';
