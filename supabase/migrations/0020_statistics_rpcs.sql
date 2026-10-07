-- =====================================================================
-- 0020: STATISTICS TAB — comprehensive aggregation RPCs
--
-- The rebuilt الإحصائيات tab is driven by three scope selectors
-- (church / service / class — each with a "كل الـ..." = null option), a
-- selected day (the header working date) and a period + granularity for
-- the timeline chart. Every number on the screen comes from ONE of the
-- functions below, so the browser never downloads log rows — cost grows
-- with the number of events / causes / buckets, not with the size of the
-- diocese.
--
-- All functions are SECURITY INVOKER → RLS on enrollments / attendance_log
-- / points_log / events / causes still applies, so a class servant only
-- ever aggregates what he is allowed to see.
--
-- Scope arguments: p_church / p_service / p_class — null means "all".
-- Dates are Cairo calendar days ('YYYY-MM-DD', the app's attended_on).
-- Everything is idempotent (create or replace).
--
--   stats_scope_summary       — headline KPIs for the scope
--   stats_day_summary         — KPIs of ONE selected day
--   stats_attendance_by_event — attendance on a day, grouped by event
--   stats_points_by_cause     — points granted on a day, grouped by cause
--   stats_attendance_timeline — attendance per bucket (day/week/month) × event
--   stats_points_timeline     — points per bucket (day/week/month) × cause
--   stats_attendance_by_class — attendance on a day per class (breakdown)
--   stats_leaderboard_scoped  — top-N by points / attendance for the scope
--   stats_weekday_profile     — attendance by weekday over a period
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- Scope helper: the enrollments this statistic is about.
-- (inlined into each function as a WHERE clause — kept here as doc)
--   (p_church  is null or e.church_id  = p_church)
--   (p_service is null or e.service_id = p_service)
--   (p_class   is null or e.class_id   = p_class)
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- 1. Headline KPIs of the scope (all time)
-- ---------------------------------------------------------------------
drop function if exists public.stats_scope_summary(uuid, uuid, uuid);
create or replace function public.stats_scope_summary(
  p_church uuid default null, p_service uuid default null, p_class uuid default null)
returns table (
  enrollments      bigint,   -- إجمالي التسجيلات
  persons          bigint,   -- إجمالي المخدومين (distinct persons)
  males            bigint,
  females          bigint,
  total_attendance bigint,   -- sum(enrollments.attendance_count)
  total_points     bigint,   -- sum(enrollments.points) — current balance
  attendance_points bigint,  -- points that came with attendance (all time)
  cause_points_added bigint, -- positive cause deltas (all time)
  cause_points_removed bigint, -- abs(negative cause deltas) (all time)
  events_count     bigint,   -- events applying to the scope
  causes_count     bigint,   -- causes applying to the scope
  classes_count    bigint,   -- distinct classes with enrollments in scope
  first_attendance date,     -- earliest attended_on in scope
  last_attendance  date      -- latest attended_on in scope
)
language sql stable security invoker set search_path = public as $$
  with sc as (
    select e.id, e.person_id, e.church_id, e.service_id, e.class_id,
           e.attendance_count, e.points
      from public.enrollments e
     where (p_church  is null or e.church_id  = p_church)
       and (p_service is null or e.service_id = p_service)
       and (p_class   is null or e.class_id   = p_class)
  )
  select
    (select count(*) from sc),
    (select count(distinct person_id) from sc),
    (select count(distinct sc.person_id) from sc join public.persons p on p.id = sc.person_id where p.gender = 'male'),
    (select count(distinct sc.person_id) from sc join public.persons p on p.id = sc.person_id where p.gender = 'female'),
    (select coalesce(sum(attendance_count), 0) from sc),
    (select coalesce(sum(points), 0) from sc),
    (select coalesce(sum(a.points_delta), 0) from public.attendance_log a join sc on sc.id = a.enrollment_id),
    (select coalesce(sum(l.delta), 0) from public.points_log l join sc on sc.id = l.enrollment_id where l.delta > 0),
    (select coalesce(-sum(l.delta), 0) from public.points_log l join sc on sc.id = l.enrollment_id where l.delta < 0),
    (select count(*) from public.events ev
      where (p_church  is null or ev.church_id = p_church)
        and (p_service is null or ev.service_id is null or ev.service_id = p_service)
        and (p_class   is null or ev.class_id   is null or ev.class_id   = p_class)),
    (select count(*) from public.causes ca
      where (p_church  is null or ca.church_id = p_church)
        and (p_service is null or ca.service_id is null or ca.service_id = p_service)
        and (p_class   is null or ca.class_id   is null or ca.class_id   = p_class)),
    (select count(distinct class_id) from sc),
    (select min(a.attended_on) from public.attendance_log a join sc on sc.id = a.enrollment_id),
    (select max(a.attended_on) from public.attendance_log a join sc on sc.id = a.enrollment_id)
$$;

-- ---------------------------------------------------------------------
-- 2. KPIs of ONE selected day
-- ---------------------------------------------------------------------
drop function if exists public.stats_day_summary(date, uuid, uuid, uuid);
create or replace function public.stats_day_summary(
  p_day date,
  p_church uuid default null, p_service uuid default null, p_class uuid default null)
returns table (
  attendance        bigint,  -- attendance rows on the day
  attendees         bigint,  -- distinct persons who attended
  events_attended   bigint,  -- distinct events with ≥1 attendance
  attendance_points bigint,  -- points granted with attendance
  cause_points_added   bigint,
  cause_points_removed bigint,
  cause_entries     bigint,  -- points_log rows on the day
  causes_used       bigint,  -- distinct causes used
  scope_persons     bigint   -- persons in scope (denominator for %)
)
language sql stable security invoker set search_path = public as $$
  with sc as (
    select e.id, e.person_id
      from public.enrollments e
     where (p_church  is null or e.church_id  = p_church)
       and (p_service is null or e.service_id = p_service)
       and (p_class   is null or e.class_id   = p_class)
  ),
  att as (
    select a.*, sc.person_id
      from public.attendance_log a join sc on sc.id = a.enrollment_id
     where a.attended_on = p_day
  ),
  pts as (
    select l.*
      from public.points_log l join sc on sc.id = l.enrollment_id
     where (l.created_at at time zone 'Africa/Cairo')::date = p_day
  )
  select
    (select count(*) from att),
    (select count(distinct person_id) from att),
    (select count(distinct event_id) from att where event_id is not null),
    (select coalesce(sum(points_delta), 0) from att),
    (select coalesce(sum(delta), 0) from pts where delta > 0),
    (select coalesce(-sum(delta), 0) from pts where delta < 0),
    (select count(*) from pts),
    (select count(distinct cause_id) from pts where cause_id is not null),
    (select count(distinct person_id) from sc)
$$;

-- ---------------------------------------------------------------------
-- 3. Attendance on a day, grouped by EVENT (sorted by event)
-- ---------------------------------------------------------------------
drop function if exists public.stats_attendance_by_event(date, uuid, uuid, uuid);
create or replace function public.stats_attendance_by_event(
  p_day date,
  p_church uuid default null, p_service uuid default null, p_class uuid default null)
returns table (
  event_id      uuid,
  event_name    text,
  church_id     uuid,     -- to disambiguate same-named events across churches
  event_scope   text,     -- 'church' | 'service' | 'class'
  attendance    bigint,   -- rows
  attendees     bigint,   -- distinct persons
  points        bigint,   -- sum(points_delta)
  eligible      bigint,   -- enrollments in scope the event applies to
  first_at      timestamptz,
  last_at       timestamptz
)
language sql stable security invoker set search_path = public as $$
  with sc as (
    select e.id, e.person_id, e.church_id, e.service_id, e.class_id
      from public.enrollments e
     where (p_church  is null or e.church_id  = p_church)
       and (p_service is null or e.service_id = p_service)
       and (p_class   is null or e.class_id   = p_class)
  ),
  att as (
    select a.event_id, a.points_delta, a.created_at, sc.person_id
      from public.attendance_log a join sc on sc.id = a.enrollment_id
     where a.attended_on = p_day
  ),
  grp as (
    select event_id,
           count(*)::bigint as attendance,
           count(distinct person_id)::bigint as attendees,
           coalesce(sum(points_delta), 0)::bigint as points,
           min(created_at) as first_at,
           max(created_at) as last_at
      from att group by event_id
  )
  select g.event_id,
         coalesce(ev.name, 'بدون مناسبة') as event_name,
         ev.church_id,
         case when ev.id is null then 'church'
              when ev.class_id is not null then 'class'
              when ev.service_id is not null then 'service'
              else 'church' end as event_scope,
         g.attendance, g.attendees, g.points,
         (select count(*) from sc
           where ev.id is not null
             and sc.church_id = ev.church_id
             and (ev.service_id is null or sc.service_id = ev.service_id)
             and (ev.class_id   is null or sc.class_id   = ev.class_id))::bigint as eligible,
         g.first_at, g.last_at
    from grp g
    left join public.events ev on ev.id = g.event_id
   order by event_name, g.event_id
$$;

-- ---------------------------------------------------------------------
-- 4. Points granted on a day, grouped by CAUSE (sorted by cause)
-- ---------------------------------------------------------------------
drop function if exists public.stats_points_by_cause(date, uuid, uuid, uuid);
create or replace function public.stats_points_by_cause(
  p_day date,
  p_church uuid default null, p_service uuid default null, p_class uuid default null)
returns table (
  cause_id      uuid,
  cause_name    text,
  church_id     uuid,
  cause_scope   text,
  entries       bigint,   -- points_log rows
  recipients    bigint,   -- distinct persons
  added         bigint,   -- sum of positive deltas
  removed       bigint,   -- abs(sum of negative deltas)
  net           bigint,   -- added - removed
  first_at      timestamptz,
  last_at       timestamptz
)
language sql stable security invoker set search_path = public as $$
  with sc as (
    select e.id, e.person_id
      from public.enrollments e
     where (p_church  is null or e.church_id  = p_church)
       and (p_service is null or e.service_id = p_service)
       and (p_class   is null or e.class_id   = p_class)
  ),
  pts as (
    select l.cause_id, l.delta, l.created_at, sc.person_id
      from public.points_log l join sc on sc.id = l.enrollment_id
     where (l.created_at at time zone 'Africa/Cairo')::date = p_day
  ),
  grp as (
    select cause_id,
           count(*)::bigint as entries,
           count(distinct person_id)::bigint as recipients,
           coalesce(sum(case when delta > 0 then delta else 0 end), 0)::bigint as added,
           coalesce(sum(case when delta < 0 then -delta else 0 end), 0)::bigint as removed,
           coalesce(sum(delta), 0)::bigint as net,
           min(created_at) as first_at,
           max(created_at) as last_at
      from pts group by cause_id
  )
  select g.cause_id,
         coalesce(ca.name, 'بدون سبب') as cause_name,
         ca.church_id,
         case when ca.id is null then 'church'
              when ca.class_id is not null then 'class'
              when ca.service_id is not null then 'service'
              else 'church' end as cause_scope,
         g.entries, g.recipients, g.added, g.removed, g.net, g.first_at, g.last_at
    from grp g
    left join public.causes ca on ca.id = g.cause_id
   order by cause_name, g.cause_id
$$;

-- ---------------------------------------------------------------------
-- 5. Attendance TIMELINE — per bucket × event over a period
--    p_bucket: 'day' | 'week' | 'month'. Buckets are Cairo calendar
--    days / ISO weeks (Monday start) / months, returned as the bucket's
--    first day. The client fills empty buckets with zero.
-- ---------------------------------------------------------------------
drop function if exists public.stats_attendance_timeline(date, date, text, uuid, uuid, uuid);
create or replace function public.stats_attendance_timeline(
  p_from date, p_to date, p_bucket text default 'day',
  p_church uuid default null, p_service uuid default null, p_class uuid default null)
returns table (
  bucket      date,
  event_id    uuid,
  event_name  text,
  church_id   uuid,
  attendance  bigint,
  attendees   bigint,
  points      bigint
)
language sql stable security invoker set search_path = public as $$
  with sc as (
    select e.id, e.person_id
      from public.enrollments e
     where (p_church  is null or e.church_id  = p_church)
       and (p_service is null or e.service_id = p_service)
       and (p_class   is null or e.class_id   = p_class)
  ),
  att as (
    select case lower(coalesce(p_bucket, 'day'))
             when 'week'  then date_trunc('week',  a.attended_on::timestamp)::date
             when 'month' then date_trunc('month', a.attended_on::timestamp)::date
             else a.attended_on
           end as bucket,
           a.event_id, a.points_delta, sc.person_id
      from public.attendance_log a join sc on sc.id = a.enrollment_id
     where a.attended_on between p_from and p_to
  )
  select att.bucket, att.event_id,
         coalesce(ev.name, 'بدون مناسبة') as event_name,
         ev.church_id,
         count(*)::bigint,
         count(distinct att.person_id)::bigint,
         coalesce(sum(att.points_delta), 0)::bigint
    from att
    left join public.events ev on ev.id = att.event_id
   group by att.bucket, att.event_id, ev.name, ev.church_id
   order by att.bucket, event_name
$$;

-- ---------------------------------------------------------------------
-- 6. Points TIMELINE — per bucket × cause over a period
-- ---------------------------------------------------------------------
drop function if exists public.stats_points_timeline(date, date, text, uuid, uuid, uuid);
create or replace function public.stats_points_timeline(
  p_from date, p_to date, p_bucket text default 'day',
  p_church uuid default null, p_service uuid default null, p_class uuid default null)
returns table (
  bucket      date,
  cause_id    uuid,
  cause_name  text,
  church_id   uuid,
  entries     bigint,
  added       bigint,
  removed     bigint,
  net         bigint
)
language sql stable security invoker set search_path = public as $$
  with sc as (
    select e.id
      from public.enrollments e
     where (p_church  is null or e.church_id  = p_church)
       and (p_service is null or e.service_id = p_service)
       and (p_class   is null or e.class_id   = p_class)
  ),
  pts as (
    select (l.created_at at time zone 'Africa/Cairo')::date as day, l.cause_id, l.delta
      from public.points_log l join sc on sc.id = l.enrollment_id
     where (l.created_at at time zone 'Africa/Cairo')::date between p_from and p_to
  ),
  b as (
    select case lower(coalesce(p_bucket, 'day'))
             when 'week'  then date_trunc('week',  day::timestamp)::date
             when 'month' then date_trunc('month', day::timestamp)::date
             else day
           end as bucket, cause_id, delta
      from pts
  )
  select b.bucket, b.cause_id,
         coalesce(ca.name, 'بدون سبب') as cause_name,
         ca.church_id,
         count(*)::bigint,
         coalesce(sum(case when b.delta > 0 then b.delta else 0 end), 0)::bigint,
         coalesce(sum(case when b.delta < 0 then -b.delta else 0 end), 0)::bigint,
         coalesce(sum(b.delta), 0)::bigint
    from b
    left join public.causes ca on ca.id = b.cause_id
   group by b.bucket, b.cause_id, ca.name, ca.church_id
   order by b.bucket, cause_name
$$;

-- ---------------------------------------------------------------------
-- 7. Attendance on a day per CLASS (with % of enrolled)
-- ---------------------------------------------------------------------
drop function if exists public.stats_attendance_by_class(date, uuid, uuid, uuid);
create or replace function public.stats_attendance_by_class(
  p_day date,
  p_church uuid default null, p_service uuid default null, p_class uuid default null)
returns table (
  class_id     uuid,
  class_name   text,
  service_name text,
  church_name  text,
  enrolled     bigint,
  attendees    bigint,   -- distinct persons attended (any event)
  attendance   bigint,   -- rows
  points       bigint
)
language sql stable security invoker set search_path = public as $$
  with sc as (
    select e.id, e.person_id, e.class_id
      from public.enrollments e
     where (p_church  is null or e.church_id  = p_church)
       and (p_service is null or e.service_id = p_service)
       and (p_class   is null or e.class_id   = p_class)
  ),
  att as (
    select sc.class_id, sc.person_id, a.points_delta
      from public.attendance_log a join sc on sc.id = a.enrollment_id
     where a.attended_on = p_day
  )
  select c.id, c.name, s.name, ch.name,
         (select count(*) from sc where sc.class_id = c.id)::bigint,
         (select count(distinct person_id) from att where att.class_id = c.id)::bigint,
         (select count(*) from att where att.class_id = c.id)::bigint,
         (select coalesce(sum(points_delta), 0) from att where att.class_id = c.id)::bigint
    from public.classes c
    join public.services s on s.id = c.service_id
    join public.churches ch on ch.id = c.church_id
   where c.id in (select distinct class_id from sc)
   order by ch.name, s.name, c.name
$$;

-- ---------------------------------------------------------------------
-- 8. Leaderboard for the scope — by points or by attendance
-- ---------------------------------------------------------------------
drop function if exists public.stats_leaderboard_scoped(text, int, uuid, uuid, uuid);
create or replace function public.stats_leaderboard_scoped(
  p_by text default 'points', p_limit int default 10,
  p_church uuid default null, p_service uuid default null, p_class uuid default null)
returns table (
  enrollment_id uuid, person_id uuid, name text, image_url text,
  class_name text, points integer, attendance_count integer)
language sql stable security invoker set search_path = public as $$
  select e.id, e.person_id, p.name, p.image_url, c.name, e.points, e.attendance_count
    from public.enrollments e
    join public.persons p on p.id = e.person_id
    left join public.classes c on c.id = e.class_id
   where (p_church  is null or e.church_id  = p_church)
     and (p_service is null or e.service_id = p_service)
     and (p_class   is null or e.class_id   = p_class)
   order by
     case when lower(coalesce(p_by, 'points')) = 'attendance' then e.attendance_count else e.points end desc,
     case when lower(coalesce(p_by, 'points')) = 'attendance' then e.points else e.attendance_count end desc,
     p.name
   limit greatest(1, least(coalesce(p_limit, 10), 100))
$$;

-- ---------------------------------------------------------------------
-- 9. Weekday profile — attendance by weekday (0=Sun..6=Sat) over a period
-- ---------------------------------------------------------------------
drop function if exists public.stats_weekday_profile(date, date, uuid, uuid, uuid);
create or replace function public.stats_weekday_profile(
  p_from date, p_to date,
  p_church uuid default null, p_service uuid default null, p_class uuid default null)
returns table (weekday int, attendance bigint, days_with_attendance bigint)
language sql stable security invoker set search_path = public as $$
  with sc as (
    select e.id from public.enrollments e
     where (p_church  is null or e.church_id  = p_church)
       and (p_service is null or e.service_id = p_service)
       and (p_class   is null or e.class_id   = p_class)
  )
  select extract(dow from a.attended_on)::int,
         count(*)::bigint,
         count(distinct a.attended_on)::bigint
    from public.attendance_log a join sc on sc.id = a.enrollment_id
   where a.attended_on between p_from and p_to
   group by 1 order by 1
$$;

-- ---------------------------------------------------------------------
-- Index for the points-by-day queries (Cairo-day expression)
-- ---------------------------------------------------------------------
create index if not exists idx_points_log_cairo_day
  on public.points_log (((created_at at time zone 'Africa/Cairo')::date));
create index if not exists idx_points_log_cause on public.points_log(cause_id);

-- ---------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------
grant execute on function public.stats_scope_summary(uuid, uuid, uuid) to authenticated;
grant execute on function public.stats_day_summary(date, uuid, uuid, uuid) to authenticated;
grant execute on function public.stats_attendance_by_event(date, uuid, uuid, uuid) to authenticated;
grant execute on function public.stats_points_by_cause(date, uuid, uuid, uuid) to authenticated;
grant execute on function public.stats_attendance_timeline(date, date, text, uuid, uuid, uuid) to authenticated;
grant execute on function public.stats_points_timeline(date, date, text, uuid, uuid, uuid) to authenticated;
grant execute on function public.stats_attendance_by_class(date, uuid, uuid, uuid) to authenticated;
grant execute on function public.stats_leaderboard_scoped(text, int, uuid, uuid, uuid) to authenticated;
grant execute on function public.stats_weekday_profile(date, date, uuid, uuid, uuid) to authenticated;

analyze public.points_log;

commit;
