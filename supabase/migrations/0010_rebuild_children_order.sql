-- =====================================================================
-- 0010: REBUILD public.children with the new column order
--
--   id, church_id, service_id, class_id,
--   qr_code, name, gender, birthdate, phone, address, notes,
--   attendance_count, points, image_url,
--   created_at, created_by, edited_at, edited_by
--
-- Postgres cannot reorder columns, so we recreate the table and copy
-- the data, then re-attach FKs, RLS policies, triggers and realtime.
-- Existing data is PRESERVED.
-- =====================================================================

begin;

-- ---------- 1. New table in the exact requested order ----------
create table public.children_new (
  id               uuid primary key default gen_random_uuid(),
  church_id        uuid not null references public.churches(id) on delete cascade,
  service_id       uuid not null references public.services(id) on delete cascade,
  class_id         uuid not null references public.classes(id) on delete cascade,
  qr_code          text unique default encode(gen_random_bytes(12), 'hex'),
  name             text not null,
  gender           text check (gender in ('boy', 'girl')),
  birthdate        date,
  phone            text,
  address          text,
  notes            text,
  attendance_count integer not null default 0,
  points           integer not null default 0,
  image_url        text,
  created_at       timestamptz not null default now(),
  created_by       uuid references public.profiles(id),
  edited_at        timestamptz not null default now(),
  edited_by        uuid references public.profiles(id)
);

-- ---------- 2. Copy existing data ----------
insert into public.children_new (
  id, church_id, service_id, class_id,
  qr_code, name, gender, birthdate, phone, address, notes,
  attendance_count, points, image_url,
  created_at, created_by, edited_at, edited_by
)
select
  id, church_id, service_id, class_id,
  qr_code, name, gender, birthdate, phone, address, notes,
  attendance_count, points, photo_url,
  created_at, created_by, updated_at, null
from public.children;

-- ---------- 3. Detach dependents from the old table ----------
alter table public.attendance     drop constraint if exists attendance_child_id_fkey;
alter table public.attendance_log drop constraint if exists attendance_log_child_id_fkey;
alter table public.points_log     drop constraint if exists points_log_child_id_fkey;

alter publication supabase_realtime drop table public.children;

drop table public.children;

-- ---------- 4. Swap in the new table ----------
alter table public.children_new rename to children;

create index idx_children_class   on public.children(class_id);
create index idx_children_service on public.children(service_id);
create index idx_children_church  on public.children(church_id);

-- ---------- 5. Re-attach dependent FKs ----------
alter table public.attendance
  add constraint attendance_child_id_fkey
  foreign key (child_id) references public.children(id) on delete cascade;
alter table public.attendance_log
  add constraint attendance_log_child_id_fkey
  foreign key (child_id) references public.children(id) on delete cascade;
alter table public.points_log
  add constraint points_log_child_id_fkey
  foreign key (child_id) references public.children(id) on delete cascade;

-- ---------- 6. RLS + policies (same rules as before) ----------
alter table public.children enable row level security;

create policy children_select on public.children for select using (
  public.can_access(church_id, service_id, class_id)
);
create policy children_insert on public.children for insert with check (
  public.can_access(church_id, service_id, class_id)
);
create policy children_update on public.children for update using (
  public.can_access(church_id, service_id, class_id)
);
create policy children_delete on public.children for delete using (
  public.is_owner()
  or (public.my_role() = 'church_manager' and church_id = public.my_church())
  or (public.my_role() = 'service_manager' and service_id = public.my_service())
);

-- ---------- 7. Touch trigger: keep edited_at / edited_by fresh ----------
create or replace function public.touch_child_edited()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.edited_at := now();
  -- only stamp edited_by when the update comes from a logged-in user
  if auth.uid() is not null then
    new.edited_by := auth.uid();
  end if;
  return new;
end $$;
create trigger trg_children_edited before update on public.children
for each row execute function public.touch_child_edited();

-- ---------- 8. Counter trigger functions: drop updated_at references ----------
create or replace function public.on_attendance_insert()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.children
     set attendance_count = attendance_count + 1,
         points = points + new.points_awarded
   where id = new.child_id;
  return new;
end $$;

create or replace function public.on_attendance_delete()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.children
     set attendance_count = greatest(attendance_count - 1, 0),
         points = greatest(points - old.points_awarded, 0)
   where id = old.child_id;
  return old;
end $$;

create or replace function public.on_attendance_log_insert()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.action = 'add' then
    update public.children
       set attendance_count = attendance_count + 1,
           points = points + new.points_delta
     where id = new.child_id;
  else -- remove
    update public.children
       set attendance_count = greatest(attendance_count - 1, 0),
           points = greatest(points - new.points_delta, 0)
     where id = new.child_id;
  end if;
  return new;
end $$;

create or replace function public.on_points_log_insert()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.children
     set points = greatest(points + new.delta, 0)
   where id = new.child_id;
  return new;
end $$;

-- ---------- 9. Realtime ----------
alter publication supabase_realtime add table public.children;
alter table public.children replica identity full;

commit;
