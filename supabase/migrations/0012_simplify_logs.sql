-- =====================================================================
-- 0012: SIMPLIFY THE LOG TABLES
--
-- The enrollment_id already says which church / service / class the
-- action belongs to, so the log tables no longer repeat those columns.
--
--   attendance_log: id, enrollment_id, action, points_delta,
--                   recorded_by, created_at
--   points_log:     id, enrollment_id, delta, recorded_by, created_at
--
-- (enrollment_id comes right after id; created/edited audit columns
--  live only on persons — for adding the person — and on enrollments —
--  for creating the enrollment.)
--
-- The old `attendance` table (scanner v1) is REMOVED — the app now uses
-- attendance_log everywhere. Its history is copied into attendance_log
-- first so no data is lost.
-- =====================================================================

begin;

-- =====================================================================
-- 1. Helper: scope check derived from the enrollment
-- =====================================================================
create or replace function public.can_access_enrollment(p_enrollment uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.enrollments e
     where e.id = p_enrollment
       and public.can_access(e.church_id, e.service_id, e.class_id)
  )
$$;

-- =====================================================================
-- 2. Rebuild ATTENDANCE_LOG in the new simple shape
-- =====================================================================
create table public.attendance_log_new (
  id            uuid primary key default gen_random_uuid(),
  enrollment_id uuid not null references public.enrollments(id) on delete cascade,
  action        text not null check (action in ('add', 'remove')),
  points_delta  integer not null default 5 check (points_delta >= 0),
  recorded_by   uuid references public.profiles(id),
  created_at    timestamptz not null default now()
);

-- Copy existing log rows
insert into public.attendance_log_new (id, enrollment_id, action, points_delta, recorded_by, created_at)
select id, enrollment_id, action, points_delta, recorded_by, created_at
from public.attendance_log;

-- Preserve the old scanner `attendance` history as 'add' log entries
-- (skip ids that would collide — there should be none, but be safe)
insert into public.attendance_log_new (id, enrollment_id, action, points_delta, recorded_by, created_at)
select a.id, a.enrollment_id, 'add', a.points_awarded, a.recorded_by, a.created_at
from public.attendance a
where not exists (select 1 from public.attendance_log_new n where n.id = a.id);

alter publication supabase_realtime drop table public.attendance_log;
drop table public.attendance_log;
alter table public.attendance_log_new rename to attendance_log;

create index idx_attendance_log_enrollment on public.attendance_log(enrollment_id);
create index idx_attendance_log_created on public.attendance_log(created_at);

-- =====================================================================
-- 3. Rebuild POINTS_LOG in the new simple shape
-- =====================================================================
create table public.points_log_new (
  id            uuid primary key default gen_random_uuid(),
  enrollment_id uuid not null references public.enrollments(id) on delete cascade,
  delta         integer not null check (delta <> 0),   -- positive = add, negative = subtract
  recorded_by   uuid references public.profiles(id),
  created_at    timestamptz not null default now()
);

insert into public.points_log_new (id, enrollment_id, delta, recorded_by, created_at)
select id, enrollment_id, delta, recorded_by, created_at
from public.points_log;

alter publication supabase_realtime drop table public.points_log;
drop table public.points_log;
alter table public.points_log_new rename to points_log;

create index idx_points_log_enrollment on public.points_log(enrollment_id);
create index idx_points_log_created on public.points_log(created_at);

-- =====================================================================
-- 4. REMOVE the old attendance table (unused — history copied above)
-- =====================================================================
alter publication supabase_realtime drop table public.attendance;
drop function if exists public.on_attendance_insert() cascade;
drop function if exists public.on_attendance_delete() cascade;
drop table public.attendance;

-- =====================================================================
-- 5. RLS — scope derived from the enrollment
-- =====================================================================
alter table public.attendance_log enable row level security;
alter table public.points_log enable row level security;

create policy attendance_log_select on public.attendance_log for select using (
  public.can_access_enrollment(enrollment_id)
);
create policy attendance_log_insert on public.attendance_log for insert with check (
  public.can_access_enrollment(enrollment_id) and recorded_by = auth.uid()
);

create policy points_log_select on public.points_log for select using (
  public.can_access_enrollment(enrollment_id)
);
create policy points_log_insert on public.points_log for insert with check (
  public.can_access_enrollment(enrollment_id) and recorded_by = auth.uid()
);

-- =====================================================================
-- 6. COUNTER TRIGGERS (re-attach to the rebuilt tables)
-- =====================================================================
create or replace function public.on_attendance_log_insert()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.action = 'add' then
    update public.enrollments
       set attendance_count = attendance_count + 1,
           points = points + new.points_delta
     where id = new.enrollment_id;
  else -- remove
    update public.enrollments
       set attendance_count = greatest(attendance_count - 1, 0),
           points = greatest(points - new.points_delta, 0)
     where id = new.enrollment_id;
  end if;
  return new;
end $$;
create trigger trg_attendance_log_insert after insert on public.attendance_log
for each row execute function public.on_attendance_log_insert();

create or replace function public.on_points_log_insert()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.enrollments
     set points = greatest(points + new.delta, 0)
   where id = new.enrollment_id;
  return new;
end $$;
create trigger trg_points_log_insert after insert on public.points_log
for each row execute function public.on_points_log_insert();

-- =====================================================================
-- 7. REALTIME
-- =====================================================================
alter publication supabase_realtime add table public.attendance_log;
alter publication supabase_realtime add table public.points_log;
alter table public.attendance_log replica identity full;
alter table public.points_log replica identity full;

commit;
