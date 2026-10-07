-- =====================================================================
-- Diocese Management — Multi-tenant schema
-- Hierarchy: church -> service -> class -> child
-- Roles: owner | church_manager | service_manager | class_servant
-- =====================================================================

-- ---------- ENUMS ----------
create type public.app_role as enum ('owner', 'church_manager', 'service_manager', 'class_servant');
create type public.approval_status as enum ('pending', 'approved', 'rejected');

-- ---------- CHURCHES ----------
create table public.churches (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  logo_url text,
  address text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---------- SERVICES (belongs to a church) ----------
create table public.services (
  id uuid primary key default gen_random_uuid(),
  church_id uuid not null references public.churches(id) on delete cascade,
  name text not null,
  description text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index idx_services_church on public.services(church_id);

-- ---------- CLASSES (belongs to a service) ----------
create table public.classes (
  id uuid primary key default gen_random_uuid(),
  church_id uuid not null references public.churches(id) on delete cascade,
  service_id uuid not null references public.services(id) on delete cascade,
  name text not null,
  description text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index idx_classes_service on public.classes(service_id);
create index idx_classes_church on public.classes(church_id);

-- ---------- PROFILES (app users, linked to auth.users) ----------
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  user_id text not null unique,            -- login username chosen at signup
  phone text not null,
  role public.app_role not null default 'class_servant',
  status public.approval_status not null default 'pending',
  church_id uuid references public.churches(id) on delete set null,
  service_id uuid references public.services(id) on delete set null,
  class_id uuid references public.classes(id) on delete set null,
  approved_by uuid references public.profiles(id),
  approved_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index idx_profiles_church on public.profiles(church_id);
create index idx_profiles_status on public.profiles(status);

-- ---------- CHILDREN (المخدومين) ----------
create table public.children (
  id uuid primary key default gen_random_uuid(),
  church_id uuid not null references public.churches(id) on delete cascade,
  service_id uuid not null references public.services(id) on delete cascade,
  class_id uuid not null references public.classes(id) on delete cascade,
  name text not null,
  phone text,
  birthdate date,
  address text,
  notes text,
  attendance_count integer not null default 0,
  points integer not null default 0,
  qr_code text unique default encode(gen_random_bytes(12), 'hex'),
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index idx_children_class on public.children(class_id);
create index idx_children_service on public.children(service_id);
create index idx_children_church on public.children(church_id);

-- ---------- ATTENDANCE LOG (scanner module) ----------
create table public.attendance (
  id uuid primary key default gen_random_uuid(),
  child_id uuid not null references public.children(id) on delete cascade,
  church_id uuid not null references public.churches(id) on delete cascade,
  service_id uuid not null references public.services(id) on delete cascade,
  class_id uuid not null references public.classes(id) on delete cascade,
  attended_on date not null default current_date,
  points_awarded integer not null default 1,
  recorded_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  unique (child_id, attended_on)
);
create index idx_attendance_child on public.attendance(child_id);
create index idx_attendance_date on public.attendance(attended_on);

-- =====================================================================
-- HELPER FUNCTIONS (security definer to avoid RLS recursion)
-- =====================================================================
create or replace function public.my_profile()
returns public.profiles
language sql stable security definer set search_path = public as
$$ select * from public.profiles where id = auth.uid() $$;

create or replace function public.my_role() returns public.app_role
language sql stable security definer set search_path = public as
$$ select role from public.profiles where id = auth.uid() and status = 'approved' $$;

create or replace function public.my_church() returns uuid
language sql stable security definer set search_path = public as
$$ select church_id from public.profiles where id = auth.uid() and status = 'approved' $$;

create or replace function public.my_service() returns uuid
language sql stable security definer set search_path = public as
$$ select service_id from public.profiles where id = auth.uid() and status = 'approved' $$;

create or replace function public.my_class() returns uuid
language sql stable security definer set search_path = public as
$$ select class_id from public.profiles where id = auth.uid() and status = 'approved' $$;

create or replace function public.is_owner() returns boolean
language sql stable security definer set search_path = public as
$$ select coalesce(public.my_role() = 'owner', false) $$;

-- Tenant visibility check: can current user see rows of (church, service, class)?
create or replace function public.can_access(p_church uuid, p_service uuid, p_class uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select case public.my_role()
    when 'owner' then true
    when 'church_manager' then p_church = public.my_church()
    when 'service_manager' then p_service = public.my_service()
    when 'class_servant' then p_class = public.my_class()
    else false
  end
$$;

-- =====================================================================
-- ROW LEVEL SECURITY
-- =====================================================================
alter table public.churches enable row level security;
alter table public.services enable row level security;
alter table public.classes enable row level security;
alter table public.profiles enable row level security;
alter table public.children enable row level security;
alter table public.attendance enable row level security;

-- ---------- CHURCHES ----------
create policy churches_select on public.churches for select using (
  public.is_owner() or id = public.my_church()
);
create policy churches_insert on public.churches for insert with check (public.is_owner());
create policy churches_update on public.churches for update using (
  public.is_owner() or (public.my_role() = 'church_manager' and id = public.my_church())
);
create policy churches_delete on public.churches for delete using (public.is_owner());

-- ---------- SERVICES ----------
create policy services_select on public.services for select using (
  public.is_owner()
  or (church_id = public.my_church() and public.my_role() = 'church_manager')
  or id = public.my_service()
  or (public.my_role() in ('service_manager','class_servant') and id = public.my_service())
);
create policy services_insert on public.services for insert with check (
  public.is_owner() or (public.my_role() = 'church_manager' and church_id = public.my_church())
);
create policy services_update on public.services for update using (
  public.is_owner()
  or (public.my_role() = 'church_manager' and church_id = public.my_church())
  or (public.my_role() = 'service_manager' and id = public.my_service())
);
create policy services_delete on public.services for delete using (
  public.is_owner() or (public.my_role() = 'church_manager' and church_id = public.my_church())
);

-- ---------- CLASSES ----------
create policy classes_select on public.classes for select using (
  public.can_access(church_id, service_id, id)
);
create policy classes_insert on public.classes for insert with check (
  public.is_owner()
  or (public.my_role() = 'church_manager' and church_id = public.my_church())
  or (public.my_role() = 'service_manager' and service_id = public.my_service())
);
create policy classes_update on public.classes for update using (
  public.is_owner()
  or (public.my_role() = 'church_manager' and church_id = public.my_church())
  or (public.my_role() = 'service_manager' and service_id = public.my_service())
);
create policy classes_delete on public.classes for delete using (
  public.is_owner()
  or (public.my_role() = 'church_manager' and church_id = public.my_church())
  or (public.my_role() = 'service_manager' and service_id = public.my_service())
);

-- ---------- PROFILES ----------
-- Everyone sees own profile; managers see profiles within their tenant scope
create policy profiles_select on public.profiles for select using (
  id = auth.uid()
  or public.is_owner()
  or (public.my_role() = 'church_manager' and church_id = public.my_church())
  or (public.my_role() = 'service_manager' and service_id = public.my_service())
);
-- Signup: a new authenticated user may insert their own pending profile
create policy profiles_insert_self on public.profiles for insert with check (
  id = auth.uid() and status = 'pending'
);
-- Own profile basic update (cannot self-approve: status/role protected by trigger below)
create policy profiles_update_self on public.profiles for update using (id = auth.uid());
-- Managers approve/manage within scope
create policy profiles_update_mgmt on public.profiles for update using (
  public.is_owner()
  or (public.my_role() = 'church_manager' and church_id = public.my_church())
  or (public.my_role() = 'service_manager' and service_id = public.my_service())
);
create policy profiles_delete on public.profiles for delete using (
  public.is_owner()
  or (public.my_role() = 'church_manager' and church_id = public.my_church())
);

-- Guard: non-managers cannot change their own role/status/assignments
create or replace function public.guard_profile_update()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_role public.app_role;
begin
  v_role := public.my_role();
  if auth.uid() = new.id and (v_role is null or v_role = 'class_servant') then
    -- self update by non-manager: freeze protected columns
    new.role := old.role;
    new.status := old.status;
    new.church_id := old.church_id;
    new.service_id := old.service_id;
    new.class_id := old.class_id;
    new.approved_by := old.approved_by;
    new.approved_at := old.approved_at;
  end if;
  new.updated_at := now();
  return new;
end $$;
create trigger trg_guard_profile before update on public.profiles
for each row execute function public.guard_profile_update();

-- ---------- CHILDREN ----------
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

-- ---------- ATTENDANCE ----------
create policy attendance_select on public.attendance for select using (
  public.can_access(church_id, service_id, class_id)
);
create policy attendance_insert on public.attendance for insert with check (
  public.can_access(church_id, service_id, class_id)
);
create policy attendance_delete on public.attendance for delete using (
  public.is_owner()
  or (public.my_role() = 'church_manager' and church_id = public.my_church())
  or (public.my_role() = 'service_manager' and service_id = public.my_service())
);

-- Attendance side-effects: bump child's counters
create or replace function public.on_attendance_insert()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.children
     set attendance_count = attendance_count + 1,
         points = points + new.points_awarded,
         updated_at = now()
   where id = new.child_id;
  return new;
end $$;
create trigger trg_attendance_insert after insert on public.attendance
for each row execute function public.on_attendance_insert();

create or replace function public.on_attendance_delete()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.children
     set attendance_count = greatest(attendance_count - 1, 0),
         points = greatest(points - old.points_awarded, 0),
         updated_at = now()
   where id = old.child_id;
  return old;
end $$;
create trigger trg_attendance_delete after delete on public.attendance
for each row execute function public.on_attendance_delete();

-- =====================================================================
-- REALTIME — enable for all app tables
-- =====================================================================
alter publication supabase_realtime add table public.churches;
alter publication supabase_realtime add table public.services;
alter publication supabase_realtime add table public.classes;
alter publication supabase_realtime add table public.profiles;
alter publication supabase_realtime add table public.children;
alter publication supabase_realtime add table public.attendance;

-- Needed so realtime + RLS deliver old record values on update/delete
alter table public.children replica identity full;
alter table public.attendance replica identity full;
alter table public.profiles replica identity full;

-- =====================================================================
-- STORAGE bucket for church logos
-- =====================================================================
insert into storage.buckets (id, name, public) values ('church-logos', 'church-logos', true)
on conflict (id) do nothing;

create policy "logos_public_read" on storage.objects for select using (bucket_id = 'church-logos');
create policy "logos_auth_write" on storage.objects for insert with check (
  bucket_id = 'church-logos' and auth.role() = 'authenticated'
);
create policy "logos_auth_update" on storage.objects for update using (
  bucket_id = 'church-logos' and auth.role() = 'authenticated'
);
