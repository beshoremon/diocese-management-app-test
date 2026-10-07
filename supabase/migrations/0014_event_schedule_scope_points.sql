-- =====================================================================
-- 0014: EVENT SCHEDULING + FLEXIBLE SCOPE + BOUND POINTS (Cairo time)
--
-- 1. EVENTS
--    - recurrence: 'once' (has event_date) or 'weekly' (weekdays[] —
--      one day = every week, several days = week days).
--    - optional start_time / end_time (Africa/Cairo local time).
--    - points: amount of points bound to attending this event.
--    - scope: service_id / class_id become NULLABLE.
--        service_id null  => ALL services of the church (=> class null too)
--        class_id  null   => ALL classes of the (church, service)
--
-- 2. CAUSES
--    - points: amount of points bound to this cause.
--    - scope: service_id / class_id become NULLABLE (same semantics).
--
-- 3. RLS uses new scope_overlaps (select) / scope_contains (write)
--    helpers so church-wide events/causes stay visible to service and
--    class managers inside that church.
--
-- 4. Attendance uniqueness becomes PER CAIRO DAY so weekly events can
--    be attended once each occurrence day. attendance_log.attended_on
--    (date, Africa/Cairo) is added.
--
-- 5. Scope-check triggers updated: an event/cause applies to an
--    enrollment when the enrollment falls INSIDE the event/cause scope.
-- =====================================================================

begin;

-- =====================================================================
-- 1. EVENTS: schedule + points + nullable scope
-- =====================================================================
alter table public.events
  alter column service_id drop not null,
  alter column class_id drop not null,
  add column recurrence text not null default 'once'
    check (recurrence in ('once', 'weekly')),
  add column weekdays smallint[] check (
    weekdays is null or (
      array_length(weekdays, 1) >= 1
      and weekdays <@ array[0,1,2,3,4,5,6]::smallint[]
    )
  ),
  add column start_time time,
  add column end_time time,
  add column points integer not null default 1 check (points >= 0);

comment on column public.events.weekdays is
  '0=Sunday .. 6=Saturday (Africa/Cairo). Used when recurrence = weekly.';
comment on column public.events.start_time is 'Africa/Cairo local time';
comment on column public.events.end_time is 'Africa/Cairo local time';

-- scope chain consistency: if service_id is null, class_id must be null
alter table public.events add constraint events_scope_chain
  check (service_id is not null or class_id is null);

-- =====================================================================
-- 2. CAUSES: points + nullable scope
-- =====================================================================
alter table public.causes
  alter column service_id drop not null,
  alter column class_id drop not null,
  add column points integer not null default 1 check (points >= 0);

alter table public.causes add constraint causes_scope_chain
  check (service_id is not null or class_id is null);

-- =====================================================================
-- 3. Scope helpers + RLS rebuild
--    scope_overlaps: viewer scope and target scope intersect (SELECT).
--    scope_contains: viewer scope fully contains target scope (WRITE).
--    Target: p_service / p_class null = "all" under the parent.
--    Viewer: profile null scope cascades as in 0006 (null = all).
-- =====================================================================
create or replace function public.scope_overlaps(p_church uuid, p_service uuid, p_class uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select case public.my_role()
    when 'owner' then true
    when 'church_manager' then p_church = public.my_church()
    when 'service_manager' then
      p_church = public.my_church()
      and (public.my_service() is null or p_service is null or p_service = public.my_service())
    when 'class_servant' then
      p_church = public.my_church()
      and (public.my_service() is null or p_service is null or p_service = public.my_service())
      and (public.my_class() is null or p_class is null or p_class = public.my_class())
    else false
  end
$$;

create or replace function public.scope_contains(p_church uuid, p_service uuid, p_class uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select case public.my_role()
    when 'owner' then true
    when 'church_manager' then p_church = public.my_church()
    when 'service_manager' then
      p_church = public.my_church()
      and (
        public.my_service() is null
        or (p_service is not null and p_service = public.my_service())
      )
    when 'class_servant' then
      p_church = public.my_church()
      and (
        public.my_service() is null
        or (p_service is not null and p_service = public.my_service())
      )
      and (
        public.my_class() is null
        or (p_class is not null and p_class = public.my_class())
      )
    else false
  end
$$;

-- events policies
drop policy if exists events_select on public.events;
drop policy if exists events_insert on public.events;
drop policy if exists events_update on public.events;
drop policy if exists events_delete on public.events;

create policy events_select on public.events for select using (
  public.scope_overlaps(church_id, service_id, class_id)
);
create policy events_insert on public.events for insert with check (
  public.scope_contains(church_id, service_id, class_id)
);
create policy events_update on public.events for update using (
  public.scope_contains(church_id, service_id, class_id)
) with check (
  public.scope_contains(church_id, service_id, class_id)
);
create policy events_delete on public.events for delete using (
  public.scope_contains(church_id, service_id, class_id)
);

-- causes policies
drop policy if exists causes_select on public.causes;
drop policy if exists causes_insert on public.causes;
drop policy if exists causes_update on public.causes;
drop policy if exists causes_delete on public.causes;

create policy causes_select on public.causes for select using (
  public.scope_overlaps(church_id, service_id, class_id)
);
create policy causes_insert on public.causes for insert with check (
  public.scope_contains(church_id, service_id, class_id)
);
create policy causes_update on public.causes for update using (
  public.scope_contains(church_id, service_id, class_id)
) with check (
  public.scope_contains(church_id, service_id, class_id)
);
create policy causes_delete on public.causes for delete using (
  public.scope_contains(church_id, service_id, class_id)
);

-- =====================================================================
-- 4. Attendance uniqueness: once per enrollment per event PER CAIRO DAY
--    (weekly events repeat — each occurrence day is a fresh attendance)
-- =====================================================================
alter table public.attendance_log
  add column attended_on date not null
    default ((now() at time zone 'Africa/Cairo')::date);

-- backfill legacy rows with their creation day (Cairo)
update public.attendance_log
   set attended_on = (created_at at time zone 'Africa/Cairo')::date;

drop index if exists public.uq_attendance_enrollment_event;
create unique index uq_attendance_enrollment_event_day
  on public.attendance_log(enrollment_id, event_id, attended_on)
  where event_id is not null;

-- =====================================================================
-- 5. Scope-check triggers: enrollment must fall INSIDE event/cause scope
-- =====================================================================
create or replace function public.check_attendance_event_scope()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.event_id is not null then
    if not exists (
      select 1
      from public.events ev
      join public.enrollments en on en.id = new.enrollment_id
      where ev.id = new.event_id
        and ev.church_id = en.church_id
        and (ev.service_id is null or ev.service_id = en.service_id)
        and (ev.class_id is null or ev.class_id = en.class_id)
    ) then
      raise exception 'event does not apply to the enrollment scope';
    end if;
  end if;
  return new;
end $$;

create or replace function public.check_points_cause_scope()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.cause_id is not null then
    if not exists (
      select 1
      from public.causes ca
      join public.enrollments en on en.id = new.enrollment_id
      where ca.id = new.cause_id
        and ca.church_id = en.church_id
        and (ca.service_id is null or ca.service_id = en.service_id)
        and (ca.class_id is null or ca.class_id = en.class_id)
    ) then
      raise exception 'cause does not apply to the enrollment scope';
    end if;
  end if;
  return new;
end $$;

commit;
