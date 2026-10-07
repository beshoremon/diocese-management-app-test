-- =====================================================================
-- 0019: PERFORMANCE & STABILITY
--
-- Goal: make the app usable for a whole diocese (tens of thousands of
-- persons, hundreds of servants online at once) on the cheapest
-- Supabase tier, by removing the three things that made cost grow
-- quadratically with data size:
--
--   1. RLS helper calls are wrapped in `(select ...)` so Postgres
--      evaluates them ONCE PER QUERY (InitPlan) instead of ONCE PER ROW.
--      This is Supabase's documented RLS performance recommendation and is
--      typically a 10–100x speedup on the persons / enrollments queries.
--
--   2. Scope helpers (my_role / my_church / my_service / my_class) are
--      collapsed into ONE profile lookup (`my_scope()`), and the
--      per-row `can_access(...)` is rewritten as a pure expression over
--      that single cached row — no nested function calls per row.
--
--   3. Missing indexes for the exact filters the app uses
--      (attendance_log(event_id, attended_on), persons(phone),
--       enrollments(class_id, person_id), events/causes by church…).
--
--   4. Aggregation RPCs so the stats / home pages fetch NUMBERS, not
--      every row: `stats_summary()`, `stats_week()`, `stats_leaderboard()`,
--      plus `lookup_enrollments_by_national_id()` for the QR scanner so it
--      never needs the whole enrollments table in memory.
--
-- Everything is idempotent (drop/create) and preserves the exact access
-- semantics of migrations 0006 / 0011 / 0012 / 0014 / 0016 / 0017 / 0018.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Single cached scope lookup
-- ---------------------------------------------------------------------
create or replace function public.my_scope()
returns table (role public.app_role, church_id uuid, service_id uuid, class_id uuid)
language sql stable security definer set search_path = public as $$
  select role, church_id, service_id, class_id
    from public.profiles
   where id = auth.uid() and status = 'approved'
$$;

-- Keep the old helpers (other code / policies still reference them) but
-- make them read from the same single-row lookup.
create or replace function public.my_role() returns public.app_role
language sql stable security definer set search_path = public as
$$ select role from public.my_scope() $$;

create or replace function public.my_church() returns uuid
language sql stable security definer set search_path = public as
$$ select church_id from public.my_scope() $$;

create or replace function public.my_service() returns uuid
language sql stable security definer set search_path = public as
$$ select service_id from public.my_scope() $$;

create or replace function public.my_class() returns uuid
language sql stable security definer set search_path = public as
$$ select class_id from public.my_scope() $$;

create or replace function public.is_owner() returns boolean
language sql stable security definer set search_path = public as
$$ select coalesce((select role from public.my_scope()) = 'owner', false) $$;

-- can_access: identical truth table to 0006, but ONE profile read.
create or replace function public.can_access(p_church uuid, p_service uuid, p_class uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((
    select case s.role
      when 'owner' then true
      when 'church_manager' then p_church = s.church_id
      when 'service_manager' then
        (s.service_id is null and p_church = s.church_id)
        or p_service = s.service_id
      when 'class_servant' then
        (s.class_id is null and (
          (s.service_id is null and p_church = s.church_id)
          or p_service = s.service_id
        ))
        or p_class = s.class_id
      else false
    end
    from public.my_scope() s
  ), false)
$$;

-- scope_overlaps / scope_contains (events, causes) — same semantics as 0014
create or replace function public.scope_overlaps(p_church uuid, p_service uuid, p_class uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((
    select case s.role
      when 'owner' then true
      when 'church_manager' then p_church = s.church_id
      when 'service_manager' then
        p_church = s.church_id
        and (s.service_id is null or p_service is null or p_service = s.service_id)
      when 'class_servant' then
        p_church = s.church_id
        and (s.service_id is null or p_service is null or p_service = s.service_id)
        and (s.class_id is null or p_class is null or p_class = s.class_id)
      else false
    end
    from public.my_scope() s
  ), false)
$$;

create or replace function public.scope_contains(p_church uuid, p_service uuid, p_class uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((
    select case s.role
      when 'owner' then true
      when 'church_manager' then p_church = s.church_id
      when 'service_manager' then
        p_church = s.church_id
        and (s.service_id is null or (p_service is not null and p_service = s.service_id))
      when 'class_servant' then
        p_church = s.church_id
        and (s.service_id is null or (p_service is not null and p_service = s.service_id))
        and (s.class_id is null or (p_class is not null and p_class = s.class_id))
      else false
    end
    from public.my_scope() s
  ), false)
$$;

-- ---------------------------------------------------------------------
-- 2. Indexes for the filters the app actually issues
-- ---------------------------------------------------------------------
create index if not exists idx_attendance_log_event_day
  on public.attendance_log(event_id, attended_on);
create index if not exists idx_attendance_log_attended_on
  on public.attendance_log(attended_on);
create index if not exists idx_attendance_log_enrollment_created
  on public.attendance_log(enrollment_id, created_at desc);
create index if not exists idx_points_log_enrollment_created
  on public.points_log(enrollment_id, created_at desc);
create index if not exists idx_enrollments_class_person
  on public.enrollments(class_id, person_id);
create index if not exists idx_enrollments_service_class
  on public.enrollments(service_id, class_id);
create index if not exists idx_enrollments_church_service
  on public.enrollments(church_id, service_id);
create index if not exists idx_enrollments_points_desc
  on public.enrollments(points desc);
create index if not exists idx_persons_phone on public.persons(phone);
create index if not exists idx_persons_created_by on public.persons(created_by);
create index if not exists idx_events_church on public.events(church_id);
create index if not exists idx_events_service on public.events(service_id);
create index if not exists idx_causes_church on public.causes(church_id);
create index if not exists idx_causes_service on public.causes(service_id);
create index if not exists idx_profiles_service on public.profiles(service_id);
create index if not exists idx_profiles_class on public.profiles(class_id);
create index if not exists idx_card_print_requests_enrollment
  on public.card_print_requests(enrollment_id);

-- ---------------------------------------------------------------------
-- 3. Policies rewritten with (select ...) so the helper is an InitPlan
--    evaluated once per statement rather than once per row.
-- ---------------------------------------------------------------------

-- ---------- CHURCHES ----------
drop policy if exists churches_select on public.churches;
create policy churches_select on public.churches for select using (
  (select public.is_owner()) or id = (select public.my_church())
);
drop policy if exists churches_update on public.churches;
create policy churches_update on public.churches for update using (
  (select public.is_owner())
  or ((select public.my_role()) = 'church_manager' and id = (select public.my_church()))
);

-- ---------- SERVICES ----------
drop policy if exists services_select on public.services;
create policy services_select on public.services for select using (
  (select public.is_owner())
  or ((select public.my_role()) = 'church_manager' and church_id = (select public.my_church()))
  or ((select public.my_role()) in ('service_manager','class_servant') and (
       id = (select public.my_service())
       or ((select public.my_service()) is null and church_id = (select public.my_church()))
  ))
);
drop policy if exists services_update on public.services;
create policy services_update on public.services for update using (
  (select public.is_owner())
  or ((select public.my_role()) = 'church_manager' and church_id = (select public.my_church()))
  or ((select public.my_role()) = 'service_manager' and (
       id = (select public.my_service())
       or ((select public.my_service()) is null and church_id = (select public.my_church()))
  ))
);

-- ---------- CLASSES ----------
drop policy if exists classes_select on public.classes;
create policy classes_select on public.classes for select using (
  (select public.is_owner())
  or (
    -- inline can_access(church_id, service_id, id) against the cached scope
    exists (
      select 1 from public.my_scope() s
      where case s.role
        when 'church_manager' then classes.church_id = s.church_id
        when 'service_manager' then
          (s.service_id is null and classes.church_id = s.church_id)
          or classes.service_id = s.service_id
        when 'class_servant' then
          (s.class_id is null and (
            (s.service_id is null and classes.church_id = s.church_id)
            or classes.service_id = s.service_id
          ))
          or classes.id = s.class_id
        else false
      end
    )
  )
);

-- ---------- PROFILES ----------
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select using (
  id = auth.uid()
  or (select public.is_owner())
  or ((select public.my_role()) = 'church_manager' and church_id = (select public.my_church()))
  or ((select public.my_role()) = 'service_manager' and (
       service_id = (select public.my_service())
       or ((select public.my_service()) is null and church_id = (select public.my_church()))
  ))
);
drop policy if exists profiles_update_mgmt on public.profiles;
create policy profiles_update_mgmt on public.profiles for update using (
  (select public.is_owner())
  or ((select public.my_role()) = 'church_manager' and church_id = (select public.my_church()))
  or ((select public.my_role()) = 'service_manager' and (
       service_id = (select public.my_service())
       or ((select public.my_service()) is null and church_id = (select public.my_church()))
  ))
);
drop policy if exists profiles_delete on public.profiles;
create policy profiles_delete on public.profiles for delete using (
  (select public.is_owner())
  or ((select public.my_role()) = 'church_manager' and church_id = (select public.my_church()))
  or ((select public.my_role()) = 'service_manager' and (
       service_id = (select public.my_service())
       or ((select public.my_service()) is null and church_id = (select public.my_church()))
  ))
);

-- ---------- ENROLLMENTS ----------
-- The heaviest table. Inline the access rule as a plain expression over the
-- single cached scope row (one InitPlan), so the planner can use the
-- church/service/class indexes directly.
create or replace function public.enrollment_visible(p_church uuid, p_service uuid, p_class uuid,
                                                     s_role public.app_role, s_church uuid,
                                                     s_service uuid, s_class uuid)
returns boolean language sql immutable as $$
  select case s_role
    when 'owner' then true
    when 'church_manager' then p_church = s_church
    when 'service_manager' then (s_service is null and p_church = s_church) or p_service = s_service
    when 'class_servant' then
      (s_class is null and ((s_service is null and p_church = s_church) or p_service = s_service))
      or p_class = s_class
    else false
  end
$$;

drop policy if exists enrollments_select on public.enrollments;
create policy enrollments_select on public.enrollments for select using (
  public.enrollment_visible(church_id, service_id, class_id,
    (select role from public.my_scope()), (select church_id from public.my_scope()),
    (select service_id from public.my_scope()), (select class_id from public.my_scope()))
);
drop policy if exists enrollments_insert on public.enrollments;
create policy enrollments_insert on public.enrollments for insert with check (
  public.enrollment_visible(church_id, service_id, class_id,
    (select role from public.my_scope()), (select church_id from public.my_scope()),
    (select service_id from public.my_scope()), (select class_id from public.my_scope()))
);
drop policy if exists enrollments_update on public.enrollments;
create policy enrollments_update on public.enrollments for update using (
  public.enrollment_visible(church_id, service_id, class_id,
    (select role from public.my_scope()), (select church_id from public.my_scope()),
    (select service_id from public.my_scope()), (select class_id from public.my_scope()))
);
drop policy if exists enrollments_delete on public.enrollments;
create policy enrollments_delete on public.enrollments for delete using (
  public.enrollment_visible(church_id, service_id, class_id,
    (select role from public.my_scope()), (select church_id from public.my_scope()),
    (select service_id from public.my_scope()), (select class_id from public.my_scope()))
);

-- ---------- PERSONS ----------
-- Visible when created by me, or I can see ANY enrollment of that person.
-- The EXISTS uses idx_enrollments_person and the inlined visibility rule.
drop policy if exists persons_select on public.persons;
create policy persons_select on public.persons for select using (
  created_by = auth.uid()
  or (select public.is_owner())
  or exists (
    select 1 from public.enrollments e
     where e.person_id = persons.id
       and public.enrollment_visible(e.church_id, e.service_id, e.class_id,
         (select role from public.my_scope()), (select church_id from public.my_scope()),
         (select service_id from public.my_scope()), (select class_id from public.my_scope()))
  )
);
drop policy if exists persons_insert on public.persons;
create policy persons_insert on public.persons for insert with check (
  (select public.my_role()) is not null
);
drop policy if exists persons_update on public.persons;
create policy persons_update on public.persons for update using (
  created_by = auth.uid()
  or (select public.is_owner())
  or exists (
    select 1 from public.enrollments e
     where e.person_id = persons.id
       and public.enrollment_visible(e.church_id, e.service_id, e.class_id,
         (select role from public.my_scope()), (select church_id from public.my_scope()),
         (select service_id from public.my_scope()), (select class_id from public.my_scope()))
  )
);
drop policy if exists persons_delete on public.persons;
create policy persons_delete on public.persons for delete using ((select public.is_owner()));

-- ---------- ATTENDANCE_LOG / POINTS_LOG ----------
-- Join to the (already RLS-filtered-by-expression) enrollment once.
drop policy if exists attendance_log_select on public.attendance_log;
create policy attendance_log_select on public.attendance_log for select using (
  exists (
    select 1 from public.enrollments e
     where e.id = attendance_log.enrollment_id
       and public.enrollment_visible(e.church_id, e.service_id, e.class_id,
         (select role from public.my_scope()), (select church_id from public.my_scope()),
         (select service_id from public.my_scope()), (select class_id from public.my_scope()))
  )
);
drop policy if exists attendance_log_insert on public.attendance_log;
create policy attendance_log_insert on public.attendance_log for insert with check (
  recorded_by = auth.uid() and exists (
    select 1 from public.enrollments e
     where e.id = attendance_log.enrollment_id
       and public.enrollment_visible(e.church_id, e.service_id, e.class_id,
         (select role from public.my_scope()), (select church_id from public.my_scope()),
         (select service_id from public.my_scope()), (select class_id from public.my_scope()))
  )
);
drop policy if exists attendance_log_delete on public.attendance_log;
create policy attendance_log_delete on public.attendance_log for delete using (
  exists (
    select 1 from public.enrollments e
     where e.id = attendance_log.enrollment_id
       and public.enrollment_visible(e.church_id, e.service_id, e.class_id,
         (select role from public.my_scope()), (select church_id from public.my_scope()),
         (select service_id from public.my_scope()), (select class_id from public.my_scope()))
  )
);
drop policy if exists points_log_select on public.points_log;
create policy points_log_select on public.points_log for select using (
  exists (
    select 1 from public.enrollments e
     where e.id = points_log.enrollment_id
       and public.enrollment_visible(e.church_id, e.service_id, e.class_id,
         (select role from public.my_scope()), (select church_id from public.my_scope()),
         (select service_id from public.my_scope()), (select class_id from public.my_scope()))
  )
);
drop policy if exists points_log_insert on public.points_log;
create policy points_log_insert on public.points_log for insert with check (
  recorded_by = auth.uid() and exists (
    select 1 from public.enrollments e
     where e.id = points_log.enrollment_id
       and public.enrollment_visible(e.church_id, e.service_id, e.class_id,
         (select role from public.my_scope()), (select church_id from public.my_scope()),
         (select service_id from public.my_scope()), (select class_id from public.my_scope()))
  )
);

-- ---------- EVENTS / CAUSES ----------
drop policy if exists events_select on public.events;
create policy events_select on public.events for select using (
  (select public.scope_overlaps(church_id, service_id, class_id))
);
drop policy if exists events_insert on public.events;
create policy events_insert on public.events for insert with check (
  (select public.scope_contains(church_id, service_id, class_id))
);
drop policy if exists events_update on public.events;
create policy events_update on public.events for update using (
  (select public.scope_contains(church_id, service_id, class_id))
) with check (
  (select public.scope_contains(church_id, service_id, class_id))
);
drop policy if exists events_delete on public.events;
create policy events_delete on public.events for delete using (
  (select public.scope_contains(church_id, service_id, class_id))
);

drop policy if exists causes_select on public.causes;
create policy causes_select on public.causes for select using (
  (select public.scope_overlaps(church_id, service_id, class_id))
);
drop policy if exists causes_insert on public.causes;
create policy causes_insert on public.causes for insert with check (
  (select public.scope_contains(church_id, service_id, class_id))
);
drop policy if exists causes_update on public.causes;
create policy causes_update on public.causes for update using (
  (select public.scope_contains(church_id, service_id, class_id))
) with check (
  (select public.scope_contains(church_id, service_id, class_id))
);
drop policy if exists causes_delete on public.causes;
create policy causes_delete on public.causes for delete using (
  (select public.scope_contains(church_id, service_id, class_id))
);

-- ---------- CARD TEMPLATES / PRINT REQUESTS ----------
drop policy if exists card_templates_select on public.card_templates;
create policy card_templates_select on public.card_templates for select using (
  (select public.can_access(church_id, service_id, class_id))
);
drop policy if exists card_templates_insert on public.card_templates;
create policy card_templates_insert on public.card_templates for insert with check (
  (select public.can_access(church_id, service_id, class_id))
);
drop policy if exists card_templates_update on public.card_templates;
create policy card_templates_update on public.card_templates for update using (
  (select public.can_access(church_id, service_id, class_id))
) with check (
  (select public.can_access(church_id, service_id, class_id))
);
drop policy if exists card_templates_delete on public.card_templates;
create policy card_templates_delete on public.card_templates for delete using (
  (select public.can_access(church_id, service_id, class_id))
);

drop policy if exists card_print_requests_select on public.card_print_requests;
create policy card_print_requests_select on public.card_print_requests for select using (
  public.enrollment_visible(church_id, service_id, class_id,
    (select role from public.my_scope()), (select church_id from public.my_scope()),
    (select service_id from public.my_scope()), (select class_id from public.my_scope()))
);
drop policy if exists card_print_requests_delete on public.card_print_requests;
create policy card_print_requests_delete on public.card_print_requests for delete using (
  public.enrollment_visible(church_id, service_id, class_id,
    (select role from public.my_scope()), (select church_id from public.my_scope()),
    (select service_id from public.my_scope()), (select class_id from public.my_scope()))
);

-- ---------------------------------------------------------------------
-- 4. Aggregation / lookup RPCs — fetch numbers, not rows
--    All run as the caller (security invoker) so RLS still applies.
-- ---------------------------------------------------------------------

-- Totals for the stats page (optionally narrowed by scope)
create or replace function public.stats_summary(
  p_church uuid default null, p_service uuid default null, p_class uuid default null)
returns table (enrollments bigint, persons bigint, total_attendance bigint, total_points bigint)
language sql stable security invoker set search_path = public as $$
  select count(*)::bigint,
         count(distinct person_id)::bigint,
         coalesce(sum(attendance_count), 0)::bigint,
         coalesce(sum(points), 0)::bigint
    from public.enrollments
   where (p_church  is null or church_id  = p_church)
     and (p_service is null or service_id = p_service)
     and (p_class   is null or class_id   = p_class)
$$;

-- Attendance per Cairo day for the last N days (default 7)
create or replace function public.stats_week(
  p_days int default 7,
  p_church uuid default null, p_service uuid default null, p_class uuid default null)
returns table (day date, count bigint)
language sql stable security invoker set search_path = public as $$
  select a.attended_on, count(*)::bigint
    from public.attendance_log a
    join public.enrollments e on e.id = a.enrollment_id
   where a.attended_on >= ((now() at time zone 'Africa/Cairo')::date - (p_days - 1))
     and (p_church  is null or e.church_id  = p_church)
     and (p_service is null or e.service_id = p_service)
     and (p_class   is null or e.class_id   = p_class)
   group by a.attended_on
   order by a.attended_on
$$;

-- Top-N leaderboard (default 10)
create or replace function public.stats_leaderboard(
  p_limit int default 10,
  p_church uuid default null, p_service uuid default null, p_class uuid default null)
returns table (enrollment_id uuid, person_id uuid, name text, points integer, attendance_count integer)
language sql stable security invoker set search_path = public as $$
  select e.id, e.person_id, p.name, e.points, e.attendance_count
    from public.enrollments e
    join public.persons p on p.id = e.person_id
   where (p_church  is null or e.church_id  = p_church)
     and (p_service is null or e.service_id = p_service)
     and (p_class   is null or e.class_id   = p_class)
   order by e.points desc, p.name
   limit greatest(1, least(p_limit, 100))
$$;

-- Home dashboard: every counter in ONE round-trip
create or replace function public.dashboard_counts(p_today_start timestamptz)
returns table (
  persons bigint, enrollments bigint, today_attendance bigint,
  pending_servants bigint, churches bigint, services bigint, classes bigint)
language sql stable security invoker set search_path = public as $$
  select
    (select count(distinct person_id) from public.enrollments),
    (select count(*) from public.enrollments),
    (select count(*) from public.attendance_log where created_at >= p_today_start),
    (select count(*) from public.profiles where status = 'pending'),
    (select count(*) from public.churches),
    (select count(*) from public.services),
    (select count(*) from public.classes)
$$;

-- QR scanner: national id -> that person's enrollments in my scope.
-- Returns the same shape the app uses (enrollment + embedded person).
create or replace function public.lookup_enrollments_by_national_id(p_national_id text)
returns table (
  id uuid, person_id uuid, church_id uuid, service_id uuid, class_id uuid,
  attendance_count integer, points integer, created_at timestamptz,
  person jsonb)
language sql stable security invoker set search_path = public as $$
  select e.id, e.person_id, e.church_id, e.service_id, e.class_id,
         e.attendance_count, e.points, e.created_at,
         to_jsonb(p) as person
    from public.persons p
    join public.enrollments e on e.person_id = p.id
   where p.national_id = p_national_id
   order by e.created_at
$$;

grant execute on function public.stats_summary(uuid, uuid, uuid) to authenticated;
grant execute on function public.stats_week(int, uuid, uuid, uuid) to authenticated;
grant execute on function public.stats_leaderboard(int, uuid, uuid, uuid) to authenticated;
grant execute on function public.dashboard_counts(timestamptz) to authenticated;
grant execute on function public.lookup_enrollments_by_national_id(text) to authenticated;
grant execute on function public.my_scope() to authenticated, anon;
grant execute on function public.enrollment_visible(uuid, uuid, uuid, public.app_role, uuid, uuid, uuid) to authenticated, anon;

-- ---------------------------------------------------------------------
-- 5. Make sure the planner has fresh statistics for the new indexes
-- ---------------------------------------------------------------------
analyze public.persons;
analyze public.enrollments;
analyze public.attendance_log;
analyze public.points_log;

commit;
