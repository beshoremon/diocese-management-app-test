-- =====================================================================
-- 0011: PERSON-CENTRIC REBUILD
--
-- New philosophy: the app is built on PERSONS.
--   persons      = identity table: national_id (the QR code), name,
--                  birthdate, gender (male/female), phone (+ photo etc.)
--   enrollments  = a person bound to church + service + class.
--                  One person may have MANY enrollments (many churches /
--                  services / classes). Attendance & points live on the
--                  enrollment.
--
-- Adding a person in any module (e.g. Sunday school):
--   1. person data goes to persons (upsert by national_id)
--   2. an enrollment row registers him in that church/service/class
--
-- Existing children data is PRESERVED:
--   1 child row -> 1 person + 1 enrollment (ids reused, so attendance,
--   attendance_log and points_log simply re-point to enrollment_id).
-- =====================================================================

begin;

-- =====================================================================
-- 1. PERSONS — the identity table
-- =====================================================================
create table public.persons (
  id           uuid primary key default gen_random_uuid(),
  national_id  text not null unique default encode(gen_random_bytes(12), 'hex'),
  name         text not null,
  birthdate    date,
  gender       text check (gender in ('male', 'female')),
  phone        text,
  address      text,
  notes        text,
  image_url    text,
  created_at   timestamptz not null default now(),
  created_by   uuid references public.profiles(id),
  edited_at    timestamptz not null default now(),
  edited_by    uuid references public.profiles(id)
);
create index idx_persons_national_id on public.persons(national_id);
create index idx_persons_name on public.persons(name);

comment on table public.persons is 'الأشخاص — جدول الهوية المركزي: الرقم القومي (QR) والاسم وتاريخ الميلاد والنوع والهاتف';
comment on column public.persons.national_id is 'الرقم القومي — هو نفسه كود الـ QR، فريد لكل شخص';

-- =====================================================================
-- 2. ENROLLMENTS — person bound to church / service / class
-- =====================================================================
create table public.enrollments (
  id               uuid primary key default gen_random_uuid(),
  person_id        uuid not null references public.persons(id) on delete cascade,
  church_id        uuid not null references public.churches(id) on delete cascade,
  service_id       uuid not null references public.services(id) on delete cascade,
  class_id         uuid not null references public.classes(id) on delete cascade,
  attendance_count integer not null default 0,
  points           integer not null default 0,
  created_at       timestamptz not null default now(),
  created_by       uuid references public.profiles(id),
  edited_at        timestamptz not null default now(),
  edited_by        uuid references public.profiles(id),
  unique (person_id, class_id)
);
create index idx_enrollments_person  on public.enrollments(person_id);
create index idx_enrollments_class   on public.enrollments(class_id);
create index idx_enrollments_service on public.enrollments(service_id);
create index idx_enrollments_church  on public.enrollments(church_id);

comment on table public.enrollments is 'تسجيلات الأشخاص — ربط الشخص بالكنيسة والخدمة والفصل، الحضور والنقاط لكل تسجيل';

-- =====================================================================
-- 3. MIGRATE existing children -> persons + enrollments
--    (person id AND enrollment id both reuse the child id so that
--     attendance / logs re-point without any value changes)
-- =====================================================================
insert into public.persons (
  id, national_id, name, birthdate, gender, phone, address, notes,
  image_url, created_at, created_by, edited_at, edited_by
)
select
  id,
  coalesce(qr_code, encode(gen_random_bytes(12), 'hex')),
  name,
  birthdate,
  case gender when 'boy' then 'male' when 'girl' then 'female' else null end,
  phone, address, notes, image_url,
  created_at, created_by, edited_at, edited_by
from public.children;

insert into public.enrollments (
  id, person_id, church_id, service_id, class_id,
  attendance_count, points, created_at, created_by, edited_at, edited_by
)
select
  id, id, church_id, service_id, class_id,
  attendance_count, points, created_at, created_by, edited_at, edited_by
from public.children;

-- =====================================================================
-- 4. RE-POINT attendance / attendance_log / points_log to enrollments
-- =====================================================================
alter table public.attendance drop constraint if exists attendance_child_id_fkey;
alter table public.attendance rename column child_id to enrollment_id;
alter table public.attendance
  add constraint attendance_enrollment_id_fkey
  foreign key (enrollment_id) references public.enrollments(id) on delete cascade;

alter table public.attendance_log drop constraint if exists attendance_log_child_id_fkey;
alter table public.attendance_log rename column child_id to enrollment_id;
alter table public.attendance_log
  add constraint attendance_log_enrollment_id_fkey
  foreign key (enrollment_id) references public.enrollments(id) on delete cascade;

alter table public.points_log drop constraint if exists points_log_child_id_fkey;
alter table public.points_log rename column child_id to enrollment_id;
alter table public.points_log
  add constraint points_log_enrollment_id_fkey
  foreign key (enrollment_id) references public.enrollments(id) on delete cascade;

-- =====================================================================
-- 5. DROP the old children table
-- =====================================================================
alter publication supabase_realtime drop table public.children;
drop table public.children;

-- =====================================================================
-- 6. COUNTER TRIGGERS now update enrollments
-- =====================================================================
create or replace function public.on_attendance_insert()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.enrollments
     set attendance_count = attendance_count + 1,
         points = points + new.points_awarded
   where id = new.enrollment_id;
  return new;
end $$;

create or replace function public.on_attendance_delete()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.enrollments
     set attendance_count = greatest(attendance_count - 1, 0),
         points = greatest(points - old.points_awarded, 0)
   where id = old.enrollment_id;
  return old;
end $$;

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

create or replace function public.on_points_log_insert()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.enrollments
     set points = greatest(points + new.delta, 0)
   where id = new.enrollment_id;
  return new;
end $$;

-- =====================================================================
-- 7. TOUCH triggers (edited_at / edited_by)
-- =====================================================================
create or replace function public.touch_edited()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.edited_at := now();
  if auth.uid() is not null then
    new.edited_by := auth.uid();
  end if;
  return new;
end $$;

create trigger trg_persons_edited before update on public.persons
for each row execute function public.touch_edited();
create trigger trg_enrollments_edited before update on public.enrollments
for each row execute function public.touch_edited();

-- =====================================================================
-- 8. RLS
-- =====================================================================
alter table public.persons enable row level security;
alter table public.enrollments enable row level security;

-- A person is visible when the user can access ANY of his enrollments
-- (or created him, or is the owner)
create or replace function public.can_see_person(p_person uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_owner()
      or exists (
        select 1 from public.enrollments e
         where e.person_id = p_person
           and public.can_access(e.church_id, e.service_id, e.class_id)
      )
$$;

-- ---------- PERSONS ----------
create policy persons_select on public.persons for select using (
  created_by = auth.uid() or public.can_see_person(id)
);
-- Any approved user may create persons (needed when adding in any module)
create policy persons_insert on public.persons for insert with check (
  public.my_role() is not null
);
create policy persons_update on public.persons for update using (
  created_by = auth.uid() or public.can_see_person(id)
);
create policy persons_delete on public.persons for delete using (public.is_owner());

-- ---------- ENROLLMENTS (same tenant rules as old children) ----------
create policy enrollments_select on public.enrollments for select using (
  public.can_access(church_id, service_id, class_id)
);
create policy enrollments_insert on public.enrollments for insert with check (
  public.can_access(church_id, service_id, class_id)
);
create policy enrollments_update on public.enrollments for update using (
  public.can_access(church_id, service_id, class_id)
);
create policy enrollments_delete on public.enrollments for delete using (
  public.is_owner()
  or (public.my_role() = 'church_manager' and church_id = public.my_church())
  or (public.my_role() = 'service_manager' and service_id = public.my_service())
);

-- =====================================================================
-- 9. RPCs — the person-centric flows
-- =====================================================================

-- Cross-scope lookup by national id (QR). Security definer so a servant
-- can recognize a person already registered at ANOTHER church/service,
-- instead of creating a duplicate.
create or replace function public.find_person_by_national_id(p_national_id text)
returns setof public.persons
language sql stable security definer set search_path = public as $$
  select p.* from public.persons p
   where public.my_role() is not null
     and p.national_id = nullif(trim(p_national_id), '')
   limit 1
$$;

-- The core "add person in a module" flow:
--   1. upsert person by national_id (data goes to persons table)
--   2. register him as an enrollment in church + service + class
-- Returns: person_id, enrollment_id, national_id,
--          person_created (new person?), already_enrolled (dup in class?)
create or replace function public.add_person_and_enroll(
  p_church uuid,
  p_service uuid,
  p_class uuid,
  p_name text,
  p_national_id text default null,
  p_gender text default null,
  p_birthdate date default null,
  p_phone text default null,
  p_address text default null,
  p_notes text default null,
  p_image_url text default null,
  p_points integer default 0
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_nid text;
  v_person public.persons%rowtype;
  v_person_created boolean := false;
  v_enrollment_id uuid;
  v_already boolean := false;
begin
  if public.my_role() is null then
    raise exception 'not_approved' using errcode = '42501';
  end if;
  if not public.can_access(p_church, p_service, p_class) then
    raise exception 'no_access' using errcode = '42501';
  end if;
  if coalesce(trim(p_name), '') = '' then
    raise exception 'name_required';
  end if;
  if p_gender is not null and p_gender not in ('male', 'female') then
    raise exception 'invalid_gender';
  end if;

  v_nid := nullif(trim(p_national_id), '');
  if v_nid is null then
    v_nid := encode(gen_random_bytes(12), 'hex');
  end if;

  select * into v_person from public.persons where national_id = v_nid;

  if not found then
    insert into public.persons (
      national_id, name, gender, birthdate, phone, address, notes,
      image_url, created_by, edited_by
    ) values (
      v_nid, trim(p_name), p_gender, p_birthdate,
      nullif(trim(coalesce(p_phone, '')), ''),
      nullif(trim(coalesce(p_address, '')), ''),
      nullif(trim(coalesce(p_notes, '')), ''),
      p_image_url, auth.uid(), auth.uid()
    ) returning * into v_person;
    v_person_created := true;
  else
    -- Person exists: fill in the blanks only (never overwrite existing data)
    update public.persons set
      gender    = coalesce(gender, p_gender),
      birthdate = coalesce(birthdate, p_birthdate),
      phone     = coalesce(phone, nullif(trim(coalesce(p_phone, '')), '')),
      address   = coalesce(address, nullif(trim(coalesce(p_address, '')), '')),
      notes     = coalesce(notes, nullif(trim(coalesce(p_notes, '')), '')),
      image_url = coalesce(image_url, p_image_url),
      edited_by = auth.uid(),
      edited_at = now()
    where id = v_person.id;
  end if;

  -- Register the enrollment (person may already be in this class)
  insert into public.enrollments (person_id, church_id, service_id, class_id, points, created_by, edited_by)
  values (v_person.id, p_church, p_service, p_class, greatest(coalesce(p_points, 0), 0), auth.uid(), auth.uid())
  on conflict (person_id, class_id) do nothing
  returning id into v_enrollment_id;

  if v_enrollment_id is null then
    v_already := true;
    select id into v_enrollment_id from public.enrollments
     where person_id = v_person.id and class_id = p_class;
  end if;

  return jsonb_build_object(
    'person_id', v_person.id,
    'enrollment_id', v_enrollment_id,
    'national_id', v_nid,
    'person_created', v_person_created,
    'already_enrolled', v_already
  );
end $$;

-- =====================================================================
-- 10. REALTIME
-- =====================================================================
alter publication supabase_realtime add table public.persons;
alter publication supabase_realtime add table public.enrollments;
alter table public.persons replica identity full;
alter table public.enrollments replica identity full;

commit;
