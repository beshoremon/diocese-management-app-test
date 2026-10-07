-- =====================================================================
-- 0008: Attendance log + Points log tables
--       Jobs are now app-code constants → drop children.job (from 0007)
-- =====================================================================

-- Jobs live in the app code now, not the database
alter table public.children drop column if exists job;

-- ---------- ATTENDANCE LOG ----------
-- Every attendance register/remove action from the children page.
create table public.attendance_log (
  id uuid primary key default gen_random_uuid(),
  child_id uuid not null references public.children(id) on delete cascade,
  church_id uuid not null references public.churches(id) on delete cascade,
  service_id uuid not null references public.services(id) on delete cascade,
  class_id uuid not null references public.classes(id) on delete cascade,
  action text not null check (action in ('add', 'remove')),
  points_delta integer not null default 5 check (points_delta >= 0),
  recorded_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);
create index idx_attendance_log_child on public.attendance_log(child_id);
create index idx_attendance_log_created on public.attendance_log(created_at);

-- ---------- POINTS LOG ----------
-- Every manual points add/subtract action from the children page.
create table public.points_log (
  id uuid primary key default gen_random_uuid(),
  child_id uuid not null references public.children(id) on delete cascade,
  church_id uuid not null references public.churches(id) on delete cascade,
  service_id uuid not null references public.services(id) on delete cascade,
  class_id uuid not null references public.classes(id) on delete cascade,
  delta integer not null check (delta <> 0),   -- positive = add, negative = subtract
  recorded_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);
create index idx_points_log_child on public.points_log(child_id);
create index idx_points_log_created on public.points_log(created_at);

-- ---------- RLS ----------
alter table public.attendance_log enable row level security;
alter table public.points_log enable row level security;

create policy attendance_log_select on public.attendance_log for select using (
  public.can_access(church_id, service_id, class_id)
);
create policy attendance_log_insert on public.attendance_log for insert with check (
  public.can_access(church_id, service_id, class_id) and recorded_by = auth.uid()
);

create policy points_log_select on public.points_log for select using (
  public.can_access(church_id, service_id, class_id)
);
create policy points_log_insert on public.points_log for insert with check (
  public.can_access(church_id, service_id, class_id) and recorded_by = auth.uid()
);

-- ---------- SIDE-EFFECT TRIGGERS (update children counters) ----------
create or replace function public.on_attendance_log_insert()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.action = 'add' then
    update public.children
       set attendance_count = attendance_count + 1,
           points = points + new.points_delta,
           updated_at = now()
     where id = new.child_id;
  else -- remove
    update public.children
       set attendance_count = greatest(attendance_count - 1, 0),
           points = greatest(points - new.points_delta, 0),
           updated_at = now()
     where id = new.child_id;
  end if;
  return new;
end $$;
create trigger trg_attendance_log_insert after insert on public.attendance_log
for each row execute function public.on_attendance_log_insert();

create or replace function public.on_points_log_insert()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.children
     set points = greatest(points + new.delta, 0),
         updated_at = now()
   where id = new.child_id;
  return new;
end $$;
create trigger trg_points_log_insert after insert on public.points_log
for each row execute function public.on_points_log_insert();

-- ---------- REALTIME ----------
alter publication supabase_realtime add table public.attendance_log;
alter publication supabase_realtime add table public.points_log;
alter table public.attendance_log replica identity full;
alter table public.points_log replica identity full;
