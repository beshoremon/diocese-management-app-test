-- =====================================================================
-- 0013: EVENTS & CAUSES
--
-- 1. New master table `events`  — bound to church/service/class.
--    Attendance is registered AGAINST AN EVENT: attendance_log now has
--    event_id (right after enrollment_id) instead of the old `action`
--    column. One attendance per enrollment per event (unique).
--
-- 2. Attendance REMOVAL no longer adds a 'remove' entry — it DELETES
--    the attendance entry, and a delete-trigger reverts the counters
--    (attendance_count - 1, points - points_delta).
--
-- 3. New master table `causes` — bound to church/service/class.
--    points_log now has cause_id BEFORE delta.
--
-- Legacy data: old 'remove' rows are netted against the most recent
-- 'add' rows of the same enrollment (they cancel each other), and the
-- remaining 'add' rows are kept with event_id = null. Enrollment
-- counters are stored values and remain unchanged.
-- =====================================================================

begin;

-- =====================================================================
-- 1. EVENTS — bound to church / service / class
-- =====================================================================
create table public.events (
  id          uuid primary key default gen_random_uuid(),
  church_id   uuid not null references public.churches(id) on delete cascade,
  service_id  uuid not null references public.services(id) on delete cascade,
  class_id    uuid not null references public.classes(id) on delete cascade,
  name        text not null,
  description text,
  event_date  date,
  created_at  timestamptz not null default now(),
  created_by  uuid references public.profiles(id),
  edited_at   timestamptz not null default now(),
  edited_by   uuid references public.profiles(id)
);
create index idx_events_class on public.events(class_id);

-- =====================================================================
-- 2. CAUSES — bound to church / service / class (reasons for points)
-- =====================================================================
create table public.causes (
  id          uuid primary key default gen_random_uuid(),
  church_id   uuid not null references public.churches(id) on delete cascade,
  service_id  uuid not null references public.services(id) on delete cascade,
  class_id    uuid not null references public.classes(id) on delete cascade,
  name        text not null,
  description text,
  created_at  timestamptz not null default now(),
  created_by  uuid references public.profiles(id),
  edited_at   timestamptz not null default now(),
  edited_by   uuid references public.profiles(id)
);
create index idx_causes_class on public.causes(class_id);

-- touch triggers (edited_at) — reuse the helper from 0011
create trigger trg_events_touch before update on public.events
for each row execute function public.touch_edited();
create trigger trg_causes_touch before update on public.causes
for each row execute function public.touch_edited();

-- RLS: scoped exactly like classes
alter table public.events enable row level security;
alter table public.causes enable row level security;

create policy events_select on public.events for select using (
  public.can_access(church_id, service_id, class_id)
);
create policy events_insert on public.events for insert with check (
  public.can_access(church_id, service_id, class_id)
);
create policy events_update on public.events for update using (
  public.can_access(church_id, service_id, class_id)
) with check (
  public.can_access(church_id, service_id, class_id)
);
create policy events_delete on public.events for delete using (
  public.can_access(church_id, service_id, class_id)
);

create policy causes_select on public.causes for select using (
  public.can_access(church_id, service_id, class_id)
);
create policy causes_insert on public.causes for insert with check (
  public.can_access(church_id, service_id, class_id)
);
create policy causes_update on public.causes for update using (
  public.can_access(church_id, service_id, class_id)
) with check (
  public.can_access(church_id, service_id, class_id)
);
create policy causes_delete on public.causes for delete using (
  public.can_access(church_id, service_id, class_id)
);

-- =====================================================================
-- 3. Rebuild ATTENDANCE_LOG: event_id instead of action
-- =====================================================================
create table public.attendance_log_new (
  id            uuid primary key default gen_random_uuid(),
  enrollment_id uuid not null references public.enrollments(id) on delete cascade,
  event_id      uuid references public.events(id) on delete set null,
  points_delta  integer not null default 5 check (points_delta >= 0),
  recorded_by   uuid references public.profiles(id),
  created_at    timestamptz not null default now()
);

-- keep the 'add' history (legacy rows have no event)
insert into public.attendance_log_new (id, enrollment_id, event_id, points_delta, recorded_by, created_at)
select id, enrollment_id, null, points_delta, recorded_by, created_at
from public.attendance_log
where action = 'add';

-- net legacy 'remove' rows: each remove cancels the most recent add
-- of the same enrollment (counters are stored and stay unchanged)
with removes as (
  select id, enrollment_id,
         row_number() over (partition by enrollment_id order by created_at) as rn
  from public.attendance_log where action = 'remove'
),
adds as (
  select id, enrollment_id,
         row_number() over (partition by enrollment_id order by created_at desc) as rn
  from public.attendance_log where action = 'add'
)
delete from public.attendance_log_new n
using removes r
join adds a on a.enrollment_id = r.enrollment_id and a.rn = r.rn
where n.id = a.id;

alter publication supabase_realtime drop table public.attendance_log;
drop table public.attendance_log;
alter table public.attendance_log_new rename to attendance_log;

create index idx_attendance_log_enrollment on public.attendance_log(enrollment_id);
create index idx_attendance_log_created on public.attendance_log(created_at);
-- one attendance per enrollment per event
create unique index uq_attendance_enrollment_event
  on public.attendance_log(enrollment_id, event_id)
  where event_id is not null;

-- =====================================================================
-- 4. Rebuild POINTS_LOG: cause_id before delta
-- =====================================================================
create table public.points_log_new (
  id            uuid primary key default gen_random_uuid(),
  enrollment_id uuid not null references public.enrollments(id) on delete cascade,
  cause_id      uuid references public.causes(id) on delete set null,
  delta         integer not null check (delta <> 0),
  recorded_by   uuid references public.profiles(id),
  created_at    timestamptz not null default now()
);

insert into public.points_log_new (id, enrollment_id, cause_id, delta, recorded_by, created_at)
select id, enrollment_id, null, delta, recorded_by, created_at
from public.points_log;

alter publication supabase_realtime drop table public.points_log;
drop table public.points_log;
alter table public.points_log_new rename to points_log;

create index idx_points_log_enrollment on public.points_log(enrollment_id);
create index idx_points_log_created on public.points_log(created_at);

-- =====================================================================
-- 5. RLS on the rebuilt logs
-- =====================================================================
alter table public.attendance_log enable row level security;
alter table public.points_log enable row level security;

create policy attendance_log_select on public.attendance_log for select using (
  public.can_access_enrollment(enrollment_id)
);
create policy attendance_log_insert on public.attendance_log for insert with check (
  public.can_access_enrollment(enrollment_id) and recorded_by = auth.uid()
);
-- removal = deleting the entry (reverted by trigger below)
create policy attendance_log_delete on public.attendance_log for delete using (
  public.can_access_enrollment(enrollment_id)
);

create policy points_log_select on public.points_log for select using (
  public.can_access_enrollment(enrollment_id)
);
create policy points_log_insert on public.points_log for insert with check (
  public.can_access_enrollment(enrollment_id) and recorded_by = auth.uid()
);

-- =====================================================================
-- 6. Integrity: event/cause must belong to the enrollment's class
-- =====================================================================
create or replace function public.check_attendance_event_scope()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.event_id is not null then
    if not exists (
      select 1
      from public.events ev
      join public.enrollments en on en.id = new.enrollment_id
      where ev.id = new.event_id and ev.class_id = en.class_id
    ) then
      raise exception 'event does not belong to the enrollment class';
    end if;
  end if;
  return new;
end $$;
create trigger trg_attendance_event_scope before insert on public.attendance_log
for each row execute function public.check_attendance_event_scope();

create or replace function public.check_points_cause_scope()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.cause_id is not null then
    if not exists (
      select 1
      from public.causes ca
      join public.enrollments en on en.id = new.enrollment_id
      where ca.id = new.cause_id and ca.class_id = en.class_id
    ) then
      raise exception 'cause does not belong to the enrollment class';
    end if;
  end if;
  return new;
end $$;
create trigger trg_points_cause_scope before insert on public.points_log
for each row execute function public.check_points_cause_scope();

-- =====================================================================
-- 7. COUNTER TRIGGERS
--    insert = attend (+1 attendance, +points_delta)
--    delete = remove attendance (-1 attendance, -points_delta)
-- =====================================================================
create or replace function public.on_attendance_log_insert()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.enrollments
     set attendance_count = attendance_count + 1,
         points = points + new.points_delta
   where id = new.enrollment_id;
  return new;
end $$;
create trigger trg_attendance_log_insert after insert on public.attendance_log
for each row execute function public.on_attendance_log_insert();

create or replace function public.on_attendance_log_delete()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.enrollments
     set attendance_count = greatest(attendance_count - 1, 0),
         points = greatest(points - old.points_delta, 0)
   where id = old.enrollment_id;
  return old;
end $$;
create trigger trg_attendance_log_delete after delete on public.attendance_log
for each row execute function public.on_attendance_log_delete();

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
-- 8. REALTIME
-- =====================================================================
alter publication supabase_realtime add table public.events;
alter publication supabase_realtime add table public.causes;
alter publication supabase_realtime add table public.attendance_log;
alter publication supabase_realtime add table public.points_log;
alter table public.events replica identity full;
alter table public.causes replica identity full;
alter table public.attendance_log replica identity full;
alter table public.points_log replica identity full;

commit;
