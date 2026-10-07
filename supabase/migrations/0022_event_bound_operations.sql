-- =====================================================================
-- 0022: EVENT-BOUND OPERATIONS
--
-- The hierarchy becomes  church → service → class → EVENT.
-- Every operation a servant performs on a child happens INSIDE an event:
--
--   attendance  → attendance_log.event_id   (already, since 0013)
--   points      → points_log.event_id       (NEW — nullable for legacy rows)
--   call / msg  → contact_log (NEW table)   — a follow-up made for an event
--
-- 1. points_log.event_id + scope check (event must apply to the enrollment)
-- 2. contact_log: kind = call | whatsapp | sms | internal, event_id,
--    template text (for messages), recorded_by. Used to know who was
--    followed up for an event (e.g. absent children who were called).
-- 3. RLS (same InitPlan pattern as 0019), indexes, realtime.
--
-- Idempotent — safe to re-run.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. POINTS ARE GIVEN INSIDE AN EVENT
-- ---------------------------------------------------------------------
alter table public.points_log
  add column if not exists event_id uuid references public.events(id) on delete set null;

create index if not exists idx_points_log_event on public.points_log(event_id);
create index if not exists idx_points_log_event_created on public.points_log(event_id, created_at desc);

-- The event must apply to the enrollment's scope (same rule as attendance)
create or replace function public.check_points_event_scope()
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

drop trigger if exists trg_points_event_scope on public.points_log;
create trigger trg_points_event_scope before insert on public.points_log
for each row execute function public.check_points_event_scope();

-- ---------------------------------------------------------------------
-- 2. CONTACT LOG — calls & messages made for an event (follow-up)
-- ---------------------------------------------------------------------
create table if not exists public.contact_log (
  id            uuid primary key default gen_random_uuid(),
  enrollment_id uuid not null references public.enrollments(id) on delete cascade,
  event_id      uuid references public.events(id) on delete set null,
  kind          text not null check (kind in ('call', 'whatsapp', 'sms', 'internal')),
  -- the message text actually sent (variables already substituted); null for calls
  message       text,
  -- Cairo day the follow-up was made on (lets us list "who was contacted
  -- for this event occurrence")
  contacted_on  date not null default ((now() at time zone 'Africa/Cairo')::date),
  recorded_by   uuid references public.profiles(id),
  created_at    timestamptz not null default now()
);

create index if not exists idx_contact_log_enrollment_created
  on public.contact_log(enrollment_id, created_at desc);
create index if not exists idx_contact_log_event_day
  on public.contact_log(event_id, contacted_on);
create index if not exists idx_contact_log_created
  on public.contact_log(created_at);

-- Event must apply to the enrollment's scope
create or replace function public.check_contact_event_scope()
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

drop trigger if exists trg_contact_event_scope on public.contact_log;
create trigger trg_contact_event_scope before insert on public.contact_log
for each row execute function public.check_contact_event_scope();

-- ---------------------------------------------------------------------
-- 3. RLS — same InitPlan pattern as 0019 (one my_scope() lookup)
-- ---------------------------------------------------------------------
alter table public.contact_log enable row level security;

drop policy if exists contact_log_select on public.contact_log;
create policy contact_log_select on public.contact_log for select using (
  exists (
    select 1 from public.enrollments e
     where e.id = contact_log.enrollment_id
       and public.enrollment_visible(e.church_id, e.service_id, e.class_id,
         (select role from public.my_scope()), (select church_id from public.my_scope()),
         (select service_id from public.my_scope()), (select class_id from public.my_scope()))
  )
);

drop policy if exists contact_log_insert on public.contact_log;
create policy contact_log_insert on public.contact_log for insert with check (
  recorded_by = auth.uid() and exists (
    select 1 from public.enrollments e
     where e.id = contact_log.enrollment_id
       and public.enrollment_visible(e.church_id, e.service_id, e.class_id,
         (select role from public.my_scope()), (select church_id from public.my_scope()),
         (select service_id from public.my_scope()), (select class_id from public.my_scope()))
  )
);

drop policy if exists contact_log_delete on public.contact_log;
create policy contact_log_delete on public.contact_log for delete using (
  exists (
    select 1 from public.enrollments e
     where e.id = contact_log.enrollment_id
       and public.enrollment_visible(e.church_id, e.service_id, e.class_id,
         (select role from public.my_scope()), (select church_id from public.my_scope()),
         (select service_id from public.my_scope()), (select class_id from public.my_scope()))
  )
);

-- ---------------------------------------------------------------------
-- 4. REALTIME
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'contact_log'
  ) then
    alter publication supabase_realtime add table public.contact_log;
  end if;
end $$;
alter table public.contact_log replica identity full;

-- ---------------------------------------------------------------------
-- 5. Child portal: expose the event on points entries (reason keeps the
--    cause name; event_name is added as a new trailing column)
-- ---------------------------------------------------------------------
drop function if exists public.child_portal_points(text);
create or replace function public.child_portal_points(p_national_id text)
returns table (
  id uuid, enrollment_id uuid, source text, reason text,
  delta integer, created_at timestamptz, recorded_by_name text,
  class_name text, service_name text, church_name text,
  event_name text
) language plpgsql stable security definer set search_path = public as $$
declare
  p public.persons;
begin
  p := public.child_portal_person(p_national_id);
  return query
    select x.id, x.enrollment_id, x.source, x.reason, x.delta, x.created_at,
           pr.full_name, cl.name, sv.name, ch.name, x.event_name
      from (
        select pl.id, pl.enrollment_id, 'cause'::text as source,
               ca.name as reason, pl.delta, pl.created_at, pl.recorded_by,
               ev.name as event_name
          from public.points_log pl
          join public.enrollments e on e.id = pl.enrollment_id
          left join public.causes ca on ca.id = pl.cause_id
          left join public.events ev on ev.id = pl.event_id
         where e.person_id = p.id
        union all
        select a.id, a.enrollment_id, 'attendance'::text,
               ev.name, a.points_delta, a.created_at, a.recorded_by,
               ev.name
          from public.attendance_log a
          join public.enrollments e on e.id = a.enrollment_id
          left join public.events ev on ev.id = a.event_id
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

analyze public.points_log;

commit;
