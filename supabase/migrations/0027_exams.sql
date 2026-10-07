-- =====================================================================
-- 0027: EXAMS MODULE — الامتحانات (multiple-choice exams for the children)
--
--   1. exams            — title, scope (church → service → class, null = all),
--                         status draft | published | closed, availability
--                         window, defaults (seconds / points per question),
--                         pass rule (percent or score), points for pass /
--                         full mark, question mode (all | random N),
--                         shuffle, attempts, what the child sees afterwards.
--   2. exam_questions   — text, picture, 2..6 options (jsonb), correct index,
--                         points, seconds (null → exam default), sort order.
--   3. exam_attempts    — one sitting of one child (enrollment). Questions
--                         are picked at START (random / all, shuffled) and
--                         SNAPSHOTTED into exam_answers with a per-question
--                         option permutation. The child NEVER receives the
--                         correct index: every payload is built server-side.
--                         Per-question timer is enforced HERE: a question is
--                         served with a deadline (served_at + seconds); an
--                         answer after the deadline (+3 s grace) is recorded
--                         as timed-out. Going back is impossible — only the
--                         current question can be answered.
--   4. Grading          — at the last answer the attempt is finalized: score,
--                         max score, percent, passed, full mark, points →
--                         ONE points_log row (the existing trigger updates
--                         enrollments.points) so the badge / child portal
--                         see the reward instantly.
--   5. Child portal     — child_portal_exams / child_exam_start /
--                         child_exam_current / child_exam_answer /
--                         child_exam_result (SECURITY DEFINER, anon by the
--                         scanned national id — same model as 0021).
--   6. Servant side     — exams / questions via RLS (module_visible('exams')),
--                         results via exam_attempts + exam_answers (read-only),
--                         exam_cancel_attempt (undo + refund → retake),
--                         exam_duplicate.
--   7. child_portal_points learns source 'exam'.
--
-- Idempotent — safe to re-run. Depends on 0019 (my_scope / is_owner /
-- enrollment_visible / scope_overlaps / scope_contains), 0021 (child
-- portal), 0022 (points_log.event_id), 0024 (module_access / module_visible),
-- 0026 (child_portal_points shape with store rows).
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 0. HELPER: is a module granted for a concrete scope? (usable by anon
--    RPCs — module_visible() needs an authenticated caller)
-- ---------------------------------------------------------------------
create or replace function public.module_granted_for(p_key text, p_church uuid, p_service uuid, p_class uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.module_access m
     where m.module_key = p_key
       and (m.church_id is null
            or (m.church_id = p_church
                and (m.service_id is null or m.service_id = p_service)
                and (m.class_id   is null or m.class_id   = p_class)))
  )
$$;
revoke all on function public.module_granted_for(text, uuid, uuid, uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 1. TABLE: exams
-- ---------------------------------------------------------------------
create table if not exists public.exams (
  id                  uuid primary key default gen_random_uuid(),
  church_id           uuid not null references public.churches(id) on delete cascade,
  service_id          uuid references public.services(id) on delete cascade,   -- null = all services
  class_id            uuid references public.classes(id)  on delete cascade,   -- null = all classes
  title               text not null,
  description         text,
  image_url           text,
  status              text not null default 'draft' check (status in ('draft', 'published', 'closed')),
  opens_at            timestamptz,                                              -- null = immediately
  closes_at           timestamptz,                                              -- null = never
  -- defaults per question (a question may override)
  default_seconds     integer not null default 30 check (default_seconds between 5 and 3600),
  default_points      integer not null default 1  check (default_points between 0 and 1000),
  -- pass rule
  pass_mode           text not null default 'percent' check (pass_mode in ('percent', 'score')),
  pass_value          numeric(8,2) not null default 50 check (pass_value >= 0),
  -- rewards (points_log)
  points_pass         integer not null default 0 check (points_pass >= 0),
  points_full         integer not null default 0 check (points_full >= 0),
  -- which questions each child gets
  question_mode       text not null default 'all' check (question_mode in ('all', 'random')),
  random_count        integer not null default 10 check (random_count >= 1),
  shuffle_questions   boolean not null default true,
  shuffle_options     boolean not null default true,
  max_attempts        integer not null default 1 check (max_attempts between 1 and 100),
  -- what the child sees after finishing
  show_result         boolean not null default true,    -- score / pass
  show_answers        boolean not null default false,   -- correct answers review
  created_at          timestamptz not null default now(),
  created_by          uuid references public.profiles(id),
  edited_at           timestamptz not null default now(),
  edited_by           uuid references public.profiles(id),
  constraint exams_title_not_blank check (length(trim(title)) > 0),
  constraint exams_scope_chain check (not (class_id is not null and service_id is null)),
  constraint exams_window check (opens_at is null or closes_at is null or closes_at > opens_at)
);

comment on table public.exams is
  'الامتحانات — امتحان اختيار من متعدد مقيد بنطاق كنيسة → خدمة → فصل، بمؤقت لكل سؤال ودرجات ونقاط للنجاح';

create index if not exists idx_exams_church  on public.exams(church_id);
create index if not exists idx_exams_service on public.exams(service_id);
create index if not exists idx_exams_class   on public.exams(class_id);
create index if not exists idx_exams_status  on public.exams(church_id, status);

drop trigger if exists trg_exams_touch on public.exams;
create trigger trg_exams_touch before update on public.exams
for each row execute function public.touch_edited();

create or replace function public.check_exam_scope()
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
  if new.pass_mode = 'percent' and new.pass_value > 100 then
    raise exception 'pass_percent_out_of_range';
  end if;
  return new;
end $$;

drop trigger if exists trg_exam_scope on public.exams;
create trigger trg_exam_scope before insert or update on public.exams
for each row execute function public.check_exam_scope();

-- ---------------------------------------------------------------------
-- 2. TABLE: exam_questions
-- ---------------------------------------------------------------------
create table if not exists public.exam_questions (
  id            uuid primary key default gen_random_uuid(),
  exam_id       uuid not null references public.exams(id) on delete cascade,
  sort_order    integer not null default 0,
  text          text not null,
  image_url     text,
  options       jsonb not null,                       -- ["…", "…", …] 2..6 strings
  correct_index integer not null check (correct_index >= 0),
  points        integer not null default 1 check (points between 0 and 1000),
  seconds       integer check (seconds is null or seconds between 5 and 3600),   -- null → exam default
  created_at    timestamptz not null default now(),
  edited_at     timestamptz not null default now(),
  constraint exam_questions_text_not_blank check (length(trim(text)) > 0)
);

create index if not exists idx_exam_questions_exam on public.exam_questions(exam_id, sort_order);

drop trigger if exists trg_exam_questions_touch on public.exam_questions;
create trigger trg_exam_questions_touch before update on public.exam_questions
for each row execute function public.touch_edited();

create or replace function public.check_exam_question()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  n integer;
  i integer;
begin
  new.text := trim(new.text);
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
  if new.correct_index >= n then
    raise exception 'correct_index_out_of_range';
  end if;
  return new;
end $$;

drop trigger if exists trg_exam_question_check on public.exam_questions;
create trigger trg_exam_question_check before insert or update on public.exam_questions
for each row execute function public.check_exam_question();

-- ---------------------------------------------------------------------
-- 3. TABLES: exam_attempts + exam_answers
-- ---------------------------------------------------------------------
create table if not exists public.exam_attempts (
  id                   uuid primary key default gen_random_uuid(),
  exam_id              uuid not null references public.exams(id) on delete cascade,
  enrollment_id        uuid not null references public.enrollments(id) on delete cascade,
  person_id            uuid not null references public.persons(id) on delete cascade,
  church_id            uuid not null references public.churches(id) on delete cascade,
  service_id           uuid not null references public.services(id) on delete cascade,
  class_id             uuid not null references public.classes(id)  on delete cascade,
  status               text not null default 'in_progress'
                       check (status in ('in_progress', 'submitted', 'cancelled')),
  attempt_no           integer not null default 1,
  questions_count      integer not null default 0,
  current_index        integer not null default 0,      -- 0-based position of the question being served
  started_at           timestamptz not null default now(),
  finished_at          timestamptz,
  -- result (filled at finalize)
  score                numeric(10,2) not null default 0,
  max_score            numeric(10,2) not null default 0,
  percent              numeric(5,2)  not null default 0,
  correct_count        integer not null default 0,
  answered_count       integer not null default 0,
  timed_out_count      integer not null default 0,
  passed               boolean,
  full_mark            boolean,
  points_granted       integer not null default 0,
  points_log_id        uuid references public.points_log(id) on delete set null,
  refund_points_log_id uuid references public.points_log(id) on delete set null,
  cancelled_by         uuid references public.profiles(id),
  cancelled_at         timestamptz,
  cancel_note          text
);

comment on table public.exam_attempts is
  'الامتحانات — محاولة مخدوم واحدة: الأسئلة المختارة، الموضع الحالي، النتيجة والنقاط';

create index if not exists idx_exam_attempts_exam       on public.exam_attempts(exam_id, started_at desc);
create index if not exists idx_exam_attempts_enrollment on public.exam_attempts(enrollment_id, exam_id);
create index if not exists idx_exam_attempts_person     on public.exam_attempts(person_id);
create index if not exists idx_exam_attempts_church     on public.exam_attempts(church_id);
create index if not exists idx_exam_attempts_service    on public.exam_attempts(service_id);
create index if not exists idx_exam_attempts_class      on public.exam_attempts(class_id);
create index if not exists idx_exam_attempts_points_log on public.exam_attempts(points_log_id);
-- one open sitting per child per exam
create unique index if not exists uq_exam_attempts_open
  on public.exam_attempts(exam_id, enrollment_id) where status = 'in_progress';

create table if not exists public.exam_answers (
  id               uuid primary key default gen_random_uuid(),
  attempt_id       uuid not null references public.exam_attempts(id) on delete cascade,
  exam_id          uuid not null references public.exams(id) on delete cascade,
  question_id      uuid references public.exam_questions(id) on delete set null,
  position         integer not null,                     -- 0-based order in this attempt
  -- snapshot of the question at start (edits / deletions never change a result)
  question_text    text not null,
  image_url        text,
  options          jsonb not null,                       -- ORIGINAL order
  option_order     integer[] not null,                   -- served order → original index
  correct_index    integer not null,                     -- original index
  points           integer not null,
  seconds          integer not null,
  -- serving / answering
  served_at        timestamptz,
  deadline_at      timestamptz,
  answered_at      timestamptz,
  selected_index   integer,                              -- original index, null = no answer
  is_correct       boolean,
  points_earned    numeric(10,2) not null default 0,
  timed_out        boolean not null default false,
  time_spent_ms    integer,
  constraint uq_exam_answers_position unique (attempt_id, position)
);

create index if not exists idx_exam_answers_attempt  on public.exam_answers(attempt_id, position);
create index if not exists idx_exam_answers_exam     on public.exam_answers(exam_id);
create index if not exists idx_exam_answers_question on public.exam_answers(question_id);

-- ---------------------------------------------------------------------
-- 4. RLS — everything requires module_visible('exams')
-- ---------------------------------------------------------------------
alter table public.exams          enable row level security;
alter table public.exam_questions enable row level security;
alter table public.exam_attempts  enable row level security;
alter table public.exam_answers   enable row level security;

drop policy if exists exams_select on public.exams;
create policy exams_select on public.exams for select using (
  (select public.module_visible('exams'))
  and (select public.scope_overlaps(church_id, service_id, class_id))
);
drop policy if exists exams_insert on public.exams;
create policy exams_insert on public.exams for insert with check (
  (select public.module_visible('exams'))
  and (select public.scope_contains(church_id, service_id, class_id))
);
drop policy if exists exams_update on public.exams;
create policy exams_update on public.exams for update using (
  (select public.module_visible('exams'))
  and (select public.scope_contains(church_id, service_id, class_id))
) with check (
  (select public.module_visible('exams'))
  and (select public.scope_contains(church_id, service_id, class_id))
);
drop policy if exists exams_delete on public.exams;
create policy exams_delete on public.exams for delete using (
  (select public.module_visible('exams'))
  and (select public.scope_contains(church_id, service_id, class_id))
);

-- questions follow their exam
drop policy if exists exam_questions_select on public.exam_questions;
create policy exam_questions_select on public.exam_questions for select using (
  exists (select 1 from public.exams x where x.id = exam_questions.exam_id
            and (select public.module_visible('exams'))
            and (select public.scope_overlaps(x.church_id, x.service_id, x.class_id)))
);
drop policy if exists exam_questions_insert on public.exam_questions;
create policy exam_questions_insert on public.exam_questions for insert with check (
  exists (select 1 from public.exams x where x.id = exam_questions.exam_id
            and (select public.module_visible('exams'))
            and (select public.scope_contains(x.church_id, x.service_id, x.class_id)))
);
drop policy if exists exam_questions_update on public.exam_questions;
create policy exam_questions_update on public.exam_questions for update using (
  exists (select 1 from public.exams x where x.id = exam_questions.exam_id
            and (select public.module_visible('exams'))
            and (select public.scope_contains(x.church_id, x.service_id, x.class_id)))
) with check (
  exists (select 1 from public.exams x where x.id = exam_questions.exam_id
            and (select public.module_visible('exams'))
            and (select public.scope_contains(x.church_id, x.service_id, x.class_id)))
);
drop policy if exists exam_questions_delete on public.exam_questions;
create policy exam_questions_delete on public.exam_questions for delete using (
  exists (select 1 from public.exams x where x.id = exam_questions.exam_id
            and (select public.module_visible('exams'))
            and (select public.scope_contains(x.church_id, x.service_id, x.class_id)))
);

-- attempts / answers: read rows of enrollments I can see; writes only via RPCs
drop policy if exists exam_attempts_select on public.exam_attempts;
create policy exam_attempts_select on public.exam_attempts for select using (
  (select public.module_visible('exams'))
  and public.enrollment_visible(church_id, service_id, class_id,
    (select role from public.my_scope()), (select church_id from public.my_scope()),
    (select service_id from public.my_scope()), (select class_id from public.my_scope()))
);
drop policy if exists exam_answers_select on public.exam_answers;
create policy exam_answers_select on public.exam_answers for select using (
  exists (
    select 1 from public.exam_attempts a
     where a.id = exam_answers.attempt_id
       and (select public.module_visible('exams'))
       and public.enrollment_visible(a.church_id, a.service_id, a.class_id,
         (select role from public.my_scope()), (select church_id from public.my_scope()),
         (select service_id from public.my_scope()), (select class_id from public.my_scope()))
  )
);

-- ---------------------------------------------------------------------
-- 5. INTERNAL HELPERS (not callable from the API)
-- ---------------------------------------------------------------------

-- Is the exam open for this enrollment right now? (published, window,
-- scope, module granted). Raises a specific error otherwise.
create or replace function public.exam_assert_open(x public.exams, e public.enrollments)
returns void language plpgsql stable security definer set search_path = public as $$
begin
  if not public.module_granted_for('exams', e.church_id, e.service_id, e.class_id) then
    raise exception 'module_not_visible' using errcode = 'P0001';
  end if;
  if not (x.church_id = e.church_id
          and (x.service_id is null or x.service_id = e.service_id)
          and (x.class_id   is null or x.class_id   = e.class_id)) then
    raise exception 'exam_out_of_scope' using errcode = 'P0001';
  end if;
  if x.status <> 'published' then
    raise exception 'exam_not_published' using errcode = 'P0001';
  end if;
  if x.opens_at is not null and now() < x.opens_at then
    raise exception 'exam_not_open_yet' using errcode = 'P0001';
  end if;
  if x.closes_at is not null and now() > x.closes_at then
    raise exception 'exam_closed' using errcode = 'P0001';
  end if;
end $$;
revoke all on function public.exam_assert_open(public.exams, public.enrollments) from public, anon, authenticated;

-- The question payload the child receives (NO correct index).
create or replace function public.exam_question_payload(a public.exam_answers, total integer)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'position', a.position,
    'total', total,
    'question_id', a.question_id,
    'text', a.question_text,
    'image_url', a.image_url,
    'options', (
      select coalesce(jsonb_agg(a.options -> o.idx order by o.pos), '[]'::jsonb)
        from unnest(a.option_order) with ordinality as o(idx, pos)
    ),
    'points', a.points,
    'seconds', a.seconds,
    'served_at', a.served_at,
    'deadline_at', a.deadline_at,
    'server_now', now()
  )
$$;
revoke all on function public.exam_question_payload(public.exam_answers, integer) from public, anon, authenticated;

-- Result payload (respects show_result / show_answers unless p_full).
create or replace function public.exam_result_payload(a public.exam_attempts, p_full boolean)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  x public.exams;
  res jsonb;
begin
  select * into x from public.exams where id = a.exam_id;
  res := jsonb_build_object(
    'attempt_id', a.id,
    'exam_id', a.exam_id,
    'exam_title', x.title,
    'status', a.status,
    'attempt_no', a.attempt_no,
    'questions_count', a.questions_count,
    'started_at', a.started_at,
    'finished_at', a.finished_at,
    'show_result', x.show_result,
    'show_answers', x.show_answers,
    'answered_count', a.answered_count,
    'timed_out_count', a.timed_out_count
  );
  if p_full or x.show_result then
    res := res || jsonb_build_object(
      'score', a.score, 'max_score', a.max_score, 'percent', a.percent,
      'correct_count', a.correct_count, 'passed', a.passed, 'full_mark', a.full_mark,
      'points_granted', a.points_granted,
      'pass_mode', x.pass_mode, 'pass_value', x.pass_value
    );
  end if;
  if p_full or x.show_answers then
    res := res || jsonb_build_object('answers', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'position', an.position,
               'text', an.question_text,
               'image_url', an.image_url,
               'options', an.options,
               'correct_index', an.correct_index,
               'selected_index', an.selected_index,
               'is_correct', an.is_correct,
               'points', an.points,
               'points_earned', an.points_earned,
               'timed_out', an.timed_out,
               'time_spent_ms', an.time_spent_ms
             ) order by an.position), '[]'::jsonb)
        from public.exam_answers an where an.attempt_id = a.id));
  end if;
  return res;
end $$;
revoke all on function public.exam_result_payload(public.exam_attempts, boolean) from public, anon, authenticated;

-- Finalize: grade + reward. Idempotent (no-op if already submitted).
create or replace function public.exam_finalize(p_attempt uuid)
returns void language plpgsql volatile security definer set search_path = public as $$
declare
  a        public.exam_attempts;
  x        public.exams;
  v_score  numeric(10,2);
  v_max    numeric(10,2);
  v_pct    numeric(5,2);
  v_ok     integer;
  v_ans    integer;
  v_to     integer;
  v_pass   boolean;
  v_full   boolean;
  v_points integer := 0;
  v_pl     uuid;
begin
  select * into a from public.exam_attempts where id = p_attempt for update;
  if not found or a.status <> 'in_progress' then return; end if;
  select * into x from public.exams where id = a.exam_id;

  select coalesce(sum(points_earned), 0), coalesce(sum(points), 0),
         count(*) filter (where is_correct), count(*) filter (where selected_index is not null),
         count(*) filter (where timed_out)
    into v_score, v_max, v_ok, v_ans, v_to
    from public.exam_answers where attempt_id = a.id;

  v_pct  := case when v_max > 0 then round(v_score * 100.0 / v_max, 2) else 0 end;
  v_full := v_max > 0 and v_score >= v_max;
  v_pass := case when x.pass_mode = 'percent' then v_pct >= x.pass_value else v_score >= x.pass_value end;
  if v_full then v_pass := true; end if;
  v_points := case when v_full then greatest(x.points_full, x.points_pass) when v_pass then x.points_pass else 0 end;

  if v_points > 0 then
    insert into public.points_log (enrollment_id, cause_id, event_id, delta, recorded_by)
    values (a.enrollment_id, null, null, v_points, null)
    returning id into v_pl;
  end if;

  update public.exam_attempts
     set status = 'submitted', finished_at = now(),
         score = v_score, max_score = v_max, percent = v_pct,
         correct_count = v_ok, answered_count = v_ans, timed_out_count = v_to,
         passed = v_pass, full_mark = v_full,
         points_granted = v_points, points_log_id = v_pl,
         current_index = a.questions_count
   where id = a.id;
end $$;
revoke all on function public.exam_finalize(uuid) from public, anon, authenticated;

-- Advance the attempt past every served question whose deadline passed
-- (child closed the app mid-exam). Then serve the current question (set
-- served_at / deadline_at if not yet). Finalizes when nothing is left.
create or replace function public.exam_advance(p_attempt uuid)
returns public.exam_attempts language plpgsql volatile security definer set search_path = public as $$
declare
  a  public.exam_attempts;
  an public.exam_answers;
  grace constant interval := interval '3 seconds';
begin
  select * into a from public.exam_attempts where id = p_attempt for update;
  if not found then
    raise exception 'attempt_not_found' using errcode = 'P0002';
  end if;
  if a.status <> 'in_progress' then return a; end if;

  loop
    if a.current_index >= a.questions_count then
      perform public.exam_finalize(a.id);
      select * into a from public.exam_attempts where id = a.id;
      return a;
    end if;
    select * into an from public.exam_answers where attempt_id = a.id and position = a.current_index;
    if an.served_at is null then
      update public.exam_answers
         set served_at = now(), deadline_at = now() + make_interval(secs => an.seconds)
       where id = an.id;
      return a;
    end if;
    if now() <= an.deadline_at + grace then
      return a;   -- still answerable
    end if;
    -- deadline passed without an answer → timed out, move on
    update public.exam_answers
       set timed_out = true, is_correct = false, points_earned = 0,
           answered_at = coalesce(answered_at, an.deadline_at),
           time_spent_ms = an.seconds * 1000
     where id = an.id;
    update public.exam_attempts set current_index = current_index + 1 where id = a.id
      returning * into a;
  end loop;
end $$;
revoke all on function public.exam_advance(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 6. CHILD PORTAL RPCs (anon, keyed by the scanned national id)
-- ---------------------------------------------------------------------

-- The exams the child can see: published + in scope + module granted,
-- with his attempt state; plus closed exams he already took.
create or replace function public.child_portal_exams(p_national_id text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  p   public.persons;
  res jsonb;
begin
  p := public.child_portal_person(p_national_id);
  select coalesce(jsonb_agg(to_jsonb(t) - 'sort_key' order by t.sort_key, t.created_at desc), '[]'::jsonb)
    into res
    from (
      select x.id, x.title, x.description, x.image_url, x.status, x.opens_at, x.closes_at,
             x.default_seconds, x.question_mode, x.random_count, x.max_attempts,
             x.show_result, x.pass_mode, x.pass_value, x.points_pass, x.points_full, x.created_at,
             e.id as enrollment_id, cl.name as class_name, sv.name as service_name, ch.name as church_name,
             (select count(*) from public.exam_questions q where q.exam_id = x.id) as total_questions,
             case when x.question_mode = 'random'
                  then least(x.random_count, (select count(*) from public.exam_questions q where q.exam_id = x.id))
                  else (select count(*) from public.exam_questions q where q.exam_id = x.id) end as served_questions,
             (select count(*) from public.exam_attempts a
               where a.exam_id = x.id and a.enrollment_id = e.id and a.status = 'submitted') as attempts_used,
             (select a.id from public.exam_attempts a
               where a.exam_id = x.id and a.enrollment_id = e.id and a.status = 'in_progress' limit 1) as open_attempt_id,
             (select public.exam_result_payload(a, false) from public.exam_attempts a
               where a.exam_id = x.id and a.enrollment_id = e.id and a.status = 'submitted'
               order by a.finished_at desc limit 1) as last_result,
             (x.status = 'published'
                and (x.opens_at is null or now() >= x.opens_at)
                and (x.closes_at is null or now() <= x.closes_at)) as is_open,
             case when x.status = 'published'
                    and (x.opens_at is null or now() >= x.opens_at)
                    and (x.closes_at is null or now() <= x.closes_at) then 0 else 1 end as sort_key
        from public.enrollments e
        join public.exams x
          on x.church_id = e.church_id
         and (x.service_id is null or x.service_id = e.service_id)
         and (x.class_id   is null or x.class_id   = e.class_id)
        join public.classes  cl on cl.id = e.class_id
        join public.services sv on sv.id = e.service_id
        join public.churches ch on ch.id = e.church_id
       where e.person_id = p.id
         and x.status in ('published', 'closed')
         and public.module_granted_for('exams', e.church_id, e.service_id, e.class_id)
         and (x.status = 'published'
              or exists (select 1 from public.exam_attempts a
                          where a.exam_id = x.id and a.enrollment_id = e.id and a.status = 'submitted'))
    ) t;
  return res;
end $$;
grant execute on function public.child_portal_exams(text) to anon, authenticated;

-- Start (or resume) an attempt. Picks + snapshots the questions, then
-- serves the first one. Returns { attempt_id, questions_count, finished, question | result }.
create or replace function public.child_exam_start(p_national_id text, p_exam uuid)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  p       public.persons;
  x       public.exams;
  e       public.enrollments;
  a       public.exam_attempts;
  an      public.exam_answers;
  q       record;
  v_used  integer;
  v_pos   integer := 0;
  v_n     integer;
  v_order integer[];
begin
  p := public.child_portal_person(p_national_id);
  select * into x from public.exams where id = p_exam;
  if not found then
    raise exception 'exam_not_found' using errcode = 'P0002';
  end if;
  -- the enrollment of this child covered by the exam
  select en.* into e from public.enrollments en
   where en.person_id = p.id
     and x.church_id = en.church_id
     and (x.service_id is null or x.service_id = en.service_id)
     and (x.class_id   is null or x.class_id   = en.class_id)
   order by en.created_at limit 1;
  if not found then
    raise exception 'exam_out_of_scope' using errcode = 'P0001';
  end if;
  perform public.exam_assert_open(x, e);

  -- resume an open sitting
  select * into a from public.exam_attempts
   where exam_id = x.id and enrollment_id = e.id and status = 'in_progress' for update;
  if found then
    a := public.exam_advance(a.id);
    if a.status <> 'in_progress' then
      return jsonb_build_object('attempt_id', a.id, 'questions_count', a.questions_count,
                                'finished', true, 'result', public.exam_result_payload(a, false));
    end if;
    select * into an from public.exam_answers where attempt_id = a.id and position = a.current_index;
    return jsonb_build_object('attempt_id', a.id, 'questions_count', a.questions_count,
                              'finished', false, 'question', public.exam_question_payload(an, a.questions_count));
  end if;

  select count(*) into v_used from public.exam_attempts
   where exam_id = x.id and enrollment_id = e.id and status = 'submitted';
  if v_used >= x.max_attempts then
    raise exception 'no_attempts_left' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.exam_questions where exam_id = x.id) then
    raise exception 'exam_has_no_questions' using errcode = 'P0001';
  end if;

  insert into public.exam_attempts (exam_id, enrollment_id, person_id, church_id, service_id, class_id, attempt_no)
  values (x.id, e.id, p.id, e.church_id, e.service_id, e.class_id, v_used + 1)
  returning * into a;

  -- pick + snapshot the questions
  for q in
    select * from public.exam_questions
     where exam_id = x.id
     order by case when x.question_mode = 'random' or x.shuffle_questions then random() else 0 end,
              sort_order, created_at
     limit case when x.question_mode = 'random' then x.random_count else null end
  loop
    v_n := jsonb_array_length(q.options);
    if x.shuffle_options then
      select array_agg(i order by random()) into v_order from generate_series(0, v_n - 1) i;
    else
      select array_agg(i order by i) into v_order from generate_series(0, v_n - 1) i;
    end if;
    insert into public.exam_answers (
      attempt_id, exam_id, question_id, position, question_text, image_url, options, option_order,
      correct_index, points, seconds)
    values (a.id, x.id, q.id, v_pos, q.text, q.image_url, q.options, v_order,
            q.correct_index, q.points, coalesce(q.seconds, x.default_seconds));
    v_pos := v_pos + 1;
  end loop;

  update public.exam_attempts set questions_count = v_pos where id = a.id returning * into a;
  a := public.exam_advance(a.id);
  select * into an from public.exam_answers where attempt_id = a.id and position = a.current_index;
  return jsonb_build_object('attempt_id', a.id, 'questions_count', a.questions_count,
                            'finished', false, 'question', public.exam_question_payload(an, a.questions_count));
end $$;
grant execute on function public.child_exam_start(text, uuid) to anon, authenticated;

-- The question being served right now (re-serves after a reload; expired
-- questions are skipped as timed-out). Returns { finished, question | result }.
create or replace function public.child_exam_current(p_national_id text, p_attempt uuid)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  p  public.persons;
  a  public.exam_attempts;
  an public.exam_answers;
begin
  p := public.child_portal_person(p_national_id);
  select * into a from public.exam_attempts where id = p_attempt and person_id = p.id;
  if not found then
    raise exception 'attempt_not_found' using errcode = 'P0002';
  end if;
  a := public.exam_advance(a.id);
  if a.status <> 'in_progress' then
    return jsonb_build_object('attempt_id', a.id, 'questions_count', a.questions_count,
                              'finished', true, 'result', public.exam_result_payload(a, false));
  end if;
  select * into an from public.exam_answers where attempt_id = a.id and position = a.current_index;
  return jsonb_build_object('attempt_id', a.id, 'questions_count', a.questions_count,
                            'finished', false, 'question', public.exam_question_payload(an, a.questions_count));
end $$;
grant execute on function public.child_exam_current(text, uuid) to anon, authenticated;

-- Answer the CURRENT question (p_selected = position in the SERVED option
-- order, or null = skip / time ran out). Moves forward; never back.
create or replace function public.child_exam_answer(
  p_national_id text, p_attempt uuid, p_position integer, p_selected integer)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  p       public.persons;
  a       public.exam_attempts;
  an      public.exam_answers;
  v_orig  integer;
  v_ok    boolean;
  grace constant interval := interval '3 seconds';
begin
  p := public.child_portal_person(p_national_id);
  select * into a from public.exam_attempts where id = p_attempt and person_id = p.id for update;
  if not found then
    raise exception 'attempt_not_found' using errcode = 'P0002';
  end if;
  if a.status <> 'in_progress' then
    return jsonb_build_object('attempt_id', a.id, 'questions_count', a.questions_count,
                              'finished', true, 'result', public.exam_result_payload(a, false));
  end if;

  -- a stale answer for an older question (double tap / reconnect) is ignored
  if p_position = a.current_index then
    select * into an from public.exam_answers where attempt_id = a.id and position = a.current_index for update;
    if an.served_at is null then
      raise exception 'question_not_served' using errcode = 'P0001';
    end if;
    if now() > an.deadline_at + grace or p_selected is null then
      update public.exam_answers
         set timed_out = (now() > an.deadline_at + grace), is_correct = false, points_earned = 0,
             answered_at = now(), selected_index = null,
             time_spent_ms = least(an.seconds * 1000, (extract(epoch from now() - an.served_at) * 1000)::int)
       where id = an.id;
    else
      if p_selected < 0 or p_selected >= array_length(an.option_order, 1) then
        raise exception 'invalid_option' using errcode = 'P0001';
      end if;
      v_orig := an.option_order[p_selected + 1];
      v_ok   := v_orig = an.correct_index;
      update public.exam_answers
         set selected_index = v_orig, is_correct = v_ok,
             points_earned = case when v_ok then an.points else 0 end,
             answered_at = now(), timed_out = false,
             time_spent_ms = (extract(epoch from now() - an.served_at) * 1000)::int
       where id = an.id;
    end if;
    update public.exam_attempts set current_index = current_index + 1 where id = a.id;
  elsif p_position > a.current_index then
    raise exception 'position_mismatch' using errcode = 'P0001';
  end if;

  a := public.exam_advance(a.id);
  if a.status <> 'in_progress' then
    return jsonb_build_object('attempt_id', a.id, 'questions_count', a.questions_count,
                              'finished', true, 'result', public.exam_result_payload(a, false));
  end if;
  select * into an from public.exam_answers where attempt_id = a.id and position = a.current_index;
  return jsonb_build_object('attempt_id', a.id, 'questions_count', a.questions_count,
                            'finished', false, 'question', public.exam_question_payload(an, a.questions_count));
end $$;
grant execute on function public.child_exam_answer(text, uuid, integer, integer) to anon, authenticated;

-- A finished attempt's result (what the exam allows the child to see).
create or replace function public.child_exam_result(p_national_id text, p_attempt uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  p public.persons;
  a public.exam_attempts;
begin
  p := public.child_portal_person(p_national_id);
  select * into a from public.exam_attempts where id = p_attempt and person_id = p.id;
  if not found then
    raise exception 'attempt_not_found' using errcode = 'P0002';
  end if;
  if a.status = 'in_progress' then
    raise exception 'attempt_in_progress' using errcode = 'P0001';
  end if;
  return public.exam_result_payload(a, false);
end $$;
grant execute on function public.child_exam_result(text, uuid) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 7. SERVANT RPCs
-- ---------------------------------------------------------------------

-- Full result of an attempt (servant view: always includes answers).
create or replace function public.exam_attempt_detail(p_attempt uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  a public.exam_attempts;
  s record;
begin
  if auth.uid() is null or not public.module_visible('exams') then
    raise exception 'forbidden' using errcode = 'P0001';
  end if;
  select * into a from public.exam_attempts where id = p_attempt;
  if not found then
    raise exception 'attempt_not_found' using errcode = 'P0002';
  end if;
  select * into s from public.my_scope();
  if not public.enrollment_visible(a.church_id, a.service_id, a.class_id, s.role, s.church_id, s.service_id, s.class_id) then
    raise exception 'forbidden' using errcode = 'P0001';
  end if;
  return public.exam_result_payload(a, true);
end $$;
grant execute on function public.exam_attempt_detail(uuid) to authenticated;

-- Cancel an attempt (servant with write scope on the exam): refunds the
-- granted points, marks it cancelled so the child may sit again.
create or replace function public.exam_cancel_attempt(p_attempt uuid, p_note text default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  a    public.exam_attempts;
  x    public.exams;
  v_pl uuid;
begin
  if auth.uid() is null then
    raise exception 'forbidden' using errcode = 'P0001';
  end if;
  if not public.module_visible('exams') then
    raise exception 'module_not_visible' using errcode = 'P0001';
  end if;
  select * into a from public.exam_attempts where id = p_attempt for update;
  if not found then
    raise exception 'attempt_not_found' using errcode = 'P0002';
  end if;
  select * into x from public.exams where id = a.exam_id;
  if not public.scope_contains(x.church_id, x.service_id, x.class_id) then
    raise exception 'forbidden' using errcode = 'P0001';
  end if;
  if a.status = 'cancelled' then
    raise exception 'already_cancelled' using errcode = 'P0001';
  end if;
  if a.status = 'submitted' and a.points_granted > 0 then
    insert into public.points_log (enrollment_id, cause_id, event_id, delta, recorded_by)
    values (a.enrollment_id, null, null, -a.points_granted, auth.uid())
    returning id into v_pl;
  end if;
  update public.exam_attempts
     set status = 'cancelled', cancelled_by = auth.uid(), cancelled_at = now(),
         refund_points_log_id = v_pl, cancel_note = nullif(trim(coalesce(p_note, '')), ''),
         finished_at = coalesce(finished_at, now())
   where id = a.id;
  return jsonb_build_object('attempt_id', a.id, 'refunded', a.points_granted);
end $$;
grant execute on function public.exam_cancel_attempt(uuid, text) to authenticated;

-- Duplicate an exam with all its questions (as a draft) — handy for the
-- next class / year. Returns the new exam id.
create or replace function public.exam_duplicate(p_exam uuid, p_title text default null)
returns uuid language plpgsql volatile security definer set search_path = public as $$
declare
  x     public.exams;
  v_new uuid;
begin
  if auth.uid() is null or not public.module_visible('exams') then
    raise exception 'forbidden' using errcode = 'P0001';
  end if;
  select * into x from public.exams where id = p_exam;
  if not found then
    raise exception 'exam_not_found' using errcode = 'P0002';
  end if;
  if not public.scope_contains(x.church_id, x.service_id, x.class_id) then
    raise exception 'forbidden' using errcode = 'P0001';
  end if;
  insert into public.exams (
    church_id, service_id, class_id, title, description, image_url, status, opens_at, closes_at,
    default_seconds, default_points, pass_mode, pass_value, points_pass, points_full,
    question_mode, random_count, shuffle_questions, shuffle_options, max_attempts,
    show_result, show_answers, created_by, edited_by)
  values (
    x.church_id, x.service_id, x.class_id, coalesce(nullif(trim(p_title), ''), x.title || ' (نسخة)'),
    x.description, x.image_url, 'draft', null, null,
    x.default_seconds, x.default_points, x.pass_mode, x.pass_value, x.points_pass, x.points_full,
    x.question_mode, x.random_count, x.shuffle_questions, x.shuffle_options, x.max_attempts,
    x.show_result, x.show_answers, auth.uid(), auth.uid())
  returning id into v_new;
  insert into public.exam_questions (exam_id, sort_order, text, image_url, options, correct_index, points, seconds)
  select v_new, sort_order, text, image_url, options, correct_index, points, seconds
    from public.exam_questions where exam_id = x.id order by sort_order, created_at;
  return v_new;
end $$;
grant execute on function public.exam_duplicate(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- 8. CHILD PORTAL — points list learns the 'exam' source
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
                    when xa.id is not null or xr.id is not null then 'exam'::text
                    else 'cause'::text end as source,
               case when so.id is not null then 'إستبدال نقاط — ' || so.items_count || ' صنف'
                    when sr.id is not null then 'إلغاء عملية إستبدال — استرداد النقاط'
                    when xa.id is not null then case when xa.full_mark then 'الدرجة الكاملة في امتحان «' else 'النجاح في امتحان «' end || xe.title || '»'
                    when xr.id is not null then 'إلغاء محاولة امتحان «' || xre.title || '»'
                    else ca.name end as reason,
               pl.delta, pl.created_at, pl.recorded_by,
               ev.name as event_name,
               coalesce(so.id, sr.id) as order_id,
               coalesce(xa.id, xr.id) as attempt_id
          from public.points_log pl
          join public.enrollments e on e.id = pl.enrollment_id
          left join public.causes ca on ca.id = pl.cause_id
          left join public.events ev on ev.id = pl.event_id
          left join public.store_orders so on so.points_log_id = pl.id
          left join public.store_orders sr on sr.refund_points_log_id = pl.id
          left join public.exam_attempts xa on xa.points_log_id = pl.id
          left join public.exams xe on xe.id = xa.exam_id
          left join public.exam_attempts xr on xr.refund_points_log_id = pl.id
          left join public.exams xre on xre.id = xr.exam_id
         where e.person_id = p.id
        union all
        select a.id, a.enrollment_id, 'attendance'::text,
               ev.name, a.points_delta, a.created_at, a.recorded_by,
               ev.name, null::uuid, null::uuid
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

-- ---------------------------------------------------------------------
-- 9. REALTIME
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'exams') then
    alter publication supabase_realtime add table public.exams;
  end if;
  if not exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'exam_questions') then
    alter publication supabase_realtime add table public.exam_questions;
  end if;
  if not exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'exam_attempts') then
    alter publication supabase_realtime add table public.exam_attempts;
  end if;
end $$;
alter table public.exams          replica identity full;
alter table public.exam_questions replica identity full;
alter table public.exam_attempts  replica identity full;

analyze public.exams;
analyze public.exam_questions;
analyze public.exam_attempts;
analyze public.exam_answers;

commit;
