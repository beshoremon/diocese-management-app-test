-- =====================================================================
-- 0032: OCCASIONS MODULE — الفعاليات (trips · conferences · celebrations ·
--       activities · special events) — simple v1
--
-- A church / service / class / ministry group CREATES OCCASIONS, children
-- REGISTER («أنا مشارك»), leaders MANAGE the participants, tick a small
-- CHECKLIST per participant, every confirmed participant gets an
-- ELECTRONIC TICKET (unique code rendered as QR) and leaders CHECK IN by
-- scanning it. Deliberately small:
--
--   1. occasions                — scope church → service? → class? (null =
--      all, same semantics as events / causes / achievements) · title ·
--      description · image · kind (trip | conference | celebration |
--      activity | other) · starts_at / ends_at · location (+ map url) ·
--      organizer (+ phone) · registration_deadline · capacity (null =
--      unlimited) · auto_confirm («أنا مشارك» → confirmed directly, else
--      pending) · checkin_points (points given through points_log when
--      the participant is checked in) · status draft | published |
--      cancelled | completed.
--   2. occasion_registrations   — one row per enrollment × occasion:
--      status pending → confirmed → checked_in → cancelled · ticket_code
--      (unique, the QR of the e-ticket) · who / when for each step ·
--      source self | leader · points_log_id of the check-in points.
--   3. occasion_checklist_items — the per-occasion checklist definition
--      (label · required · order) — e.g. الدفع · إذن ولي الأمر · المواصلات.
--   4. occasion_checklist_marks — item ✓ per registration (who / when).
--   5. occasion_notifications   — announcements / reminders written by the
--      leaders (registration_id null = everyone who sees the occasion) and
--      automatic status rows per registration (registered / confirmed /
--      checked in / cancelled) written by the RPCs.
--
-- Status changes go through ONE internal path (occasion_apply_status):
--   • capacity is checked when a registration becomes active again,
--   • check-in awards checkin_points once (points_log → existing trigger
--     updates enrollments.points), leaving checked_in refunds them,
--   • every change writes a status notification for the child.
--
-- Permissions (existing RBAC — role + scope + module grant):
--   view     : module_visible('occasions') + scope_overlaps   (RLS select)
--   create   : module_visible + scope_contains                (RLS insert)
--   edit     : module_visible + scope_contains                (RLS update)
--   delete   : module_visible + scope_contains + role in
--              (owner, church_manager, service_manager)       (RLS delete)
--   manage   : add / status / check-in / checklist marks for participants
--              whose enrollment the caller can see (enrollment_visible)
--              on an occasion he can see — so a class servant handles his
--              own children on a service-wide trip                (RPCs)
--   announce : scope_contains on the occasion scope           (RLS insert)
--   Children (anon, token = national id — pattern of 0021): see published
--   occasions covering one of their enrollments where the module is
--   granted, register / cancel their OWN registration, read their ticket,
--   checklist and notifications. Nothing else.
--
-- Idempotent — safe to re-run. Depends on 0019 (my_scope / scope_* /
-- enrollment_visible), 0021 (child portal), 0024 (module_visible), 0027
-- (module_granted_for), 0031 (shape of child_portal_points). NO module
-- grant is seeded — the owner enables it per scope in وحدة المالك →
-- صلاحيات الوحدات.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. TABLE: occasions
-- ---------------------------------------------------------------------
create table if not exists public.occasions (
  id                     uuid primary key default gen_random_uuid(),
  church_id              uuid not null references public.churches(id) on delete cascade,
  service_id             uuid references public.services(id) on delete cascade,   -- null = all services
  class_id               uuid references public.classes(id)  on delete cascade,   -- null = all classes
  title                  text not null,
  description            text,
  image_url              text,
  kind                   text not null default 'activity'
                         check (kind in ('trip', 'conference', 'celebration', 'activity', 'other')),
  starts_at              timestamptz not null,
  ends_at                timestamptz,
  location               text,
  location_url           text,
  organizer              text,
  organizer_phone        text,
  registration_deadline  timestamptz,
  capacity               integer check (capacity is null or capacity >= 1),        -- null = unlimited
  auto_confirm           boolean not null default false,
  checkin_points         integer not null default 0 check (checkin_points >= 0),
  status                 text not null default 'published'
                         check (status in ('draft', 'published', 'cancelled', 'completed')),
  created_at             timestamptz not null default now(),
  created_by             uuid references public.profiles(id),
  edited_at              timestamptz not null default now(),
  edited_by              uuid references public.profiles(id),
  constraint occasions_title_not_blank check (length(trim(title)) > 0),
  constraint occasions_scope_chain     check (not (class_id is not null and service_id is null)),
  constraint occasions_ends_after      check (ends_at is null or ends_at >= starts_at)
);

comment on table public.occasions is
  'الفعاليات — رحلة / مؤتمر / احتفال / نشاط: عنوان، صورة، موعد، مكان، منظّم، آخر موعد للتسجيل، سعة، نقاط تسجيل الدخول';

create index if not exists idx_occasions_church   on public.occasions(church_id);
create index if not exists idx_occasions_service  on public.occasions(service_id);
create index if not exists idx_occasions_class    on public.occasions(class_id);
create index if not exists idx_occasions_starts   on public.occasions(church_id, starts_at desc);
create index if not exists idx_occasions_status   on public.occasions(status, starts_at);

drop trigger if exists trg_occasions_touch on public.occasions;
create trigger trg_occasions_touch before update on public.occasions
for each row execute function public.touch_edited();

create or replace function public.check_occasion_scope()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.title := trim(new.title);
  if new.service_id is not null and not exists (
    select 1 from public.services s where s.id = new.service_id and s.church_id = new.church_id
  ) then
    raise exception 'service does not belong to the church';
  end if;
  if new.class_id is not null and not exists (
    select 1 from public.classes c
     where c.id = new.class_id and c.service_id = new.service_id and c.church_id = new.church_id
  ) then
    raise exception 'class does not belong to the service';
  end if;
  return new;
end $$;

drop trigger if exists trg_occasion_scope on public.occasions;
create trigger trg_occasion_scope before insert or update on public.occasions
for each row execute function public.check_occasion_scope();

-- ---------------------------------------------------------------------
-- 2. TABLE: occasion_registrations (المشاركون)
-- ---------------------------------------------------------------------
create table if not exists public.occasion_registrations (
  id              uuid primary key default gen_random_uuid(),
  occasion_id     uuid not null references public.occasions(id)   on delete cascade,
  enrollment_id   uuid not null references public.enrollments(id) on delete cascade,
  person_id       uuid not null references public.persons(id)     on delete cascade,
  -- denormalized scope (from the enrollment) for cheap RLS + realtime filters
  church_id       uuid not null references public.churches(id) on delete cascade,
  service_id      uuid not null references public.services(id) on delete cascade,
  class_id        uuid not null references public.classes(id)  on delete cascade,
  status          text not null default 'pending'
                  check (status in ('pending', 'confirmed', 'checked_in', 'cancelled')),
  ticket_code     text not null unique,
  source          text not null default 'self' check (source in ('self', 'leader')),
  registered_at   timestamptz not null default now(),
  registered_by   uuid references public.profiles(id),          -- null = the child himself
  confirmed_at    timestamptz,
  checked_in_at   timestamptz,
  checked_in_by   uuid references public.profiles(id),
  cancelled_at    timestamptz,
  note            text,
  points_log_id   uuid references public.points_log(id) on delete set null,   -- the check-in points row
  updated_at      timestamptz not null default now(),
  constraint uq_occasion_registration unique (occasion_id, enrollment_id)
);

comment on table public.occasion_registrations is
  'مشاركو الفعاليات — تسجيل مخدوم في فعالية: الحالة (قيد المراجعة → مؤكد → سجّل الدخول → ملغي) · كود التذكرة (QR)';

create index if not exists idx_occ_reg_occasion   on public.occasion_registrations(occasion_id, status);
create index if not exists idx_occ_reg_enrollment on public.occasion_registrations(enrollment_id);
create index if not exists idx_occ_reg_person     on public.occasion_registrations(person_id, registered_at desc);
create index if not exists idx_occ_reg_church     on public.occasion_registrations(church_id);
create index if not exists idx_occ_reg_service    on public.occasion_registrations(service_id);
create index if not exists idx_occ_reg_class      on public.occasion_registrations(class_id);
create index if not exists idx_occ_reg_points_log on public.occasion_registrations(points_log_id);

-- «T-» + 10 hex chars — unique, unguessable enough for a ticket.
-- Built on gen_random_uuid() (core PostgreSQL) — NOT pgcrypto: on Supabase
-- pgcrypto lives in the `extensions` schema and is invisible from a
-- function pinned to search_path = public.
create or replace function public.occasion_new_ticket_code()
returns text language plpgsql volatile security definer set search_path = public as $$
declare v text; i integer := 0;
begin
  loop
    v := 'T-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));
    exit when not exists (select 1 from public.occasion_registrations r where r.ticket_code = v);
    i := i + 1;
    if i > 20 then raise exception 'ticket_code_collision'; end if;
  end loop;
  return v;
end $$;
revoke all on function public.occasion_new_ticket_code() from public, anon, authenticated;

-- fill person + scope from the enrollment, ticket code when missing
create or replace function public.occasion_registration_fill()
returns trigger language plpgsql security definer set search_path = public as $$
declare e public.enrollments; o public.occasions;
begin
  select * into e from public.enrollments where id = new.enrollment_id;
  if not found then raise exception 'enrollment_not_found' using errcode = 'P0002'; end if;
  select * into o from public.occasions where id = new.occasion_id;
  if not found then raise exception 'occasion_not_found' using errcode = 'P0002'; end if;
  if not (o.church_id = e.church_id
          and (o.service_id is null or o.service_id = e.service_id)
          and (o.class_id   is null or o.class_id   = e.class_id)) then
    raise exception 'out_of_scope' using errcode = 'P0001';
  end if;
  new.person_id  := e.person_id;
  new.church_id  := e.church_id;
  new.service_id := e.service_id;
  new.class_id   := e.class_id;
  if new.ticket_code is null or length(trim(new.ticket_code)) = 0 then
    new.ticket_code := public.occasion_new_ticket_code();
  end if;
  return new;
end $$;

drop trigger if exists trg_occ_reg_fill on public.occasion_registrations;
create trigger trg_occ_reg_fill before insert on public.occasion_registrations
for each row execute function public.occasion_registration_fill();

create or replace function public.occasion_registration_touch()
returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;
drop trigger if exists trg_occ_reg_touch on public.occasion_registrations;
create trigger trg_occ_reg_touch before update on public.occasion_registrations
for each row execute function public.occasion_registration_touch();

-- deleting a checked-in participant refunds the check-in points
create or replace function public.occasion_registration_before_delete()
returns trigger language plpgsql security definer set search_path = public as $$
declare pts integer;
begin
  if old.points_log_id is not null then
    select delta into pts from public.points_log where id = old.points_log_id;
    if pts is not null and pts > 0 then
      insert into public.points_log (enrollment_id, cause_id, event_id, delta, recorded_by)
      values (old.enrollment_id, null, null, -pts, auth.uid());
    end if;
  end if;
  return old;
end $$;
drop trigger if exists trg_occ_reg_before_delete on public.occasion_registrations;
create trigger trg_occ_reg_before_delete before delete on public.occasion_registrations
for each row execute function public.occasion_registration_before_delete();

-- ---------------------------------------------------------------------
-- 3. TABLES: checklist items + marks
-- ---------------------------------------------------------------------
create table if not exists public.occasion_checklist_items (
  id           uuid primary key default gen_random_uuid(),
  occasion_id  uuid not null references public.occasions(id) on delete cascade,
  label        text not null,
  required     boolean not null default true,
  sort_order   integer not null default 0,
  created_at   timestamptz not null default now(),
  created_by   uuid references public.profiles(id),
  constraint occ_item_label_not_blank check (length(trim(label)) > 0)
);
comment on table public.occasion_checklist_items is 'قائمة التحقق لكل فعالية — الدفع · إذن ولي الأمر · المواصلات · الأغراض المطلوبة …';
create index if not exists idx_occ_items_occasion on public.occasion_checklist_items(occasion_id, sort_order);

create table if not exists public.occasion_checklist_marks (
  registration_id uuid not null references public.occasion_registrations(id)   on delete cascade,
  item_id         uuid not null references public.occasion_checklist_items(id) on delete cascade,
  marked_at       timestamptz not null default now(),
  marked_by       uuid references public.profiles(id),
  primary key (registration_id, item_id)
);
comment on table public.occasion_checklist_marks is 'علامة ✓ على عنصر من قائمة التحقق لمشارك';
create index if not exists idx_occ_marks_item on public.occasion_checklist_marks(item_id);

-- ---------------------------------------------------------------------
-- 4. TABLE: occasion_notifications (إعلانات · تذكيرات · حالة التسجيل)
-- ---------------------------------------------------------------------
create table if not exists public.occasion_notifications (
  id              uuid primary key default gen_random_uuid(),
  occasion_id     uuid not null references public.occasions(id) on delete cascade,
  registration_id uuid references public.occasion_registrations(id) on delete cascade,   -- null = everyone
  kind            text not null default 'announcement' check (kind in ('announcement', 'reminder', 'status')),
  body            text not null,
  created_at      timestamptz not null default now(),
  created_by      uuid references public.profiles(id),     -- null = automatic
  constraint occ_notif_body_not_blank check (length(trim(body)) > 0)
);
comment on table public.occasion_notifications is 'إشعارات الفعالية — إعلان / تذكير للجميع، أو تغيير حالة لمشارك واحد';
create index if not exists idx_occ_notif_occasion     on public.occasion_notifications(occasion_id, created_at desc);
create index if not exists idx_occ_notif_registration on public.occasion_notifications(registration_id, created_at desc);

-- ---------------------------------------------------------------------
-- 5. RLS — everything requires module_visible('occasions')
-- ---------------------------------------------------------------------
alter table public.occasions                enable row level security;
alter table public.occasion_registrations   enable row level security;
alter table public.occasion_checklist_items enable row level security;
alter table public.occasion_checklist_marks enable row level security;
alter table public.occasion_notifications   enable row level security;

drop policy if exists occasions_select on public.occasions;
create policy occasions_select on public.occasions for select using (
  (select public.module_visible('occasions'))
  and (select public.scope_overlaps(church_id, service_id, class_id))
);
drop policy if exists occasions_insert on public.occasions;
create policy occasions_insert on public.occasions for insert with check (
  (select public.module_visible('occasions'))
  and (select public.scope_contains(church_id, service_id, class_id))
);
drop policy if exists occasions_update on public.occasions;
create policy occasions_update on public.occasions for update using (
  (select public.module_visible('occasions'))
  and (select public.scope_contains(church_id, service_id, class_id))
) with check (
  (select public.module_visible('occasions'))
  and (select public.scope_contains(church_id, service_id, class_id))
);
drop policy if exists occasions_delete on public.occasions;
create policy occasions_delete on public.occasions for delete using (
  (select public.module_visible('occasions'))
  and (select public.scope_contains(church_id, service_id, class_id))
  and (select role from public.my_scope()) in ('owner', 'church_manager', 'service_manager')
);

-- registrations: read / delete rows of enrollments I can see; insert /
-- update ONLY through the RPCs (ticket code, capacity, notifications).
drop policy if exists occ_reg_select on public.occasion_registrations;
create policy occ_reg_select on public.occasion_registrations for select using (
  (select public.module_visible('occasions'))
  and public.enrollment_visible(church_id, service_id, class_id,
    (select role from public.my_scope()), (select church_id from public.my_scope()),
    (select service_id from public.my_scope()), (select class_id from public.my_scope()))
);
drop policy if exists occ_reg_delete on public.occasion_registrations;
create policy occ_reg_delete on public.occasion_registrations for delete using (
  (select public.module_visible('occasions'))
  and public.enrollment_visible(church_id, service_id, class_id,
    (select role from public.my_scope()), (select church_id from public.my_scope()),
    (select service_id from public.my_scope()), (select class_id from public.my_scope()))
);

-- checklist items: see with the occasion; write = occasion editors
drop policy if exists occ_items_select on public.occasion_checklist_items;
create policy occ_items_select on public.occasion_checklist_items for select using (
  (select public.module_visible('occasions'))
  and exists (select 1 from public.occasions o where o.id = occasion_id
                and public.scope_overlaps(o.church_id, o.service_id, o.class_id))
);
drop policy if exists occ_items_write on public.occasion_checklist_items;
create policy occ_items_write on public.occasion_checklist_items for all using (
  (select public.module_visible('occasions'))
  and exists (select 1 from public.occasions o where o.id = occasion_id
                and public.scope_contains(o.church_id, o.service_id, o.class_id))
) with check (
  (select public.module_visible('occasions'))
  and exists (select 1 from public.occasions o where o.id = occasion_id
                and public.scope_contains(o.church_id, o.service_id, o.class_id))
);

-- marks: read with the registration; write through the RPC
drop policy if exists occ_marks_select on public.occasion_checklist_marks;
create policy occ_marks_select on public.occasion_checklist_marks for select using (
  (select public.module_visible('occasions'))
  and exists (select 1 from public.occasion_registrations r where r.id = registration_id
                and public.enrollment_visible(r.church_id, r.service_id, r.class_id,
                  (select role from public.my_scope()), (select church_id from public.my_scope()),
                  (select service_id from public.my_scope()), (select class_id from public.my_scope())))
);

-- notifications: read with the occasion (per-child rows only for visible
-- enrollments); leaders insert announcements / reminders for the whole
-- occasion (scope_contains); status rows are written by the RPCs.
drop policy if exists occ_notif_select on public.occasion_notifications;
create policy occ_notif_select on public.occasion_notifications for select using (
  (select public.module_visible('occasions'))
  and exists (select 1 from public.occasions o where o.id = occasion_id
                and public.scope_overlaps(o.church_id, o.service_id, o.class_id))
  and (registration_id is null or exists (
        select 1 from public.occasion_registrations r where r.id = registration_id
          and public.enrollment_visible(r.church_id, r.service_id, r.class_id,
            (select role from public.my_scope()), (select church_id from public.my_scope()),
            (select service_id from public.my_scope()), (select class_id from public.my_scope()))))
);
drop policy if exists occ_notif_insert on public.occasion_notifications;
create policy occ_notif_insert on public.occasion_notifications for insert with check (
  (select public.module_visible('occasions'))
  and registration_id is null
  and kind in ('announcement', 'reminder')
  and created_by = auth.uid()
  and exists (select 1 from public.occasions o where o.id = occasion_id
                and public.scope_contains(o.church_id, o.service_id, o.class_id))
);
drop policy if exists occ_notif_delete on public.occasion_notifications;
create policy occ_notif_delete on public.occasion_notifications for delete using (
  (select public.module_visible('occasions'))
  and registration_id is null
  and exists (select 1 from public.occasions o where o.id = occasion_id
                and public.scope_contains(o.church_id, o.service_id, o.class_id))
);

-- ---------------------------------------------------------------------
-- 6. PERMISSIONS — flags for the caller
-- ---------------------------------------------------------------------
create or replace function public.occasion_permissions()
returns jsonb language sql stable security definer set search_path = public as $$
  select case
    when (select count(*) from public.my_scope()) = 0 or not public.module_visible('occasions') then
      jsonb_build_object('view', false, 'create', false, 'edit', false, 'delete', false, 'manage', false)
    else
      jsonb_build_object(
        'view',   true,
        'create', true,
        'edit',   true,
        'delete', (select role from public.my_scope()) in ('owner', 'church_manager', 'service_manager'),
        'manage', true)
  end
$$;
grant execute on function public.occasion_permissions() to authenticated;

-- ---------------------------------------------------------------------
-- 7. HELPERS — active count, Arabic status texts
-- ---------------------------------------------------------------------
create or replace function public.occasion_active_count(p_occasion uuid)
returns integer language sql stable security definer set search_path = public as $$
  select count(*)::integer from public.occasion_registrations r
   where r.occasion_id = p_occasion and r.status in ('pending', 'confirmed', 'checked_in')
$$;
revoke all on function public.occasion_active_count(uuid) from public, anon, authenticated;

create or replace function public.occasion_status_text(p_status text, p_title text, p_by_leader boolean)
returns text language sql immutable as $$
  select case p_status
    when 'pending'    then case when p_by_leader then 'سجّلك خادمك في «' || p_title || '» — طلبك قيد المراجعة'
                                                 else 'تم استلام طلب مشاركتك في «' || p_title || '» — بانتظار تأكيد الخادم' end
    when 'confirmed'  then 'تم تأكيد مشاركتك في «' || p_title || '» 🎟️ تذكرتك الإلكترونية جاهزة'
    when 'checked_in' then 'تم تسجيل دخولك إلى «' || p_title || '» ✅ أهلاً بك!'
    when 'cancelled'  then case when p_by_leader then 'تم إلغاء مشاركتك في «' || p_title || '»'
                                                 else 'ألغيت مشاركتك في «' || p_title || '»' end
    else p_status end
$$;

-- ---------------------------------------------------------------------
-- 8. APPLY STATUS — the single write path for status changes (internal)
--    • capacity re-checked when a cancelled registration becomes active
--    • check-in awards checkin_points once; leaving checked_in refunds
--    • writes a status notification for the child
-- ---------------------------------------------------------------------
create or replace function public.occasion_apply_status(
  p_registration uuid, p_status text, p_by uuid, p_note text, p_by_leader boolean)
returns public.occasion_registrations language plpgsql volatile security definer set search_path = public as $$
declare
  r   public.occasion_registrations;
  o   public.occasions;
  pts integer;
  pl  uuid;
begin
  if p_status not in ('pending', 'confirmed', 'checked_in', 'cancelled') then
    raise exception 'invalid_status' using errcode = 'P0001';
  end if;
  select * into r from public.occasion_registrations where id = p_registration for update;
  if not found then raise exception 'registration_not_found' using errcode = 'P0002'; end if;
  select * into o from public.occasions where id = r.occasion_id for update;

  if r.status = p_status then return r; end if;

  -- becoming active again → capacity
  if r.status = 'cancelled' and o.capacity is not null
     and public.occasion_active_count(o.id) >= o.capacity then
    raise exception 'occasion_full' using errcode = 'P0001';
  end if;

  -- leaving checked_in → refund the points
  if r.status = 'checked_in' and r.points_log_id is not null then
    select delta into pts from public.points_log where id = r.points_log_id;
    if pts is not null and pts > 0 then
      insert into public.points_log (enrollment_id, cause_id, event_id, delta, recorded_by)
      values (r.enrollment_id, null, null, -pts, p_by);
    end if;
    r.points_log_id := null;
  end if;

  case p_status
    when 'pending' then
      r.confirmed_at := null; r.cancelled_at := null; r.checked_in_at := null; r.checked_in_by := null;
    when 'confirmed' then
      r.confirmed_at := coalesce(r.confirmed_at, now()); r.cancelled_at := null;
      r.checked_in_at := null; r.checked_in_by := null;
    when 'checked_in' then
      r.confirmed_at := coalesce(r.confirmed_at, now()); r.cancelled_at := null;
      r.checked_in_at := now(); r.checked_in_by := p_by;
      if o.checkin_points > 0 then
        insert into public.points_log (enrollment_id, cause_id, event_id, delta, recorded_by)
        values (r.enrollment_id, null, null, o.checkin_points, p_by)
        returning id into pl;
        r.points_log_id := pl;
      end if;
    when 'cancelled' then
      r.cancelled_at := now(); r.checked_in_at := null; r.checked_in_by := null;
  end case;

  update public.occasion_registrations
     set status = p_status, confirmed_at = r.confirmed_at, cancelled_at = r.cancelled_at,
         checked_in_at = r.checked_in_at, checked_in_by = r.checked_in_by,
         points_log_id = r.points_log_id,
         note = coalesce(nullif(trim(coalesce(p_note, '')), ''), note)
   where id = r.id
   returning * into r;

  insert into public.occasion_notifications (occasion_id, registration_id, kind, body, created_by)
  values (o.id, r.id, 'status', public.occasion_status_text(p_status, o.title, p_by_leader), p_by);

  return r;
end $$;
revoke all on function public.occasion_apply_status(uuid, text, uuid, text, boolean) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 9. INTERNAL CREATE — register an enrollment (used by leader + child RPCs)
--    Reactivates a cancelled row; raises already_registered / occasion_full
-- ---------------------------------------------------------------------
create or replace function public.occasion_create_registration(
  p_occasion uuid, p_enrollment uuid, p_status text, p_by uuid, p_source text, p_by_leader boolean)
returns public.occasion_registrations language plpgsql volatile security definer set search_path = public as $$
declare
  o public.occasions;
  r public.occasion_registrations;
begin
  select * into o from public.occasions where id = p_occasion for update;
  if not found then raise exception 'occasion_not_found' using errcode = 'P0002'; end if;

  select * into r from public.occasion_registrations
   where occasion_id = p_occasion and enrollment_id = p_enrollment for update;
  if found then
    if r.status <> 'cancelled' then raise exception 'already_registered' using errcode = 'P0001'; end if;
    return public.occasion_apply_status(r.id, p_status, p_by, null, p_by_leader);
  end if;

  if o.capacity is not null and public.occasion_active_count(o.id) >= o.capacity then
    raise exception 'occasion_full' using errcode = 'P0001';
  end if;

  insert into public.occasion_registrations (occasion_id, enrollment_id, person_id, church_id, service_id, class_id,
                                             status, source, registered_by, confirmed_at)
  values (p_occasion, p_enrollment,
          '00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000000',
          '00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000000',   -- filled by trigger
          p_status, p_source, p_by, case when p_status = 'confirmed' then now() end)
  returning * into r;

  insert into public.occasion_notifications (occasion_id, registration_id, kind, body, created_by)
  values (o.id, r.id, 'status', public.occasion_status_text(p_status, o.title, p_by_leader), p_by);
  return r;
end $$;
revoke all on function public.occasion_create_registration(uuid, uuid, text, uuid, text, boolean) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 10. LEADER RPCs
-- ---------------------------------------------------------------------
-- caller can manage this enrollment on this occasion?
create or replace function public.occasion_can_manage(p_occasion uuid, p_enrollment uuid)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare s record; o public.occasions; e public.enrollments;
begin
  if auth.uid() is null or not public.module_visible('occasions') then return false; end if;
  select * into s from public.my_scope();
  if not found then return false; end if;
  select * into o from public.occasions where id = p_occasion;
  if not found or not public.scope_overlaps(o.church_id, o.service_id, o.class_id) then return false; end if;
  if p_enrollment is null then return true; end if;
  select * into e from public.enrollments where id = p_enrollment;
  if not found then return false; end if;
  return public.enrollment_visible(e.church_id, e.service_id, e.class_id, s.role, s.church_id, s.service_id, s.class_id);
end $$;
revoke all on function public.occasion_can_manage(uuid, uuid) from public, anon, authenticated;

-- add a participant (leaders bypass the deadline, never the capacity)
create or replace function public.occasion_register(
  p_occasion uuid, p_enrollment uuid, p_status text default 'confirmed')
returns public.occasion_registrations language plpgsql volatile security definer set search_path = public as $$
begin
  if p_status not in ('pending', 'confirmed') then raise exception 'invalid_status' using errcode = 'P0001'; end if;
  if not public.occasion_can_manage(p_occasion, p_enrollment) then
    raise exception 'forbidden' using errcode = 'P0001';
  end if;
  return public.occasion_create_registration(p_occasion, p_enrollment, p_status, auth.uid(), 'leader', true);
end $$;
grant execute on function public.occasion_register(uuid, uuid, text) to authenticated;

-- change a participant's status (pending / confirmed / checked_in / cancelled)
create or replace function public.occasion_set_status(p_registration uuid, p_status text, p_note text default null)
returns public.occasion_registrations language plpgsql volatile security definer set search_path = public as $$
declare r public.occasion_registrations;
begin
  select * into r from public.occasion_registrations where id = p_registration;
  if not found then raise exception 'registration_not_found' using errcode = 'P0002'; end if;
  if not public.occasion_can_manage(r.occasion_id, r.enrollment_id) then
    raise exception 'forbidden' using errcode = 'P0001';
  end if;
  return public.occasion_apply_status(r.id, p_status, auth.uid(), p_note, true);
end $$;
grant execute on function public.occasion_set_status(uuid, text, text) to authenticated;

-- CHECK-IN by scanning: the ticket code OR the child's card QR (national id)
-- → { result: checked_in | already_checked_in, registration, person_name, ... }
-- raises unknown_code / not_registered / registration_cancelled / forbidden
create or replace function public.occasion_checkin(p_occasion uuid, p_code text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  code text := trim(coalesce(p_code, ''));
  r    public.occasion_registrations;
  p    public.persons;
  o    public.occasions;
  res  text;
  prev text;
begin
  if code = '' then raise exception 'unknown_code' using errcode = 'P0002'; end if;
  if not public.occasion_can_manage(p_occasion, null) then raise exception 'forbidden' using errcode = 'P0001'; end if;
  select * into o from public.occasions where id = p_occasion;

  -- 1) ticket code
  select * into r from public.occasion_registrations
   where occasion_id = p_occasion and upper(ticket_code) = upper(code);
  -- 2) national id (the child's card) → his registration on this occasion
  if not found then
    select * into p from public.persons where national_id = code;
    if not found then raise exception 'unknown_code' using errcode = 'P0002'; end if;
    select * into r from public.occasion_registrations
     where occasion_id = p_occasion and person_id = p.id
     order by (status <> 'cancelled') desc, registered_at desc limit 1;
    if not found then
      raise exception 'not_registered' using errcode = 'P0001';
    end if;
  end if;
  if not public.occasion_can_manage(p_occasion, r.enrollment_id) then
    raise exception 'forbidden' using errcode = 'P0001';
  end if;
  if r.status = 'cancelled' then raise exception 'registration_cancelled' using errcode = 'P0001'; end if;

  prev := r.status;
  if r.status = 'checked_in' then
    res := 'already_checked_in';
  else
    r := public.occasion_apply_status(r.id, 'checked_in', auth.uid(), null, true);
    res := 'checked_in';
  end if;
  select * into p from public.persons where id = r.person_id;

  return jsonb_build_object(
    'result', res, 'previous_status', prev,
    'registration_id', r.id, 'enrollment_id', r.enrollment_id, 'status', r.status,
    'ticket_code', r.ticket_code, 'checked_in_at', r.checked_in_at,
    'person_name', p.name, 'person_image', p.image_url, 'national_id', p.national_id,
    'class_name', (select name from public.classes where id = r.class_id),
    'points', case when res = 'checked_in' then o.checkin_points else 0 end);
end $$;
grant execute on function public.occasion_checkin(uuid, text) to authenticated;

-- checklist ✓ / ✗ for one participant
create or replace function public.occasion_checklist_mark(p_registration uuid, p_item uuid, p_done boolean)
returns void language plpgsql volatile security definer set search_path = public as $$
declare r public.occasion_registrations; it public.occasion_checklist_items;
begin
  select * into r from public.occasion_registrations where id = p_registration;
  if not found then raise exception 'registration_not_found' using errcode = 'P0002'; end if;
  select * into it from public.occasion_checklist_items where id = p_item;
  if not found or it.occasion_id <> r.occasion_id then raise exception 'item_not_found' using errcode = 'P0002'; end if;
  if not public.occasion_can_manage(r.occasion_id, r.enrollment_id) then
    raise exception 'forbidden' using errcode = 'P0001';
  end if;
  if p_done then
    insert into public.occasion_checklist_marks (registration_id, item_id, marked_by)
    values (r.id, it.id, auth.uid())
    on conflict (registration_id, item_id) do update set marked_at = now(), marked_by = auth.uid();
  else
    delete from public.occasion_checklist_marks where registration_id = r.id and item_id = it.id;
  end if;
end $$;
grant execute on function public.occasion_checklist_mark(uuid, uuid, boolean) to authenticated;

-- participants of an occasion (names / pictures resolved server-side; only
-- the enrollments the caller can see) + checklist done count
create or replace function public.occasion_participants(p_occasion uuid)
returns table (
  id uuid, enrollment_id uuid, person_id uuid, person_name text, person_image text,
  national_id text, phone text, class_id uuid, class_name text, service_name text,
  status text, ticket_code text, source text, registered_at timestamptz, registered_by_name text,
  confirmed_at timestamptz, checked_in_at timestamptz, checked_in_by_name text,
  cancelled_at timestamptz, note text, checklist_done integer, checklist_items uuid[]
) language plpgsql stable security definer set search_path = public as $$
declare s record;
begin
  if not public.occasion_can_manage(p_occasion, null) then return; end if;
  select * into s from public.my_scope();
  return query
    select r.id, r.enrollment_id, r.person_id, p.name, p.image_url, p.national_id, p.phone,
           r.class_id, cl.name, sv.name,
           r.status, r.ticket_code, r.source, r.registered_at, rb.full_name,
           r.confirmed_at, r.checked_in_at, cb.full_name, r.cancelled_at, r.note,
           (select count(*)::integer from public.occasion_checklist_marks m where m.registration_id = r.id),
           (select coalesce(array_agg(m.item_id), '{}'::uuid[]) from public.occasion_checklist_marks m where m.registration_id = r.id)
      from public.occasion_registrations r
      join public.persons  p  on p.id  = r.person_id
      join public.classes  cl on cl.id = r.class_id
      join public.services sv on sv.id = r.service_id
      left join public.profiles rb on rb.id = r.registered_by
      left join public.profiles cb on cb.id = r.checked_in_by
     where r.occasion_id = p_occasion
       and public.enrollment_visible(r.church_id, r.service_id, r.class_id, s.role, s.church_id, s.service_id, s.class_id)
     order by (r.status = 'cancelled'), p.name;
end $$;
grant execute on function public.occasion_participants(uuid) to authenticated;

-- dashboard counters for a set of occasions (whole occasion — capacity is
-- global, so a class servant sees the real remaining seats)
create or replace function public.occasion_counts(p_occasions uuid[])
returns table (occasion_id uuid, pending integer, confirmed integer, checked_in integer, cancelled integer, active integer)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null or not public.module_visible('occasions') then return; end if;
  return query
    select o.id,
           count(r.id) filter (where r.status = 'pending')::integer,
           count(r.id) filter (where r.status = 'confirmed')::integer,
           count(r.id) filter (where r.status = 'checked_in')::integer,
           count(r.id) filter (where r.status = 'cancelled')::integer,
           count(r.id) filter (where r.status in ('pending', 'confirmed', 'checked_in'))::integer
      from public.occasions o
      left join public.occasion_registrations r on r.occasion_id = o.id
     where o.id = any(p_occasions)
       and public.scope_overlaps(o.church_id, o.service_id, o.class_id)
     group by o.id;
end $$;
grant execute on function public.occasion_counts(uuid[]) to authenticated;

-- ---------------------------------------------------------------------
-- 11. CHILD PORTAL (anon, token = national id)
-- ---------------------------------------------------------------------
-- one occasion → jsonb (shared by the list and the detail)
create or replace function public.child_occasion_json(o public.occasions, p_person uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  r      public.occasion_registrations;
  v_reg  jsonb := null;
  v_can  boolean;
  v_act  integer := public.occasion_active_count(o.id);
  v_enr  uuid;
  v_ln   record;
  v_tot  integer;
  v_done integer := 0;
begin
  -- the enrollment this occasion applies to (first covering one)
  select e.id into v_enr from public.enrollments e
   where e.person_id = p_person and e.church_id = o.church_id
     and (o.service_id is null or o.service_id = e.service_id)
     and (o.class_id   is null or o.class_id   = e.class_id)
     and public.module_granted_for('occasions', e.church_id, e.service_id, e.class_id)
   order by e.created_at limit 1;

  select * into r from public.occasion_registrations
   where occasion_id = o.id and person_id = p_person
   order by (status <> 'cancelled') desc, registered_at desc limit 1;
  if found then
    select count(*)::integer into v_tot from public.occasion_checklist_items i where i.occasion_id = o.id;
    select count(*)::integer into v_done from public.occasion_checklist_marks m where m.registration_id = r.id;
    v_reg := jsonb_build_object(
      'id', r.id, 'enrollment_id', r.enrollment_id, 'status', r.status, 'ticket_code', r.ticket_code,
      'source', r.source, 'registered_at', r.registered_at, 'confirmed_at', r.confirmed_at,
      'checked_in_at', r.checked_in_at, 'cancelled_at', r.cancelled_at, 'note', r.note,
      'checklist_total', v_tot, 'checklist_done', v_done);
  end if;

  v_can := o.status = 'published'
           and v_enr is not null
           and now() < o.starts_at
           and (o.registration_deadline is null or now() <= o.registration_deadline)
           and (o.capacity is null or v_act < o.capacity)
           and (r.id is null or r.status = 'cancelled');

  select n.body, n.kind, n.created_at into v_ln
    from public.occasion_notifications n
   where n.occasion_id = o.id and (n.registration_id is null or n.registration_id = r.id)
   order by n.created_at desc limit 1;

  return jsonb_build_object(
    'id', o.id, 'title', o.title, 'description', o.description, 'image_url', o.image_url, 'kind', o.kind,
    'starts_at', o.starts_at, 'ends_at', o.ends_at, 'location', o.location, 'location_url', o.location_url,
    'organizer', o.organizer, 'organizer_phone', o.organizer_phone,
    'registration_deadline', o.registration_deadline, 'capacity', o.capacity, 'active_count', v_act,
    'remaining', case when o.capacity is null then null else greatest(o.capacity - v_act, 0) end,
    'auto_confirm', o.auto_confirm, 'checkin_points', o.checkin_points, 'status', o.status,
    'church_name', (select name from public.churches where id = o.church_id),
    'service_name', (select name from public.services where id = o.service_id),
    'class_name', (select name from public.classes where id = o.class_id),
    'enrollment_id', v_enr, 'can_register', v_can,
    'my_registration', v_reg,
    'last_notification', case when v_ln.body is null then null else
      jsonb_build_object('body', v_ln.body, 'kind', v_ln.kind, 'created_at', v_ln.created_at) end,
    'server_now', now());
end $$;
revoke all on function public.child_occasion_json(public.occasions, uuid) from public, anon, authenticated;

-- board: published (+ completed / cancelled where I am registered) occasions
-- covering one of my enrollments with the module granted
create or replace function public.child_portal_occasions(p_national_id text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare p public.persons; out jsonb;
begin
  p := public.child_portal_person(p_national_id);
  select coalesce(jsonb_agg(public.child_occasion_json(o, p.id) order by o.starts_at), '[]'::jsonb) into out
    from public.occasions o
   where o.status <> 'draft'
     and exists (
       select 1 from public.enrollments e
        where e.person_id = p.id and e.church_id = o.church_id
          and (o.service_id is null or o.service_id = e.service_id)
          and (o.class_id   is null or o.class_id   = e.class_id)
          and public.module_granted_for('occasions', e.church_id, e.service_id, e.class_id))
     and (o.status = 'published'
          or exists (select 1 from public.occasion_registrations r where r.occasion_id = o.id and r.person_id = p.id))
     and coalesce(o.ends_at, o.starts_at) > now() - interval '30 days';
  return out;
end $$;
grant execute on function public.child_portal_occasions(text) to anon, authenticated;

-- detail: occasion + checklist (with my marks) + notifications (mine + everyone's)
create or replace function public.child_portal_occasion(p_national_id text, p_occasion uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare p public.persons; o public.occasions; r public.occasion_registrations; v jsonb; items jsonb; notifs jsonb;
begin
  p := public.child_portal_person(p_national_id);
  select * into o from public.occasions where id = p_occasion and status <> 'draft';
  if not found then raise exception 'occasion_not_found' using errcode = 'P0002'; end if;
  if not exists (
       select 1 from public.enrollments e
        where e.person_id = p.id and e.church_id = o.church_id
          and (o.service_id is null or o.service_id = e.service_id)
          and (o.class_id   is null or o.class_id   = e.class_id)
          and public.module_granted_for('occasions', e.church_id, e.service_id, e.class_id)) then
    raise exception 'occasion_not_found' using errcode = 'P0002';
  end if;
  v := public.child_occasion_json(o, p.id);
  select * into r from public.occasion_registrations
   where occasion_id = o.id and person_id = p.id
   order by (status <> 'cancelled') desc, registered_at desc limit 1;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', i.id, 'label', i.label, 'required', i.required,
           'done', m.registration_id is not null, 'marked_at', m.marked_at) order by i.sort_order, i.created_at), '[]'::jsonb)
    into items
    from public.occasion_checklist_items i
    left join public.occasion_checklist_marks m on m.item_id = i.id and m.registration_id = r.id
   where i.occasion_id = o.id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', n.id, 'kind', n.kind, 'body', n.body, 'created_at', n.created_at,
           'mine', n.registration_id is not null, 'by_name', pr.full_name) order by n.created_at desc), '[]'::jsonb)
    into notifs
    from (select * from public.occasion_notifications x
           where x.occasion_id = o.id and (x.registration_id is null or x.registration_id = r.id)
           order by x.created_at desc limit 50) n
    left join public.profiles pr on pr.id = n.created_by;

  return v || jsonb_build_object('checklist', items, 'notifications', notifs);
end $$;
grant execute on function public.child_portal_occasion(text, uuid) to anon, authenticated;

-- «أنا مشارك» — register myself (pending, or confirmed when auto_confirm)
create or replace function public.child_portal_occasion_register(p_national_id text, p_occasion uuid)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare p public.persons; o public.occasions; v_enr uuid; r public.occasion_registrations;
begin
  p := public.child_portal_person(p_national_id);
  select * into o from public.occasions where id = p_occasion;
  if not found or o.status = 'draft' then raise exception 'occasion_not_found' using errcode = 'P0002'; end if;
  select e.id into v_enr from public.enrollments e
   where e.person_id = p.id and e.church_id = o.church_id
     and (o.service_id is null or o.service_id = e.service_id)
     and (o.class_id   is null or o.class_id   = e.class_id)
     and public.module_granted_for('occasions', e.church_id, e.service_id, e.class_id)
   order by e.created_at limit 1;
  if v_enr is null then raise exception 'occasion_not_found' using errcode = 'P0002'; end if;
  if o.status <> 'published' then raise exception 'registration_closed' using errcode = 'P0001'; end if;
  if now() >= o.starts_at then raise exception 'occasion_started' using errcode = 'P0001'; end if;
  if o.registration_deadline is not null and now() > o.registration_deadline then
    raise exception 'deadline_passed' using errcode = 'P0001';
  end if;
  r := public.occasion_create_registration(o.id, v_enr,
         case when o.auto_confirm then 'confirmed' else 'pending' end, null, 'self', false);
  return public.child_occasion_json(o, p.id);
end $$;
grant execute on function public.child_portal_occasion_register(text, uuid) to anon, authenticated;

-- cancel my own registration (only before the occasion starts, not after check-in)
create or replace function public.child_portal_occasion_cancel(p_national_id text, p_occasion uuid)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare p public.persons; o public.occasions; r public.occasion_registrations;
begin
  p := public.child_portal_person(p_national_id);
  select * into o from public.occasions where id = p_occasion;
  if not found then raise exception 'occasion_not_found' using errcode = 'P0002'; end if;
  select * into r from public.occasion_registrations
   where occasion_id = o.id and person_id = p.id and status <> 'cancelled'
   order by registered_at desc limit 1;
  if not found then raise exception 'not_registered' using errcode = 'P0001'; end if;
  if r.status = 'checked_in' then raise exception 'already_checked_in' using errcode = 'P0001'; end if;
  if now() >= o.starts_at then raise exception 'occasion_started' using errcode = 'P0001'; end if;
  perform public.occasion_apply_status(r.id, 'cancelled', null, null, false);
  return public.child_occasion_json(o, p.id);
end $$;
grant execute on function public.child_portal_occasion_cancel(text, uuid) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 12. CHILD PORTAL — points list learns the 'occasion' source (shape of 0031)
-- ---------------------------------------------------------------------
drop function if exists public.child_portal_points(text);
create or replace function public.child_portal_points(p_national_id text)
returns table (
  id uuid, enrollment_id uuid, source text, reason text,
  delta integer, created_at timestamptz, recorded_by_name text,
  class_name text, service_name text, church_name text,
  event_name text, order_id uuid, attempt_id uuid
) language plpgsql stable security definer set search_path = public as $$
declare
  p public.persons;
begin
  p := public.child_portal_person(p_national_id);
  return query
    select x.id, x.enrollment_id, x.source, x.reason, x.delta, x.created_at,
           pr.full_name, cl.name, sv.name, ch.name, x.event_name, x.order_id, x.attempt_id
      from (
        select pl.id, pl.enrollment_id,
               case when so.id is not null or sr.id is not null then 'store'::text
                    when ea.id is not null then 'exam'::text
                    when bg.id is not null then 'birthday'::text
                    when oa.id is not null then 'online'::text
                    when ua.id is not null then 'achievement'::text
                    when orr.id is not null then 'occasion'::text
                    else 'cause'::text end as source,
               case when so.id is not null then 'إستبدال نقاط — ' || so.items_count || ' صنف'
                    when sr.id is not null then 'إلغاء عملية إستبدال — استرداد النقاط'
                    when ea.id is not null then 'امتحان — ' || coalesce(ex.title, '')
                    when bg.id is not null then 'هدية عيد ميلاد 🎂 ' || bg.year
                    when oa.id is not null then 'إجابة صحيحة في فصل أونلاين «' || coalesce(oc.title, '') || '»'
                    when ua.id is not null then 'إنجاز 🏆 ' || coalesce(ac.name, '')
                    when orr.id is not null then 'حضور فعالية 🎟️ ' || coalesce(occ.title, '')
                    else ca.name end as reason,
               pl.delta, pl.created_at, pl.recorded_by,
               ev.name as event_name,
               coalesce(so.id, sr.id) as order_id,
               ea.id as attempt_id
          from public.points_log pl
          join public.enrollments e on e.id = pl.enrollment_id
          left join public.causes ca on ca.id = pl.cause_id
          left join public.events ev on ev.id = pl.event_id
          left join public.store_orders so on so.points_log_id = pl.id
          left join public.store_orders sr on sr.refund_points_log_id = pl.id
          left join public.exam_attempts ea on ea.points_log_id = pl.id
          left join public.exams ex on ex.id = ea.exam_id
          left join public.birthday_greetings bg on bg.points_log_id = pl.id
          left join public.online_class_answers oa on oa.points_log_id = pl.id
          left join public.online_classes oc on oc.id = oa.class_id
          left join public.user_achievements ua on ua.points_log_id = pl.id
          left join public.achievements ac on ac.id = ua.achievement_id
          left join public.occasion_registrations orr on orr.points_log_id = pl.id
          left join public.occasions occ on occ.id = orr.occasion_id
         where e.person_id = p.id
        union all
        select a.id, a.enrollment_id, 'attendance'::text,
               coalesce(ev.name, case when op.id is not null then 'حضور فصل أونلاين «' || oc2.title || '»' end),
               a.points_delta, a.created_at, a.recorded_by,
               ev.name, null::uuid, null::uuid
          from public.attendance_log a
          join public.enrollments e on e.id = a.enrollment_id
          left join public.events ev on ev.id = a.event_id
          left join public.online_class_participants op on op.attendance_log_id = a.id
          left join public.online_classes oc2 on oc2.id = op.class_id
         where e.person_id = p.id and a.points_delta <> 0
      ) x
      join public.enrollments e2 on e2.id = x.enrollment_id
      left join public.profiles pr on pr.id = x.recorded_by
      join public.classes  cl on cl.id = e2.class_id
      join public.services sv on sv.id = e2.service_id
      join public.churches ch on ch.id = e2.church_id
     order by x.created_at desc;
end $$;
grant execute on function public.child_portal_points(text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 13. REALTIME
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['occasions', 'occasion_registrations', 'occasion_checklist_items',
                           'occasion_checklist_marks', 'occasion_notifications'] loop
    if not exists (select 1 from pg_publication_tables
                    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;
alter table public.occasions                replica identity full;
alter table public.occasion_registrations   replica identity full;
alter table public.occasion_checklist_items replica identity full;
alter table public.occasion_checklist_marks replica identity full;
alter table public.occasion_notifications   replica identity full;

commit;
