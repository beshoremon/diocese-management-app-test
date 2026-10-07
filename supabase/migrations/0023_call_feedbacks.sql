-- =====================================================================
-- 0023: CALL FEEDBACKS (نتائج الاتصال)
--
-- A servant calls a child as a FOLLOW-UP for an event occurrence (e.g. the
-- absentees of Friday's mass). The outcome of that call is a FEEDBACK
-- chosen from a list the managers define — each feedback has a NAME, a
-- COLOR and an ICON and is bound to a scope exactly like events / causes:
--
--     church → service (null = all) → class (null = all) → event (null = all)
--
-- The children page & scanner show a CALL FEEDBACK BADGE right after the
-- status badge:
--     لم يُتصل به بعد  (not called yet) — the follow-up cycle is still open
--     لم يُتصل به      (wasn't called)  — the next occurrence has started
--                                        and nobody called him
--     <feedback>       (color + icon + name) — the recorded outcome
--
-- Storage: the feedback is a `contact_log` row (kind = 'call') carrying the
-- chosen `feedback_id` and the `occurrence_on` day the follow-up refers to.
-- Keeping it in contact_log preserves the history (a log, like attendance
-- and points); the badge shows the LATEST feedback for the occurrence.
--
-- Idempotent — safe to re-run. Depends on 0019 (scope_overlaps /
-- scope_contains) and 0022 (contact_log).
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. MASTER TABLE: call_feedbacks
-- ---------------------------------------------------------------------
create table if not exists public.call_feedbacks (
  id          uuid primary key default gen_random_uuid(),
  church_id   uuid not null references public.churches(id) on delete cascade,
  service_id  uuid references public.services(id) on delete cascade,  -- null = all services
  class_id    uuid references public.classes(id)  on delete cascade,  -- null = all classes
  event_id    uuid references public.events(id)   on delete cascade,  -- null = all events
  name        text not null,
  color       text not null default '#6366f1',   -- hex color of the badge / button
  icon        text not null default 'phone',     -- lucide icon key (see src/lib/call-feedback.ts)
  sort_order  integer not null default 0,
  created_at  timestamptz not null default now(),
  created_by  uuid references public.profiles(id),
  edited_at   timestamptz not null default now(),
  edited_by   uuid references public.profiles(id),
  constraint call_feedbacks_color_hex check (color ~* '^#[0-9a-f]{6}$'),
  constraint call_feedbacks_name_len check (char_length(btrim(name)) between 1 and 60)
);

create index if not exists idx_call_feedbacks_church  on public.call_feedbacks(church_id);
create index if not exists idx_call_feedbacks_service on public.call_feedbacks(service_id);
create index if not exists idx_call_feedbacks_class   on public.call_feedbacks(class_id);
create index if not exists idx_call_feedbacks_event   on public.call_feedbacks(event_id);

drop trigger if exists trg_call_feedbacks_touch on public.call_feedbacks;
create trigger trg_call_feedbacks_touch before update on public.call_feedbacks
for each row execute function public.touch_edited();

-- The bound event (when given) must live inside the feedback's scope
create or replace function public.check_call_feedback_event_scope()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.event_id is not null then
    if not exists (
      select 1 from public.events ev
       where ev.id = new.event_id
         and ev.church_id = new.church_id
         and (ev.service_id is null or new.service_id is null or ev.service_id = new.service_id)
         and (ev.class_id   is null or new.class_id   is null or ev.class_id   = new.class_id)
    ) then
      raise exception 'event does not belong to the feedback scope';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists trg_call_feedback_event_scope on public.call_feedbacks;
create trigger trg_call_feedback_event_scope before insert or update on public.call_feedbacks
for each row execute function public.check_call_feedback_event_scope();

-- RLS — same rules as causes (0019): read what overlaps my scope, write
-- only inside my scope.
alter table public.call_feedbacks enable row level security;

drop policy if exists call_feedbacks_select on public.call_feedbacks;
create policy call_feedbacks_select on public.call_feedbacks for select using (
  (select public.scope_overlaps(church_id, service_id, class_id))
);
drop policy if exists call_feedbacks_insert on public.call_feedbacks;
create policy call_feedbacks_insert on public.call_feedbacks for insert with check (
  (select public.scope_contains(church_id, service_id, class_id))
);
drop policy if exists call_feedbacks_update on public.call_feedbacks;
create policy call_feedbacks_update on public.call_feedbacks for update using (
  (select public.scope_contains(church_id, service_id, class_id))
) with check (
  (select public.scope_contains(church_id, service_id, class_id))
);
drop policy if exists call_feedbacks_delete on public.call_feedbacks;
create policy call_feedbacks_delete on public.call_feedbacks for delete using (
  (select public.scope_contains(church_id, service_id, class_id))
);

-- ---------------------------------------------------------------------
-- 2. contact_log: the feedback + the occurrence day it refers to
-- ---------------------------------------------------------------------
alter table public.contact_log
  add column if not exists feedback_id uuid references public.call_feedbacks(id) on delete set null;
alter table public.contact_log
  add column if not exists occurrence_on date;   -- Cairo day of the event occurrence followed up

-- Badge lookup: latest feedback per (enrollment, event, occurrence)
create index if not exists idx_contact_log_feedback_lookup
  on public.contact_log(event_id, occurrence_on, enrollment_id, created_at desc)
  where feedback_id is not null;

-- Extend the scope trigger: the feedback must apply to the enrollment and
-- (when bound to an event) to the event of the row.
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

  if new.feedback_id is not null then
    if not exists (
      select 1
      from public.call_feedbacks fb
      join public.enrollments en on en.id = new.enrollment_id
      where fb.id = new.feedback_id
        and fb.church_id = en.church_id
        and (fb.service_id is null or fb.service_id = en.service_id)
        and (fb.class_id   is null or fb.class_id   = en.class_id)
        and (fb.event_id   is null or fb.event_id   = new.event_id)
    ) then
      raise exception 'feedback does not apply to the enrollment / event';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists trg_contact_event_scope on public.contact_log;
create trigger trg_contact_event_scope before insert on public.contact_log
for each row execute function public.check_contact_event_scope();

-- ---------------------------------------------------------------------
-- 3. REALTIME
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'call_feedbacks'
  ) then
    alter publication supabase_realtime add table public.call_feedbacks;
  end if;
end $$;
alter table public.call_feedbacks replica identity full;

analyze public.contact_log;

commit;
