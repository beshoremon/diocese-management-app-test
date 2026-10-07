-- =====================================================================
-- 0030: ONLINE CLASSES MODULE — الفصول الأونلاين (live-stream classes with
--       attention checks, live questions, live chat and AUTOMATIC attendance)
--
--   1. online_classes            — title, scope (church → service → class,
--                                  null = all), starts_at / ends_at, platform +
--                                  stream url (YouTube / Facebook / Zoom /
--                                  Google Meet / other), status scheduled |
--                                  live | ended | cancelled, chat toggle,
--                                  optional bound exam + bound event, and
--                                  the CONFIGURABLE ATTENDANCE RULES:
--                                    min_time_percent   — minimum presence (٪ of the live span)
--                                    checks_required    — attention checks the servant intends to send
--                                    checks_min_success — minimum successful checks
--                                    min_answers        — minimum live questions answered
--                                    check_seconds      — response window per check
--                                    attendance_points  — points given to present children
--   2. online_class_participants — one row per child (enrollment) who entered:
--                                  first join, last seen, cached presence
--                                  seconds, counters, FINAL result (present /
--                                  absent, percent, the attendance_log row).
--   3. online_class_sessions     — join / leave intervals (heartbeat-driven;
--                                  a gap > 90 s = left and came back).
--   4. online_class_checks       — attention checks sent by the servant
--      online_class_check_responses — who tapped, when, in time or late.
--   5. online_class_questions    — live questions (MCQ or free text) opened /
--                                  closed by the servant; correct MCQ answers
--                                  may grant points instantly.
--      online_class_answers
--   6. online_class_messages     — live chat (servants + children).
--   7. Servant RPCs              — online_class_start / end / finalize /
--                                  reopen / send_check / set_override /
--                                  live_stats.
--   8. Child RPCs (anon, token = national id, model of 0021) —
--                                  child_online_classes / join / heartbeat /
--                                  leave / check_respond / answer / chat_send.
--   9. child_portal_points learns source 'online'.
--
-- ATTENDANCE ALGORITHM (online_class_finalize):
--   presence% = clipped presence seconds / live span seconds
--   present ⇔ presence% ≥ min_time_percent
--          AND successful checks ≥ least(checks_min_success, checks actually sent)
--          AND answered questions ≥ min_answers
--   (a manual override per participant always wins). Present children get
--   ONE attendance_log row (bound event or none, points = attendance_points)
--   so the existing counters / badges / child portal see it instantly.
--
-- Idempotent — safe to re-run. Depends on 0019 (my_scope / enrollment_visible
-- / scope_overlaps / scope_contains), 0021 (child_portal_person), 0022
-- (points_log.event_id), 0024 (module_access / module_visible), 0027
-- (module_granted_for, exams), 0028 (child_portal_points shape).
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. TABLE: online_classes
-- ---------------------------------------------------------------------
create table if not exists public.online_classes (
  id                  uuid primary key default gen_random_uuid(),
  church_id           uuid not null references public.churches(id) on delete cascade,
  service_id          uuid references public.services(id) on delete cascade,   -- null = all services
  class_id            uuid references public.classes(id)  on delete cascade,   -- null = all classes
  title               text not null,
  description         text,
  starts_at           timestamptz not null,
  ends_at             timestamptz not null,
  platform            text not null default 'youtube'
                      check (platform in ('youtube', 'facebook', 'zoom', 'meet', 'other')),
  stream_url          text,
  status              text not null default 'scheduled'
                      check (status in ('scheduled', 'live', 'ended', 'cancelled')),
  started_at          timestamptz,
  ended_at            timestamptz,
  chat_enabled        boolean not null default true,
  exam_id             uuid references public.exams(id) on delete set null,
  event_id            uuid references public.events(id) on delete set null,
  -- attendance rules (configurable per class)
  min_time_percent    integer not null default 60 check (min_time_percent between 0 and 100),
  checks_required     integer not null default 3 check (checks_required between 0 and 100),
  checks_min_success  integer not null default 2 check (checks_min_success between 0 and 100),
  min_answers         integer not null default 0 check (min_answers between 0 and 100),
  check_seconds       integer not null default 60 check (check_seconds between 10 and 600),
  attendance_points   integer not null default 0 check (attendance_points between 0 and 1000),
  finalized_at        timestamptz,
  created_at          timestamptz not null default now(),
  created_by          uuid references public.profiles(id),
  edited_at           timestamptz not null default now(),
  edited_by           uuid references public.profiles(id),
  constraint online_classes_title_not_blank check (length(trim(title)) > 0),
  constraint online_classes_scope_chain check (not (class_id is not null and service_id is null)),
  constraint online_classes_window check (ends_at > starts_at),
  constraint online_classes_checks_rule check (checks_min_success <= checks_required)
);

comment on table public.online_classes is
  'الفصول الأونلاين — فصل ببث مباشر مقيد بنطاق كنيسة → خدمة → فصل، بقواعد حضور قابلة للتهيئة';

create index if not exists idx_online_classes_church  on public.online_classes(church_id);
create index if not exists idx_online_classes_service on public.online_classes(service_id);
create index if not exists idx_online_classes_class   on public.online_classes(class_id);
create index if not exists idx_online_classes_status  on public.online_classes(church_id, status, starts_at);
create index if not exists idx_online_classes_starts  on public.online_classes(starts_at desc);

drop trigger if exists trg_online_classes_touch on public.online_classes;
create trigger trg_online_classes_touch before update on public.online_classes
for each row execute function public.touch_edited();

create or replace function public.check_online_class_scope()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.title := trim(new.title);
  new.stream_url := nullif(trim(coalesce(new.stream_url, '')), '');
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
  -- the bound exam / event must cover the class scope (same church, and a
  -- scope that is not narrower than the class scope)
  if new.exam_id is not null and not exists (
    select 1 from public.exams x
     where x.id = new.exam_id and x.church_id = new.church_id
       and (x.service_id is null or x.service_id = new.service_id)
       and (x.class_id   is null or x.class_id   = new.class_id)
  ) then
    raise exception 'exam_out_of_scope';
  end if;
  if new.event_id is not null and not exists (
    select 1 from public.events ev
     where ev.id = new.event_id and ev.church_id = new.church_id
       and (ev.service_id is null or ev.service_id = new.service_id)
       and (ev.class_id   is null or ev.class_id   = new.class_id)
  ) then
    raise exception 'event_out_of_scope';
  end if;
  return new;
end $$;

drop trigger if exists trg_online_class_scope on public.online_classes;
create trigger trg_online_class_scope before insert or update on public.online_classes
for each row execute function public.check_online_class_scope();

-- ---------------------------------------------------------------------
-- 2. TABLE: online_class_participants (+ 3. sessions)
-- ---------------------------------------------------------------------
create table if not exists public.online_class_participants (
  id                  uuid primary key default gen_random_uuid(),
  class_id            uuid not null references public.online_classes(id) on delete cascade,
  enrollment_id       uuid not null references public.enrollments(id) on delete cascade,
  person_id           uuid not null references public.persons(id) on delete cascade,
  church_id           uuid not null references public.churches(id) on delete cascade,
  service_id          uuid not null references public.services(id) on delete cascade,
  room_class_id       uuid not null references public.classes(id)  on delete cascade,
  first_joined_at     timestamptz not null default now(),
  last_seen_at        timestamptz not null default now(),
  left_at             timestamptz,                    -- null = currently inside (subject to the 90 s heartbeat rule)
  total_seconds       integer not null default 0,     -- cached live presence (recomputed from sessions at finalize)
  sessions_count      integer not null default 1,
  checks_ok           integer not null default 0,
  checks_late         integer not null default 0,
  answers_count       integer not null default 0,
  correct_count       integer not null default 0,
  messages_count      integer not null default 0,
  -- final result
  final_status        text check (final_status in ('present', 'absent')),
  final_percent       numeric(5,2),
  final_checks_total  integer,
  override_status     text check (override_status in ('present', 'absent')),
  override_by         uuid references public.profiles(id),
  override_at         timestamptz,
  attendance_log_id   uuid references public.attendance_log(id) on delete set null,
  finalized_at        timestamptz,
  constraint uq_online_participant unique (class_id, enrollment_id)
);

comment on table public.online_class_participants is
  'الفصول الأونلاين — مخدوم دخل الفصل: أوقات الدخول، الحضور المحسوب، النتيجة النهائية';

create index if not exists idx_online_participants_class   on public.online_class_participants(class_id, first_joined_at);
create index if not exists idx_online_participants_person  on public.online_class_participants(person_id);
create index if not exists idx_online_participants_enroll  on public.online_class_participants(enrollment_id);
create index if not exists idx_online_participants_church  on public.online_class_participants(church_id);
create index if not exists idx_online_participants_service on public.online_class_participants(service_id);
create index if not exists idx_online_participants_room    on public.online_class_participants(room_class_id);
create index if not exists idx_online_participants_attlog  on public.online_class_participants(attendance_log_id);

create table if not exists public.online_class_sessions (
  id              uuid primary key default gen_random_uuid(),
  participant_id  uuid not null references public.online_class_participants(id) on delete cascade,
  class_id        uuid not null references public.online_classes(id) on delete cascade,
  joined_at       timestamptz not null default now(),
  last_seen_at    timestamptz not null default now(),
  left_at         timestamptz
);
create index if not exists idx_online_sessions_participant on public.online_class_sessions(participant_id, joined_at);
create index if not exists idx_online_sessions_class       on public.online_class_sessions(class_id);
create unique index if not exists uq_online_sessions_open
  on public.online_class_sessions(participant_id) where left_at is null;

-- ---------------------------------------------------------------------
-- 4. TABLES: attention checks + responses
-- ---------------------------------------------------------------------
create table if not exists public.online_class_checks (
  id          uuid primary key default gen_random_uuid(),
  class_id    uuid not null references public.online_classes(id) on delete cascade,
  seq         integer not null default 1,
  prompt      text,
  sent_at     timestamptz not null default now(),
  expires_at  timestamptz not null,
  sent_by     uuid references public.profiles(id),
  constraint online_checks_window check (expires_at > sent_at)
);
create index if not exists idx_online_checks_class on public.online_class_checks(class_id, sent_at);

create table if not exists public.online_class_check_responses (
  id              uuid primary key default gen_random_uuid(),
  check_id        uuid not null references public.online_class_checks(id) on delete cascade,
  class_id        uuid not null references public.online_classes(id) on delete cascade,
  participant_id  uuid not null references public.online_class_participants(id) on delete cascade,
  responded_at    timestamptz not null default now(),
  ok              boolean not null default true,          -- within the window
  latency_ms      integer,
  constraint uq_online_check_response unique (check_id, participant_id)
);
create index if not exists idx_online_check_responses_class on public.online_class_check_responses(class_id);
create index if not exists idx_online_check_responses_part  on public.online_class_check_responses(participant_id);

-- ---------------------------------------------------------------------
-- 5. TABLES: live questions + answers
-- ---------------------------------------------------------------------
create table if not exists public.online_class_questions (
  id            uuid primary key default gen_random_uuid(),
  class_id      uuid not null references public.online_classes(id) on delete cascade,
  sort_order    integer not null default 0,
  text          text not null,
  options       jsonb,                                   -- null = free text; else 2..6 strings
  correct_index integer,                                 -- null = no auto-grading
  points        integer not null default 0 check (points between 0 and 1000),
  status        text not null default 'draft' check (status in ('draft', 'open', 'closed')),
  opened_at     timestamptz,
  closed_at     timestamptz,
  created_at    timestamptz not null default now(),
  created_by    uuid references public.profiles(id),
  constraint online_questions_text_not_blank check (length(trim(text)) > 0)
);
create index if not exists idx_online_questions_class on public.online_class_questions(class_id, sort_order, created_at);

create or replace function public.check_online_question()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  n integer;
  i integer;
begin
  new.text := trim(new.text);
  if new.options is not null then
    if jsonb_typeof(new.options) <> 'array' then
      raise exception 'options_must_be_array';
    end if;
    n := jsonb_array_length(new.options);
    if n < 2 or n > 6 then
      raise exception 'options_count_out_of_range';
    end if;
    for i in 0 .. n - 1 loop
      if jsonb_typeof(new.options -> i) <> 'string' or length(trim(new.options ->> i)) = 0 then
        raise exception 'option_blank:%', i + 1;
      end if;
    end loop;
    if new.correct_index is not null and (new.correct_index < 0 or new.correct_index >= n) then
      raise exception 'correct_index_out_of_range';
    end if;
  else
    new.correct_index := null;
  end if;
  if new.status = 'open' and new.opened_at is null then new.opened_at := now(); end if;
  if new.status = 'closed' and new.closed_at is null then new.closed_at := now(); end if;
  return new;
end $$;

drop trigger if exists trg_online_question_check on public.online_class_questions;
create trigger trg_online_question_check before insert or update on public.online_class_questions
for each row execute function public.check_online_question();

create table if not exists public.online_class_answers (
  id              uuid primary key default gen_random_uuid(),
  question_id     uuid not null references public.online_class_questions(id) on delete cascade,
  class_id        uuid not null references public.online_classes(id) on delete cascade,
  participant_id  uuid not null references public.online_class_participants(id) on delete cascade,
  selected_index  integer,
  answer_text     text,
  is_correct      boolean,
  points_granted  integer not null default 0,
  points_log_id   uuid references public.points_log(id) on delete set null,
  answered_at     timestamptz not null default now(),
  constraint uq_online_answer unique (question_id, participant_id)
);
create index if not exists idx_online_answers_class    on public.online_class_answers(class_id);
create index if not exists idx_online_answers_question on public.online_class_answers(question_id);
create index if not exists idx_online_answers_part     on public.online_class_answers(participant_id);

-- ---------------------------------------------------------------------
-- 6. TABLE: live chat
-- ---------------------------------------------------------------------
create table if not exists public.online_class_messages (
  id                 uuid primary key default gen_random_uuid(),
  class_id           uuid not null references public.online_classes(id) on delete cascade,
  sender_profile_id  uuid references public.profiles(id) on delete set null,
  sender_participant_id uuid references public.online_class_participants(id) on delete cascade,
  body               text not null,
  created_at         timestamptz not null default now(),
  constraint online_messages_body check (length(trim(body)) between 1 and 1000),
  constraint online_messages_one_sender check (
    (sender_profile_id is not null)::int + (sender_participant_id is not null)::int = 1
  )
);
create index if not exists idx_online_messages_class on public.online_class_messages(class_id, created_at desc);

-- ---------------------------------------------------------------------
-- RLS — everything requires module_visible('online')
-- ---------------------------------------------------------------------
alter table public.online_classes                 enable row level security;
alter table public.online_class_participants      enable row level security;
alter table public.online_class_sessions          enable row level security;
alter table public.online_class_checks            enable row level security;
alter table public.online_class_check_responses   enable row level security;
alter table public.online_class_questions         enable row level security;
alter table public.online_class_answers           enable row level security;
alter table public.online_class_messages          enable row level security;

drop policy if exists online_classes_select on public.online_classes;
create policy online_classes_select on public.online_classes for select using (
  (select public.module_visible('online'))
  and (select public.scope_overlaps(church_id, service_id, class_id))
);
drop policy if exists online_classes_insert on public.online_classes;
create policy online_classes_insert on public.online_classes for insert with check (
  (select public.module_visible('online'))
  and (select public.scope_contains(church_id, service_id, class_id))
);
drop policy if exists online_classes_update on public.online_classes;
create policy online_classes_update on public.online_classes for update using (
  (select public.module_visible('online'))
  and (select public.scope_contains(church_id, service_id, class_id))
) with check (
  (select public.module_visible('online'))
  and (select public.scope_contains(church_id, service_id, class_id))
);
drop policy if exists online_classes_delete on public.online_classes;
create policy online_classes_delete on public.online_classes for delete using (
  (select public.module_visible('online'))
  and (select public.scope_contains(church_id, service_id, class_id))
);

-- helper predicates (InitPlan pattern): can I SEE / WRITE this class?
create or replace function public.online_class_readable(p_class uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.online_classes c
     where c.id = p_class
       and public.module_visible('online')
       and public.scope_overlaps(c.church_id, c.service_id, c.class_id)
  )
$$;
create or replace function public.online_class_writable(p_class uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.online_classes c
     where c.id = p_class
       and public.module_visible('online')
       and public.scope_contains(c.church_id, c.service_id, c.class_id)
  )
$$;

-- participants / sessions / responses / answers: read-only via the API
drop policy if exists online_participants_select on public.online_class_participants;
create policy online_participants_select on public.online_class_participants for select using (
  public.online_class_readable(class_id)
);
drop policy if exists online_sessions_select on public.online_class_sessions;
create policy online_sessions_select on public.online_class_sessions for select using (
  public.online_class_readable(class_id)
);
drop policy if exists online_check_responses_select on public.online_class_check_responses;
create policy online_check_responses_select on public.online_class_check_responses for select using (
  public.online_class_readable(class_id)
);
drop policy if exists online_answers_select on public.online_class_answers;
create policy online_answers_select on public.online_class_answers for select using (
  public.online_class_readable(class_id)
);

-- checks: read if class readable; write only through online_class_send_check (RPC); delete by writers
drop policy if exists online_checks_select on public.online_class_checks;
create policy online_checks_select on public.online_class_checks for select using (
  public.online_class_readable(class_id)
);
drop policy if exists online_checks_delete on public.online_class_checks;
create policy online_checks_delete on public.online_class_checks for delete using (
  public.online_class_writable(class_id)
);

-- questions: full CRUD for writers of the class
drop policy if exists online_questions_select on public.online_class_questions;
create policy online_questions_select on public.online_class_questions for select using (
  public.online_class_readable(class_id)
);
drop policy if exists online_questions_insert on public.online_class_questions;
create policy online_questions_insert on public.online_class_questions for insert with check (
  public.online_class_writable(class_id)
);
drop policy if exists online_questions_update on public.online_class_questions;
create policy online_questions_update on public.online_class_questions for update using (
  public.online_class_writable(class_id)
) with check (
  public.online_class_writable(class_id)
);
drop policy if exists online_questions_delete on public.online_class_questions;
create policy online_questions_delete on public.online_class_questions for delete using (
  public.online_class_writable(class_id)
);

-- chat: every servant who can see the class may read + write as himself; writers may delete
drop policy if exists online_messages_select on public.online_class_messages;
create policy online_messages_select on public.online_class_messages for select using (
  public.online_class_readable(class_id)
);
drop policy if exists online_messages_insert on public.online_class_messages;
create policy online_messages_insert on public.online_class_messages for insert with check (
  sender_profile_id = auth.uid() and sender_participant_id is null
  and public.online_class_readable(class_id)
);
drop policy if exists online_messages_delete on public.online_class_messages;
create policy online_messages_delete on public.online_class_messages for delete using (
  sender_profile_id = auth.uid() or public.online_class_writable(class_id)
);

-- ---------------------------------------------------------------------
-- INTERNAL HELPERS
-- ---------------------------------------------------------------------

-- presence seconds of a participant clipped to [p_from, p_to]
create or replace function public.online_presence_seconds(p_participant uuid, p_from timestamptz, p_to timestamptz)
returns integer language sql stable security definer set search_path = public as $$
  select coalesce(sum(
           greatest(0, extract(epoch from (
             least(coalesce(s.left_at, s.last_seen_at), p_to) - greatest(s.joined_at, p_from)
           )))
         ), 0)::integer
    from public.online_class_sessions s
   where s.participant_id = p_participant
$$;
revoke all on function public.online_presence_seconds(uuid, timestamptz, timestamptz) from public, anon, authenticated;

-- the live span used for presence: started_at → (ended_at | now)
create or replace function public.online_class_span(c public.online_classes, out p_from timestamptz, out p_to timestamptz, out p_seconds integer)
language plpgsql stable security definer set search_path = public as $$
begin
  p_from := coalesce(c.started_at, c.starts_at);
  p_to   := coalesce(c.ended_at, case when c.status = 'live' then now() else c.ends_at end);
  if p_to < p_from then p_to := p_from; end if;
  p_seconds := greatest(1, extract(epoch from (p_to - p_from))::integer);
end $$;
revoke all on function public.online_class_span(public.online_classes) from public, anon, authenticated;

-- evaluate the rules for one participant (no writes)
create or replace function public.online_evaluate(c public.online_classes, pt public.online_class_participants,
                                                  out o_seconds integer, out o_percent numeric,
                                                  out o_checks_total integer, out o_rule_present boolean,
                                                  out o_status text)
language plpgsql stable security definer set search_path = public as $$
declare
  v_from timestamptz; v_to timestamptz; v_span integer;
  v_need integer;
begin
  select * into v_from, v_to, v_span from public.online_class_span(c);
  o_seconds := public.online_presence_seconds(pt.id, v_from, v_to);
  o_percent := least(100, round(o_seconds * 100.0 / v_span, 2));
  select count(*) into o_checks_total from public.online_class_checks k where k.class_id = c.id;
  v_need := least(c.checks_min_success, o_checks_total);
  o_rule_present := o_percent >= c.min_time_percent
                    and pt.checks_ok >= v_need
                    and pt.answers_count >= c.min_answers;
  o_status := coalesce(pt.override_status, case when o_rule_present then 'present' else 'absent' end);
end $$;
revoke all on function public.online_evaluate(public.online_classes, public.online_class_participants) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 7. SERVANT RPCs
-- ---------------------------------------------------------------------
create or replace function public.online_assert_writer(p_class uuid)
returns public.online_classes language plpgsql stable security definer set search_path = public as $$
declare
  c public.online_classes;
begin
  if auth.uid() is null then
    raise exception 'forbidden' using errcode = 'P0001';
  end if;
  if not public.module_visible('online') then
    raise exception 'module_not_visible' using errcode = 'P0001';
  end if;
  select * into c from public.online_classes where id = p_class;
  if not found then
    raise exception 'class_not_found' using errcode = 'P0002';
  end if;
  if not public.scope_contains(c.church_id, c.service_id, c.class_id) then
    raise exception 'forbidden' using errcode = 'P0001';
  end if;
  return c;
end $$;
revoke all on function public.online_assert_writer(uuid) from public, anon, authenticated;

-- START the class (scheduled → live). Reopening an ended class uses online_class_reopen.
create or replace function public.online_class_start(p_class uuid)
returns public.online_classes language plpgsql volatile security definer set search_path = public as $$
declare
  c public.online_classes;
begin
  c := public.online_assert_writer(p_class);
  if c.status = 'live' then return c; end if;
  if c.status <> 'scheduled' then
    raise exception 'class_not_scheduled' using errcode = 'P0001';
  end if;
  update public.online_classes
     set status = 'live', started_at = now(), ended_at = null, edited_by = auth.uid()
   where id = c.id returning * into c;
  return c;
end $$;
grant execute on function public.online_class_start(uuid) to authenticated;

-- FINALIZE: compute every participant's result and write the attendance rows.
-- Idempotent: re-running recomputes; rows already written are kept / removed
-- according to the new status.
create or replace function public.online_class_finalize(p_class uuid)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  c   public.online_classes;
  pt  public.online_class_participants;
  ev  record;
  v_present integer := 0;
  v_absent  integer := 0;
  v_day     date;
  v_al      uuid;
begin
  c := public.online_assert_writer(p_class);
  if c.status not in ('live', 'ended') then
    raise exception 'class_not_started' using errcode = 'P0001';
  end if;
  if c.ended_at is null then
    update public.online_classes set ended_at = now() where id = c.id returning * into c;
  end if;
  v_day := (coalesce(c.started_at, c.starts_at) at time zone 'Africa/Cairo')::date;

  -- close every open session at the end of the class
  update public.online_class_sessions s
     set left_at = least(greatest(s.last_seen_at, s.joined_at), c.ended_at)
   where s.class_id = c.id and s.left_at is null;
  update public.online_class_participants set left_at = coalesce(left_at, c.ended_at) where class_id = c.id;

  for pt in select * from public.online_class_participants where class_id = c.id for update loop
    select * into ev from public.online_evaluate(c, pt);
    v_al := pt.attendance_log_id;
    if ev.o_status = 'present' then
      v_present := v_present + 1;
      if v_al is null or not exists (select 1 from public.attendance_log where id = v_al) then
        -- one attendance per enrollment per event per day (partial unique index)
        if c.event_id is not null and exists (
          select 1 from public.attendance_log a
           where a.enrollment_id = pt.enrollment_id and a.event_id = c.event_id and a.attended_on = v_day
        ) then
          select a.id into v_al from public.attendance_log a
           where a.enrollment_id = pt.enrollment_id and a.event_id = c.event_id and a.attended_on = v_day limit 1;
        else
          insert into public.attendance_log (enrollment_id, event_id, points_delta, recorded_by, attended_on)
          values (pt.enrollment_id, c.event_id, c.attendance_points, auth.uid(), v_day)
          returning id into v_al;
        end if;
      end if;
    else
      v_absent := v_absent + 1;
      if v_al is not null then
        delete from public.attendance_log where id = v_al;   -- trigger reverts the counters
        v_al := null;
      end if;
    end if;
    update public.online_class_participants
       set total_seconds = ev.o_seconds, final_percent = ev.o_percent, final_checks_total = ev.o_checks_total,
           final_status = ev.o_status, attendance_log_id = v_al, finalized_at = now()
     where id = pt.id;
  end loop;

  update public.online_classes
     set status = 'ended', finalized_at = now(), edited_by = auth.uid()
   where id = c.id;
  return jsonb_build_object('class_id', c.id, 'present', v_present, 'absent', v_absent, 'ended_at', c.ended_at);
end $$;
grant execute on function public.online_class_finalize(uuid) to authenticated;

-- END the class = stop the stream + finalize attendance in one go
create or replace function public.online_class_end(p_class uuid)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  c public.online_classes;
begin
  c := public.online_assert_writer(p_class);
  if c.status <> 'live' then
    raise exception 'class_not_live' using errcode = 'P0001';
  end if;
  update public.online_classes set ended_at = now() where id = c.id;
  return public.online_class_finalize(c.id);
end $$;
grant execute on function public.online_class_end(uuid) to authenticated;

-- REOPEN an ended class: removes the attendance rows it wrote and goes live again
create or replace function public.online_class_reopen(p_class uuid)
returns public.online_classes language plpgsql volatile security definer set search_path = public as $$
declare
  c public.online_classes;
begin
  c := public.online_assert_writer(p_class);
  if c.status <> 'ended' then
    raise exception 'class_not_ended' using errcode = 'P0001';
  end if;
  delete from public.attendance_log a
   using public.online_class_participants p
   where p.class_id = c.id and p.attendance_log_id = a.id;
  update public.online_class_participants
     set final_status = null, final_percent = null, final_checks_total = null,
         attendance_log_id = null, finalized_at = null
   where class_id = c.id;
  update public.online_classes
     set status = 'live', ended_at = null, finalized_at = null, edited_by = auth.uid()
   where id = c.id returning * into c;
  return c;
end $$;
grant execute on function public.online_class_reopen(uuid) to authenticated;

-- SEND an attention check (window = p_seconds or the class default)
create or replace function public.online_class_send_check(p_class uuid, p_prompt text default null, p_seconds integer default null)
returns public.online_class_checks language plpgsql volatile security definer set search_path = public as $$
declare
  c   public.online_classes;
  k   public.online_class_checks;
  v_s integer;
  v_seq integer;
begin
  c := public.online_assert_writer(p_class);
  if c.status <> 'live' then
    raise exception 'class_not_live' using errcode = 'P0001';
  end if;
  v_s := coalesce(p_seconds, c.check_seconds);
  if v_s < 10 or v_s > 600 then
    raise exception 'invalid_seconds' using errcode = 'P0001';
  end if;
  select coalesce(max(seq), 0) + 1 into v_seq from public.online_class_checks where class_id = c.id;
  insert into public.online_class_checks (class_id, seq, prompt, sent_at, expires_at, sent_by)
  values (c.id, v_seq, nullif(trim(coalesce(p_prompt, '')), ''), now(), now() + make_interval(secs => v_s), auth.uid())
  returning * into k;
  return k;
end $$;
grant execute on function public.online_class_send_check(uuid, text, integer) to authenticated;

-- MANUAL OVERRIDE of one participant (null = back to the rules). Re-finalizes
-- if the class already ended so the attendance rows follow.
create or replace function public.online_class_set_override(p_participant uuid, p_status text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  pt public.online_class_participants;
  c  public.online_classes;
begin
  select * into pt from public.online_class_participants where id = p_participant;
  if not found then
    raise exception 'participant_not_found' using errcode = 'P0002';
  end if;
  c := public.online_assert_writer(pt.class_id);
  if p_status is not null and p_status not in ('present', 'absent') then
    raise exception 'invalid_status' using errcode = 'P0001';
  end if;
  update public.online_class_participants
     set override_status = p_status,
         override_by = case when p_status is null then null else auth.uid() end,
         override_at = case when p_status is null then null else now() end
   where id = pt.id;
  if c.status = 'ended' then
    return public.online_class_finalize(c.id);
  end if;
  return jsonb_build_object('class_id', c.id, 'participant_id', pt.id, 'override', p_status);
end $$;
grant execute on function public.online_class_set_override(uuid, text) to authenticated;

-- LIVE STATS for the control room: every participant evaluated NOW against
-- the rules (so the servant sees who would be present if the class ended
-- this second) + totals.
create or replace function public.online_class_live_stats(p_class uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  c   public.online_classes;
  s   record;
  v_from timestamptz; v_to timestamptz; v_span integer;
  v_rows jsonb;
  v_checks integer;
begin
  if auth.uid() is null or not public.module_visible('online') then
    raise exception 'forbidden' using errcode = 'P0001';
  end if;
  select * into c from public.online_classes where id = p_class;
  if not found then
    raise exception 'class_not_found' using errcode = 'P0002';
  end if;
  if not public.scope_overlaps(c.church_id, c.service_id, c.class_id) then
    raise exception 'forbidden' using errcode = 'P0001';
  end if;
  select * into v_from, v_to, v_span from public.online_class_span(c);
  select count(*) into v_checks from public.online_class_checks where class_id = c.id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'participant_id', pt.id,
           'enrollment_id', pt.enrollment_id,
           'person_id', pt.person_id,
           'name', p.name,
           'image_url', p.image_url,
           'national_id', p.national_id,
           'class_name', cl.name,
           'first_joined_at', pt.first_joined_at,
           'last_seen_at', pt.last_seen_at,
           'left_at', pt.left_at,
           'online', (pt.left_at is null and pt.last_seen_at >= now() - interval '90 seconds' and c.status = 'live'),
           'sessions_count', pt.sessions_count,
           'seconds', e.o_seconds,
           'percent', e.o_percent,
           'checks_ok', pt.checks_ok,
           'checks_late', pt.checks_late,
           'checks_total', e.o_checks_total,
           'answers_count', pt.answers_count,
           'correct_count', pt.correct_count,
           'messages_count', pt.messages_count,
           'rule_present', e.o_rule_present,
           'status', e.o_status,
           'override_status', pt.override_status,
           'final_status', pt.final_status,
           'attendance_log_id', pt.attendance_log_id
         ) order by p.name), '[]'::jsonb)
    into v_rows
    from public.online_class_participants pt
    join public.persons p on p.id = pt.person_id
    join public.classes cl on cl.id = pt.room_class_id
    cross join lateral public.online_evaluate(c, pt) e
   where pt.class_id = c.id;

  return jsonb_build_object(
    'class_id', c.id,
    'status', c.status,
    'span_from', v_from, 'span_to', v_to, 'span_seconds', v_span,
    'checks_sent', v_checks,
    'server_now', now(),
    'participants', v_rows,
    'totals', jsonb_build_object(
      'entered', jsonb_array_length(v_rows),
      'online', (select count(*) from jsonb_array_elements(v_rows) r where (r->>'online')::boolean),
      'present', (select count(*) from jsonb_array_elements(v_rows) r where r->>'status' = 'present'),
      'absent',  (select count(*) from jsonb_array_elements(v_rows) r where r->>'status' = 'absent'),
      'eligible', (select count(*) from public.enrollments en
                    where en.church_id = c.church_id
                      and (c.service_id is null or en.service_id = c.service_id)
                      and (c.class_id is null or en.class_id = c.class_id))
    )
  );
end $$;
grant execute on function public.online_class_live_stats(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 8. CHILD RPCs (anon — token = scanned national id, model of 0021)
-- ---------------------------------------------------------------------

-- the participant row of this child in this class (or null)
create or replace function public.online_child_participant(p_person uuid, p_class uuid)
returns public.online_class_participants language sql stable security definer set search_path = public as $$
  select * from public.online_class_participants where class_id = p_class and person_id = p_person limit 1
$$;
revoke all on function public.online_child_participant(uuid, uuid) from public, anon, authenticated;

-- what one class looks like to the child (card + room payload)
create or replace function public.online_class_child_payload(c public.online_classes, e public.enrollments, pt public.online_class_participants)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  res jsonb;
  ev record;
  k public.online_class_checks;
  v_open_q jsonb;
begin
  res := jsonb_build_object(
    'id', c.id, 'title', c.title, 'description', c.description,
    'starts_at', c.starts_at, 'ends_at', c.ends_at,
    'platform', c.platform, 'stream_url', c.stream_url,
    'status', c.status, 'started_at', c.started_at, 'ended_at', c.ended_at,
    'chat_enabled', c.chat_enabled, 'exam_id', c.exam_id,
    'exam_title', (select x.title from public.exams x where x.id = c.exam_id and x.status = 'published'),
    'event_name', (select ev2.name from public.events ev2 where ev2.id = c.event_id),
    'min_time_percent', c.min_time_percent, 'checks_required', c.checks_required,
    'checks_min_success', c.checks_min_success, 'min_answers', c.min_answers,
    'check_seconds', c.check_seconds, 'attendance_points', c.attendance_points,
    'teacher_name', (select pr.full_name from public.profiles pr where pr.id = c.created_by),
    'enrollment_id', e.id,
    'class_name', (select cl.name from public.classes cl where cl.id = e.class_id),
    'service_name', (select sv.name from public.services sv where sv.id = e.service_id),
    'server_now', now(),
    'participant', null
  );
  if pt.id is not null then
    select * into ev from public.online_evaluate(c, pt);
    res := res || jsonb_build_object('participant', jsonb_build_object(
      'id', pt.id,
      'first_joined_at', pt.first_joined_at,
      'last_seen_at', pt.last_seen_at,
      'left_at', pt.left_at,
      'seconds', ev.o_seconds,
      'percent', ev.o_percent,
      'checks_ok', pt.checks_ok,
      'checks_late', pt.checks_late,
      'checks_total', ev.o_checks_total,
      'answers_count', pt.answers_count,
      'correct_count', pt.correct_count,
      'final_status', pt.final_status,
      'final_percent', pt.final_percent,
      'live_status', case when c.status = 'ended' then pt.final_status else ev.o_status end
    ));
    -- pending attention check (sent, still open, not yet answered)
    select k2.* into k from public.online_class_checks k2
     where k2.class_id = c.id and k2.expires_at > now()
       and not exists (select 1 from public.online_class_check_responses r where r.check_id = k2.id and r.participant_id = pt.id)
     order by k2.sent_at desc limit 1;
    if found then
      res := res || jsonb_build_object('pending_check', jsonb_build_object(
        'id', k.id, 'seq', k.seq, 'prompt', k.prompt, 'sent_at', k.sent_at, 'expires_at', k.expires_at));
    else
      res := res || jsonb_build_object('pending_check', null);
    end if;
    -- open questions (with my answer if any)
    select coalesce(jsonb_agg(jsonb_build_object(
             'id', q.id, 'text', q.text, 'options', q.options, 'points', q.points, 'status', q.status,
             'opened_at', q.opened_at, 'closed_at', q.closed_at,
             'my_answer', case when a.id is null then null else jsonb_build_object(
               'selected_index', a.selected_index, 'answer_text', a.answer_text,
               'is_correct', a.is_correct, 'points_granted', a.points_granted, 'answered_at', a.answered_at) end,
             'correct_index', case when q.status = 'closed' then q.correct_index else null end
           ) order by q.opened_at nulls last, q.sort_order), '[]'::jsonb)
      into v_open_q
      from public.online_class_questions q
      left join public.online_class_answers a on a.question_id = q.id and a.participant_id = pt.id
     where q.class_id = c.id and q.status in ('open', 'closed');
    res := res || jsonb_build_object('questions', v_open_q);
  end if;
  return res;
end $$;
revoke all on function public.online_class_child_payload(public.online_classes, public.enrollments, public.online_class_participants) from public, anon, authenticated;

-- LIST — upcoming / live / recent (last 30 days) classes for the child's scope
create or replace function public.child_online_classes(p_national_id text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  p public.persons;
  res jsonb;
begin
  p := public.child_portal_person(p_national_id);
  select coalesce(jsonb_agg(public.online_class_child_payload(c, e, pt)
           order by case c.status when 'live' then 0 when 'scheduled' then 1 else 2 end,
                    case when c.status = 'scheduled' then c.starts_at end asc,
                    c.starts_at desc), '[]'::jsonb)
    into res
    from public.enrollments e
    join public.online_classes c
      on c.church_id = e.church_id
     and (c.service_id is null or c.service_id = e.service_id)
     and (c.class_id   is null or c.class_id   = e.class_id)
    left join public.online_class_participants pt on pt.class_id = c.id and pt.person_id = p.id
   where e.person_id = p.id
     and c.status <> 'cancelled'
     and public.module_granted_for('online', e.church_id, e.service_id, e.class_id)
     and (c.status in ('scheduled', 'live') or c.ends_at >= now() - interval '30 days');
  return res;
end $$;
grant execute on function public.child_online_classes(text) to anon, authenticated;

-- resolve class + the enrollment that covers it + module check
create or replace function public.online_child_class(p_class uuid)
returns public.online_classes language plpgsql stable security definer set search_path = public as $$
declare c public.online_classes;
begin
  select * into c from public.online_classes where id = p_class;
  if not found then
    raise exception 'class_not_found' using errcode = 'P0002';
  end if;
  return c;
end $$;
revoke all on function public.online_child_class(uuid) from public, anon, authenticated;

create or replace function public.online_child_enrollment(p_person uuid, c public.online_classes)
returns public.enrollments language plpgsql stable security definer set search_path = public as $$
declare e public.enrollments;
begin
  select en.* into e from public.enrollments en
   where en.person_id = p_person
     and c.church_id = en.church_id
     and (c.service_id is null or c.service_id = en.service_id)
     and (c.class_id   is null or c.class_id   = en.class_id)
   order by en.created_at limit 1;
  if not found then
    raise exception 'class_out_of_scope' using errcode = 'P0001';
  end if;
  if not public.module_granted_for('online', e.church_id, e.service_id, e.class_id) then
    raise exception 'module_not_visible' using errcode = 'P0001';
  end if;
  return e;
end $$;
revoke all on function public.online_child_enrollment(uuid, public.online_classes) from public, anon, authenticated;

-- ROOM — the class payload for the live page (no side effects)
create or replace function public.child_online_class(p_national_id text, p_class uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  p public.persons;
  rc public.online_classes;
  re public.enrollments;
  pt public.online_class_participants;
begin
  p := public.child_portal_person(p_national_id);
  rc := public.online_child_class(p_class);
  re := public.online_child_enrollment(p.id, rc);
  pt := public.online_child_participant(p.id, p_class);
  return public.online_class_child_payload(rc, re, pt);
end $$;
grant execute on function public.child_online_class(text, uuid) to anon, authenticated;

-- JOIN — records the join timestamp (first time) and opens a session
create or replace function public.child_online_join(p_national_id text, p_class uuid)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  p  public.persons;
  rc public.online_classes;
  re public.enrollments;
  pt public.online_class_participants;
begin
  p := public.child_portal_person(p_national_id);
  rc := public.online_child_class(p_class);
  re := public.online_child_enrollment(p.id, rc);
  if rc.status <> 'live' then
    raise exception 'class_not_live' using errcode = 'P0001';
  end if;
  select * into pt from public.online_class_participants
   where class_id = p_class and enrollment_id = re.id for update;
  if not found then
    insert into public.online_class_participants (class_id, enrollment_id, person_id, church_id, service_id, room_class_id)
    values (p_class, re.id, p.id, re.church_id, re.service_id, re.class_id)
    on conflict (class_id, enrollment_id) do update set last_seen_at = now()
    returning * into pt;
    insert into public.online_class_sessions (participant_id, class_id) values (pt.id, p_class);
  else
    -- reopen: close a stale open session (if any) then open a fresh one
    if not exists (select 1 from public.online_class_sessions s where s.participant_id = pt.id and s.left_at is null
                     and s.last_seen_at >= now() - interval '90 seconds') then
      update public.online_class_sessions set left_at = last_seen_at where participant_id = pt.id and left_at is null;
      insert into public.online_class_sessions (participant_id, class_id) values (pt.id, p_class);
      update public.online_class_participants set sessions_count = sessions_count + 1 where id = pt.id;
    end if;
    update public.online_class_participants set last_seen_at = now(), left_at = null where id = pt.id returning * into pt;
  end if;
  return public.online_class_child_payload(rc, re, pt);
end $$;
grant execute on function public.child_online_join(text, uuid) to anon, authenticated;

-- HEARTBEAT — every ~30 s while the room is open; extends the current
-- session. A gap > 90 s means the child left; the next heartbeat reopens.
create or replace function public.child_online_heartbeat(p_national_id text, p_class uuid)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  p  public.persons;
  rc public.online_classes;
  re public.enrollments;
  pt public.online_class_participants;
  s  public.online_class_sessions;
begin
  p := public.child_portal_person(p_national_id);
  rc := public.online_child_class(p_class);
  re := public.online_child_enrollment(p.id, rc);
  pt := public.online_child_participant(p.id, p_class);
  if pt.id is null then
    raise exception 'not_joined' using errcode = 'P0001';
  end if;
  if rc.status = 'live' then
    select * into s from public.online_class_sessions where participant_id = pt.id and left_at is null for update;
    if found and s.last_seen_at >= now() - interval '90 seconds' then
      update public.online_class_sessions set last_seen_at = now() where id = s.id;
    else
      if found then update public.online_class_sessions set left_at = last_seen_at where id = s.id; end if;
      insert into public.online_class_sessions (participant_id, class_id) values (pt.id, p_class);
      update public.online_class_participants set sessions_count = sessions_count + 1 where id = pt.id;
    end if;
    update public.online_class_participants
       set last_seen_at = now(), left_at = null,
           total_seconds = public.online_presence_seconds(pt.id, coalesce(rc.started_at, rc.starts_at), now())
     where id = pt.id returning * into pt;
  end if;
  return public.online_class_child_payload(rc, re, pt);
end $$;
grant execute on function public.child_online_heartbeat(text, uuid) to anon, authenticated;

-- LEAVE — explicit exit (closing the room)
create or replace function public.child_online_leave(p_national_id text, p_class uuid)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  p  public.persons;
  rc public.online_classes;
  re public.enrollments;
  pt public.online_class_participants;
begin
  p := public.child_portal_person(p_national_id);
  rc := public.online_child_class(p_class);
  re := public.online_child_enrollment(p.id, rc);
  pt := public.online_child_participant(p.id, p_class);
  if pt.id is null then
    return public.online_class_child_payload(rc, re, pt);
  end if;
  update public.online_class_sessions set last_seen_at = now(), left_at = now() where participant_id = pt.id and left_at is null;
  update public.online_class_participants
     set left_at = now(), last_seen_at = now(),
         total_seconds = public.online_presence_seconds(pt.id, coalesce(rc.started_at, rc.starts_at), now())
   where id = pt.id returning * into pt;
  return public.online_class_child_payload(rc, re, pt);
end $$;
grant execute on function public.child_online_leave(text, uuid) to anon, authenticated;

-- RESPOND to an attention check (ok = within the window; late is recorded but doesn't count)
create or replace function public.child_online_check_respond(p_national_id text, p_check uuid)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  p  public.persons;
  k  public.online_class_checks;
  rc public.online_classes;
  re public.enrollments;
  pt public.online_class_participants;
  v_ok boolean;
  grace constant interval := interval '5 seconds';
begin
  p := public.child_portal_person(p_national_id);
  select * into k from public.online_class_checks where id = p_check;
  if not found then
    raise exception 'check_not_found' using errcode = 'P0002';
  end if;
  rc := public.online_child_class(k.class_id);
  re := public.online_child_enrollment(p.id, rc);
  pt := public.online_child_participant(p.id, k.class_id);
  if pt.id is null then
    raise exception 'not_joined' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.online_class_check_responses where check_id = k.id and participant_id = pt.id) then
    return public.online_class_child_payload(rc, re, pt);   -- idempotent
  end if;
  v_ok := now() <= k.expires_at + grace;
  insert into public.online_class_check_responses (check_id, class_id, participant_id, ok, latency_ms)
  values (k.id, k.class_id, pt.id, v_ok, (extract(epoch from now() - k.sent_at) * 1000)::integer);
  update public.online_class_participants
     set checks_ok = checks_ok + case when v_ok then 1 else 0 end,
         checks_late = checks_late + case when v_ok then 0 else 1 end,
         last_seen_at = now(), left_at = null
   where id = pt.id returning * into pt;
  return public.online_class_child_payload(rc, re, pt);
end $$;
grant execute on function public.child_online_check_respond(text, uuid) to anon, authenticated;

-- ANSWER a live question (once). MCQ with a correct index → graded + points instantly.
create or replace function public.child_online_answer(p_national_id text, p_question uuid, p_selected integer default null, p_text text default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  p  public.persons;
  q  public.online_class_questions;
  rc public.online_classes;
  re public.enrollments;
  pt public.online_class_participants;
  v_ok boolean;
  v_pts integer := 0;
  v_pl uuid;
begin
  p := public.child_portal_person(p_national_id);
  select * into q from public.online_class_questions where id = p_question;
  if not found then
    raise exception 'question_not_found' using errcode = 'P0002';
  end if;
  if q.status <> 'open' then
    raise exception 'question_closed' using errcode = 'P0001';
  end if;
  rc := public.online_child_class(q.class_id);
  re := public.online_child_enrollment(p.id, rc);
  pt := public.online_child_participant(p.id, q.class_id);
  if pt.id is null then
    raise exception 'not_joined' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.online_class_answers where question_id = q.id and participant_id = pt.id) then
    raise exception 'already_answered' using errcode = 'P0001';
  end if;
  if q.options is not null then
    if p_selected is null or p_selected < 0 or p_selected >= jsonb_array_length(q.options) then
      raise exception 'invalid_option' using errcode = 'P0001';
    end if;
    v_ok := case when q.correct_index is null then null else p_selected = q.correct_index end;
  else
    if length(trim(coalesce(p_text, ''))) = 0 then
      raise exception 'answer_blank' using errcode = 'P0001';
    end if;
    v_ok := null;
  end if;
  if v_ok is true and q.points > 0 then
    v_pts := q.points;
    insert into public.points_log (enrollment_id, cause_id, event_id, delta, recorded_by)
    values (pt.enrollment_id, null, rc.event_id, v_pts, q.created_by)
    returning id into v_pl;
  end if;
  insert into public.online_class_answers (question_id, class_id, participant_id, selected_index, answer_text, is_correct, points_granted, points_log_id)
  values (q.id, q.class_id, pt.id, case when q.options is null then null else p_selected end,
          case when q.options is null then trim(p_text) else null end, v_ok, v_pts, v_pl);
  update public.online_class_participants
     set answers_count = answers_count + 1,
         correct_count = correct_count + case when v_ok is true then 1 else 0 end,
         last_seen_at = now(), left_at = null
   where id = pt.id returning * into pt;
  return public.online_class_child_payload(rc, re, pt);
end $$;
grant execute on function public.child_online_answer(text, uuid, integer, text) to anon, authenticated;

-- CHAT — messages of the room (newest first, paged) for the child
create or replace function public.child_online_messages(p_national_id text, p_class uuid, p_before timestamptz default null, p_limit integer default 100)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  p public.persons;
  rc public.online_classes;
  re public.enrollments;
  pt public.online_class_participants;
begin
  p := public.child_portal_person(p_national_id);
  rc := public.online_child_class(p_class);
  re := public.online_child_enrollment(p.id, rc);
  pt := public.online_child_participant(p.id, p_class);
  return public.online_messages_payload(p_class, pt.id, p_before, least(greatest(coalesce(p_limit, 100), 1), 200));
end $$;
grant execute on function public.child_online_messages(text, uuid, timestamptz, integer) to anon, authenticated;

create or replace function public.online_messages_payload(p_class uuid, p_me_participant uuid, p_before timestamptz, p_limit integer)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(row_to_json(t) order by t.created_at), '[]'::jsonb)
    from (
      select m.id, m.class_id, m.body, m.created_at,
             m.sender_profile_id, m.sender_participant_id,
             coalesce(pr.full_name, p.name) as sender_name,
             coalesce(pr.photo_url, p.image_url) as sender_image,
             (m.sender_profile_id is not null) as is_servant,
             (m.sender_participant_id is not null and m.sender_participant_id = p_me_participant) as mine
        from public.online_class_messages m
        left join public.profiles pr on pr.id = m.sender_profile_id
        left join public.online_class_participants pt on pt.id = m.sender_participant_id
        left join public.persons p on p.id = pt.person_id
       where m.class_id = p_class
         and (p_before is null or m.created_at < p_before)
       order by m.created_at desc
       limit p_limit
    ) t
$$;
revoke all on function public.online_messages_payload(uuid, uuid, timestamptz, integer) from public, anon, authenticated;

-- servant view of the same chat (names resolved) — RLS-checked inside
create or replace function public.online_class_messages_list(p_class uuid, p_before timestamptz default null, p_limit integer default 100)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null or not public.online_class_readable(p_class) then
    raise exception 'forbidden' using errcode = 'P0001';
  end if;
  return public.online_messages_payload(p_class, null, p_before, least(greatest(coalesce(p_limit, 100), 1), 200));
end $$;
grant execute on function public.online_class_messages_list(uuid, timestamptz, integer) to authenticated;

-- CHAT SEND (child) — rate limited 30 msgs / 5 min, chat must be enabled, class live
create or replace function public.child_online_chat_send(p_national_id text, p_class uuid, p_body text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  p  public.persons;
  rc public.online_classes;
  re public.enrollments;
  pt public.online_class_participants;
  m  public.online_class_messages;
begin
  p := public.child_portal_person(p_national_id);
  rc := public.online_child_class(p_class);
  re := public.online_child_enrollment(p.id, rc);
  pt := public.online_child_participant(p.id, p_class);
  if pt.id is null then
    raise exception 'not_joined' using errcode = 'P0001';
  end if;
  if not rc.chat_enabled then
    raise exception 'chat_disabled' using errcode = 'P0001';
  end if;
  if rc.status <> 'live' then
    raise exception 'class_not_live' using errcode = 'P0001';
  end if;
  if length(trim(coalesce(p_body, ''))) = 0 then
    raise exception 'message_blank' using errcode = 'P0001';
  end if;
  if (select count(*) from public.online_class_messages
       where sender_participant_id = pt.id and created_at > now() - interval '5 minutes') >= 30 then
    raise exception 'rate_limited' using errcode = 'P0001';
  end if;
  insert into public.online_class_messages (class_id, sender_participant_id, body)
  values (p_class, pt.id, left(trim(p_body), 1000)) returning * into m;
  update public.online_class_participants set messages_count = messages_count + 1, last_seen_at = now(), left_at = null where id = pt.id;
  return jsonb_build_object('id', m.id, 'created_at', m.created_at);
end $$;
grant execute on function public.child_online_chat_send(text, uuid, text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 9. CHILD PORTAL — points list learns the 'online' source
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
                    else 'cause'::text end as source,
               case when so.id is not null then 'إستبدال نقاط — ' || so.items_count || ' صنف'
                    when sr.id is not null then 'إلغاء عملية إستبدال — استرداد النقاط'
                    when ea.id is not null then 'امتحان — ' || coalesce(ex.title, '')
                    when bg.id is not null then 'هدية عيد ميلاد 🎂 ' || bg.year
                    when oa.id is not null then 'إجابة صحيحة في فصل أونلاين «' || coalesce(oc.title, '') || '»'
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

-- child attendance list: label online-class rows that have no event
drop function if exists public.child_portal_attendance(text);
create or replace function public.child_portal_attendance(p_national_id text)
returns table (
  id uuid, enrollment_id uuid, event_id uuid, event_name text,
  points_delta integer, attended_on date, created_at timestamptz,
  recorded_by_name text, class_name text, service_name text, church_name text
) language plpgsql stable security definer set search_path = public as $$
declare
  p public.persons;
begin
  p := public.child_portal_person(p_national_id);
  return query
    select a.id, a.enrollment_id, a.event_id,
           coalesce(ev.name, case when op.id is not null then 'فصل أونلاين — ' || oc.title end),
           a.points_delta, a.attended_on, a.created_at,
           pr.full_name, cl.name, sv.name, ch.name
      from public.attendance_log a
      join public.enrollments e on e.id = a.enrollment_id
      left join public.events   ev on ev.id = a.event_id
      left join public.online_class_participants op on op.attendance_log_id = a.id
      left join public.online_classes oc on oc.id = op.class_id
      left join public.profiles pr on pr.id = a.recorded_by
      join public.classes  cl on cl.id = e.class_id
      join public.services sv on sv.id = e.service_id
      join public.churches ch on ch.id = e.church_id
     where e.person_id = p.id
     order by a.attended_on desc, a.created_at desc;
end $$;
grant execute on function public.child_portal_attendance(text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 10. REALTIME
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['online_classes', 'online_class_participants', 'online_class_checks',
                           'online_class_check_responses', 'online_class_questions', 'online_class_answers',
                           'online_class_messages'] loop
    if not exists (select 1 from pg_publication_tables
                    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;
alter table public.online_classes               replica identity full;
alter table public.online_class_participants    replica identity full;
alter table public.online_class_checks          replica identity full;
alter table public.online_class_check_responses replica identity full;
alter table public.online_class_questions       replica identity full;
alter table public.online_class_answers         replica identity full;
alter table public.online_class_messages        replica identity full;

analyze public.online_classes;
analyze public.online_class_participants;
analyze public.online_class_sessions;

commit;
