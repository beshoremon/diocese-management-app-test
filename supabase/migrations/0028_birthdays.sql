-- =====================================================================
-- 0028: BIRTHDAYS MODULE — أعياد الميلاد
--
-- Who has a birthday this month (day by day), greet them (call / WhatsApp
-- / SMS — one or ALL), give a birthday gift of points, design & print /
-- share birthday cards, and keep a log of who was greeted so nothing is
-- forgotten and nobody is greeted twice.
--
--   1. birthdays_in_month(year, month, scope)  — RPC (security invoker →
--      RLS applies): every visible enrollment whose person was born in
--      that month, one row per PERSON (first visible enrollment), with the
--      age he turns that year, his greetings of THAT year and whether the
--      gift was already given. Also `birthdays_upcoming(days)` for the
--      home widget (today + the next N days, wraps across the year).
--   2. birthday_greetings — log: person × year × kind
--      (call | whatsapp | sms | card_printed | card_shared | gift | note).
--      RLS: enrollments I can see, module granted.
--   3. birthday_gift(enrollment, year, points, note) — SECURITY DEFINER
--      transaction: module granted → enrollment visible → not already
--      gifted this year → ONE points_log row (+points, no cause / event,
--      the existing trigger updates enrollments.points) + a greeting row
--      of kind 'gift' holding the points_log id. `birthday_gift_cancel`
--      reverts it (managers) with a compensating −points row.
--   4. birthday_card_templates — same JSON design engine as the ID cards
--      (src/lib/card-types.ts) with birthday variables (age, day, month,
--      year …). Scoped church → service? → class? (null = all).
--   5. birthday_settings — per church (or global row church_id = null):
--      default gift points, default message template.
--   6. child portal: child_portal_points labels the gift rows
--      (source 'birthday'), and child_portal_birthday(nid) tells the
--      portal whether today is the child's birthday (+ card template to
--      show him).
--
-- Idempotent — safe to re-run. Depends on 0019 (my_scope / is_owner /
-- enrollment_visible / scope_overlaps / scope_contains), 0021 (child
-- portal), 0024 (module_visible), 0027 (module_granted_for,
-- child_portal_points signature).
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 0. INDEX — birthdays by month / day (expression index). Lets the month
--    query hit the index instead of scanning every person of the diocese.
-- ---------------------------------------------------------------------
create index if not exists idx_persons_birth_month_day
  on public.persons ((extract(month from birthdate)::int), (extract(day from birthdate)::int))
  where birthdate is not null;

-- ---------------------------------------------------------------------
-- 1. TABLE: birthday_greetings (سجل التهاني)
-- ---------------------------------------------------------------------
create table if not exists public.birthday_greetings (
  id            uuid primary key default gen_random_uuid(),
  person_id     uuid not null references public.persons(id)     on delete cascade,
  enrollment_id uuid not null references public.enrollments(id) on delete cascade,
  -- denormalized scope (from the enrollment) for cheap RLS + realtime
  church_id     uuid not null references public.churches(id) on delete cascade,
  service_id    uuid not null references public.services(id) on delete cascade,
  class_id      uuid not null references public.classes(id)  on delete cascade,
  year          integer not null check (year between 1900 and 2200),   -- the birthday year greeted
  kind          text not null check (kind in ('call', 'whatsapp', 'sms', 'card_printed', 'card_shared', 'gift', 'note')),
  message       text,                                                  -- text sent / note
  points        integer,                                               -- for kind = gift
  points_log_id uuid references public.points_log(id) on delete set null,
  recorded_by   uuid references public.profiles(id),
  created_at    timestamptz not null default now()
);

comment on table public.birthday_greetings is
  'أعياد الميلاد — سجل التهاني: لكل مخدوم في كل سنة: مكالمة / واتساب / SMS / كارت / هدية نقاط';

create index if not exists idx_birthday_greetings_person_year on public.birthday_greetings(person_id, year);
create index if not exists idx_birthday_greetings_class        on public.birthday_greetings(class_id, year);
create index if not exists idx_birthday_greetings_created      on public.birthday_greetings(created_at desc);
create index if not exists idx_birthday_greetings_points_log   on public.birthday_greetings(points_log_id);
-- one GIFT per person per year (the whole point of the log)
create unique index if not exists uq_birthday_gift_person_year
  on public.birthday_greetings(person_id, year) where kind = 'gift';

-- fill the scope + person from the enrollment
create or replace function public.fill_birthday_greeting_scope()
returns trigger language plpgsql security definer set search_path = public as $$
declare e public.enrollments;
begin
  select * into e from public.enrollments where id = new.enrollment_id;
  if e.id is null then raise exception 'enrollment_not_found'; end if;
  new.person_id  := e.person_id;
  new.church_id  := e.church_id;
  new.service_id := e.service_id;
  new.class_id   := e.class_id;
  if new.recorded_by is null then new.recorded_by := auth.uid(); end if;
  return new;
end $$;

drop trigger if exists trg_birthday_greeting_scope on public.birthday_greetings;
create trigger trg_birthday_greeting_scope before insert on public.birthday_greetings
for each row execute function public.fill_birthday_greeting_scope();

alter table public.birthday_greetings enable row level security;

drop policy if exists birthday_greetings_select on public.birthday_greetings;
create policy birthday_greetings_select on public.birthday_greetings for select using (
  (select public.module_visible('birthdays'))
  and public.enrollment_visible(church_id, service_id, class_id,
    (select role from public.my_scope()), (select church_id from public.my_scope()),
    (select service_id from public.my_scope()), (select class_id from public.my_scope()))
);
drop policy if exists birthday_greetings_insert on public.birthday_greetings;
create policy birthday_greetings_insert on public.birthday_greetings for insert with check (
  (select public.module_visible('birthdays'))
  and kind <> 'gift'                                   -- gifts only through the RPC
  and exists (select 1 from public.enrollments e where e.id = enrollment_id)   -- RLS on enrollments = visible to me
);
drop policy if exists birthday_greetings_delete on public.birthday_greetings;
create policy birthday_greetings_delete on public.birthday_greetings for delete using (
  (select public.module_visible('birthdays'))
  and kind <> 'gift'
  and (recorded_by = auth.uid()
       or (select role from public.my_scope()) in ('owner', 'church_manager', 'service_manager'))
  and public.enrollment_visible(church_id, service_id, class_id,
    (select role from public.my_scope()), (select church_id from public.my_scope()),
    (select service_id from public.my_scope()), (select class_id from public.my_scope()))
);

-- ---------------------------------------------------------------------
-- 2. TABLE: birthday_card_templates (قوالب كروت عيد الميلاد)
-- ---------------------------------------------------------------------
create table if not exists public.birthday_card_templates (
  id             uuid primary key default gen_random_uuid(),
  church_id      uuid not null references public.churches(id) on delete cascade,
  service_id     uuid references public.services(id) on delete cascade,   -- null = all services
  class_id       uuid references public.classes(id)  on delete cascade,   -- null = all classes
  name           text not null,
  design         jsonb not null default '{}'::jsonb,
  print_settings jsonb not null default '{}'::jsonb,
  is_default     boolean not null default false,
  created_at     timestamptz not null default now(),
  created_by     uuid references public.profiles(id),
  edited_at      timestamptz not null default now(),
  edited_by      uuid references public.profiles(id),
  constraint birthday_card_templates_scope_chain check (not (class_id is not null and service_id is null))
);

comment on table public.birthday_card_templates is
  'أعياد الميلاد — قوالب كروت التهنئة (نفس محرك تصميم الكروت) بنطاق كنيسة → خدمة → فصل';

create index if not exists idx_birthday_card_templates_church on public.birthday_card_templates(church_id);

drop trigger if exists trg_birthday_card_templates_touch on public.birthday_card_templates;
create trigger trg_birthday_card_templates_touch before update on public.birthday_card_templates
for each row execute function public.touch_edited();

create or replace function public.check_birthday_card_template_scope()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.service_id is not null and not exists (
    select 1 from public.services s where s.id = new.service_id and s.church_id = new.church_id
  ) then raise exception 'service does not belong to the church'; end if;
  if new.class_id is not null and not exists (
    select 1 from public.classes c
     where c.id = new.class_id and c.service_id = new.service_id and c.church_id = new.church_id
  ) then raise exception 'class does not belong to the service'; end if;
  -- only one default per exact scope
  if new.is_default then
    update public.birthday_card_templates
       set is_default = false
     where id <> new.id and is_default and church_id = new.church_id
       and coalesce(service_id, '00000000-0000-0000-0000-000000000000'::uuid)
           = coalesce(new.service_id, '00000000-0000-0000-0000-000000000000'::uuid)
       and coalesce(class_id, '00000000-0000-0000-0000-000000000000'::uuid)
           = coalesce(new.class_id, '00000000-0000-0000-0000-000000000000'::uuid);
  end if;
  return new;
end $$;

drop trigger if exists trg_birthday_card_template_scope on public.birthday_card_templates;
create trigger trg_birthday_card_template_scope before insert or update on public.birthday_card_templates
for each row execute function public.check_birthday_card_template_scope();

alter table public.birthday_card_templates enable row level security;

drop policy if exists birthday_card_templates_select on public.birthday_card_templates;
create policy birthday_card_templates_select on public.birthday_card_templates for select using (
  (select public.module_visible('birthdays'))
  and (select public.scope_overlaps(church_id, service_id, class_id))
);
drop policy if exists birthday_card_templates_insert on public.birthday_card_templates;
create policy birthday_card_templates_insert on public.birthday_card_templates for insert with check (
  (select public.module_visible('birthdays'))
  and (select public.scope_contains(church_id, service_id, class_id))
);
drop policy if exists birthday_card_templates_update on public.birthday_card_templates;
create policy birthday_card_templates_update on public.birthday_card_templates for update using (
  (select public.module_visible('birthdays'))
  and (select public.scope_contains(church_id, service_id, class_id))
) with check (
  (select public.module_visible('birthdays'))
  and (select public.scope_contains(church_id, service_id, class_id))
);
drop policy if exists birthday_card_templates_delete on public.birthday_card_templates;
create policy birthday_card_templates_delete on public.birthday_card_templates for delete using (
  (select public.module_visible('birthdays'))
  and (select public.scope_contains(church_id, service_id, class_id))
);

-- ---------------------------------------------------------------------
-- 3. TABLE: birthday_settings (إعدادات الوحدة) — one row per church,
--    plus an optional global row (church_id null, owner only)
-- ---------------------------------------------------------------------
create table if not exists public.birthday_settings (
  id               uuid primary key default gen_random_uuid(),
  church_id        uuid references public.churches(id) on delete cascade,
  gift_points      integer not null default 10 check (gift_points >= 0),
  message_template text not null default 'كل سنة وأنت طيب يا [الاسم الأول] 🎂🎉 عيد ميلاد سعيد وربنا يفرّح قلبك — أسرة [اسم الفصل] · [اسم الكنيسة]',
  edited_at        timestamptz not null default now(),
  edited_by        uuid references public.profiles(id)
);
create unique index if not exists uq_birthday_settings_church
  on public.birthday_settings (coalesce(church_id, '00000000-0000-0000-0000-000000000000'::uuid));

drop trigger if exists trg_birthday_settings_touch on public.birthday_settings;
create trigger trg_birthday_settings_touch before update on public.birthday_settings
for each row execute function public.touch_edited();

alter table public.birthday_settings enable row level security;
drop policy if exists birthday_settings_select on public.birthday_settings;
create policy birthday_settings_select on public.birthday_settings for select using (
  (select public.module_visible('birthdays'))
  and (church_id is null or (select public.scope_overlaps(church_id, null, null)))
);
drop policy if exists birthday_settings_write on public.birthday_settings;
create policy birthday_settings_write on public.birthday_settings for all using (
  (select public.module_visible('birthdays'))
  and ((church_id is null and (select public.is_owner()))
       or (church_id is not null and (select role from public.my_scope()) in ('owner', 'church_manager')
           and (select public.scope_contains(church_id, null, null))))
) with check (
  (select public.module_visible('birthdays'))
  and ((church_id is null and (select public.is_owner()))
       or (church_id is not null and (select role from public.my_scope()) in ('owner', 'church_manager')
           and (select public.scope_contains(church_id, null, null))))
);

-- ---------------------------------------------------------------------
-- 4. RPC: birthdays_in_month — the month view (RLS applies)
-- ---------------------------------------------------------------------
drop function if exists public.birthdays_in_month(integer, integer, uuid, uuid, uuid);
create or replace function public.birthdays_in_month(
  p_year integer, p_month integer,
  p_church uuid default null, p_service uuid default null, p_class uuid default null
)
returns table (
  enrollment_id uuid, person_id uuid,
  church_id uuid, service_id uuid, class_id uuid,
  national_id text, name text, birthdate date, gender text, phone text, address text, image_url text,
  points integer, attendance_count integer,
  birth_day integer, birth_month integer,
  turns_age integer,                      -- age he turns in p_year
  greetings jsonb,                        -- [{id, kind, created_at, points, message, recorded_by_name}] of p_year
  gift_points integer,                    -- points gifted in p_year (null = not yet)
  enrollments_count integer               -- how many visible enrollments this person has (in scope)
)
language sql stable security invoker set search_path = public as $$
  with vis as (
    -- one row per person: his first visible enrollment (narrowed by the scope)
    select distinct on (e.person_id)
           e.id as enrollment_id, e.person_id, e.church_id, e.service_id, e.class_id,
           e.points, e.attendance_count,
           count(*) over (partition by e.person_id)::int as enrollments_count
      from public.enrollments e
      join public.persons p on p.id = e.person_id
     where p.birthdate is not null
       and extract(month from p.birthdate)::int = p_month
       and (p_church  is null or e.church_id  = p_church)
       and (p_service is null or e.service_id = p_service)
       and (p_class   is null or e.class_id   = p_class)
     order by e.person_id, e.created_at, e.id
  )
  select v.enrollment_id, v.person_id, v.church_id, v.service_id, v.class_id,
         p.national_id, p.name, p.birthdate, p.gender::text, p.phone, p.address, p.image_url,
         v.points, v.attendance_count,
         extract(day from p.birthdate)::int, extract(month from p.birthdate)::int,
         (p_year - extract(year from p.birthdate)::int),
         coalesce((
           select jsonb_agg(jsonb_build_object(
                    'id', g.id, 'kind', g.kind, 'created_at', g.created_at,
                    'points', g.points, 'message', g.message,
                    'recorded_by', g.recorded_by, 'recorded_by_name', pr.full_name)
                  order by g.created_at desc)
             from public.birthday_greetings g
             left join public.profiles pr on pr.id = g.recorded_by
            where g.person_id = v.person_id and g.year = p_year
         ), '[]'::jsonb),
         (select g.points from public.birthday_greetings g
           where g.person_id = v.person_id and g.year = p_year and g.kind = 'gift' limit 1),
         v.enrollments_count
    from vis v
    join public.persons p on p.id = v.person_id
   order by extract(day from p.birthdate), p.name
$$;
grant execute on function public.birthdays_in_month(integer, integer, uuid, uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 5. RPC: birthdays_upcoming — today + next N days (home widget).
--    Returns the next occurrence of each birthday (Cairo calendar), wraps
--    across December → January, Feb 29 → last day of Feb. RLS applies.
-- ---------------------------------------------------------------------
create or replace function public.next_birthday(p_birthdate date, p_today date)
returns date language sql immutable as $$
  select case when this_year >= p_today then this_year else next_year end
    from (
      select make_date(extract(year from p_today)::int, extract(month from p_birthdate)::int,
               least(extract(day from p_birthdate)::int,
                     extract(day from (date_trunc('month', make_date(extract(year from p_today)::int, extract(month from p_birthdate)::int, 1)) + interval '1 month - 1 day'))::int)) as this_year,
             make_date(extract(year from p_today)::int + 1, extract(month from p_birthdate)::int,
               least(extract(day from p_birthdate)::int,
                     extract(day from (date_trunc('month', make_date(extract(year from p_today)::int + 1, extract(month from p_birthdate)::int, 1)) + interval '1 month - 1 day'))::int)) as next_year
    ) d
$$;

drop function if exists public.birthdays_upcoming(integer, date);
create or replace function public.birthdays_upcoming(p_days integer default 7, p_today date default null)
returns table (
  enrollment_id uuid, person_id uuid, church_id uuid, service_id uuid, class_id uuid,
  name text, phone text, image_url text, birthdate date, next_birthday date, days_left integer, turns_age integer
)
language sql stable security invoker set search_path = public as $$
  with t as (
    select coalesce(p_today, (now() at time zone 'Africa/Cairo')::date) as today
  ),
  vis as (
    select distinct on (e.person_id)
           e.id as enrollment_id, e.person_id, e.church_id, e.service_id, e.class_id
      from public.enrollments e
      join public.persons p on p.id = e.person_id
     where p.birthdate is not null
     order by e.person_id, e.created_at, e.id
  ),
  nb as (
    select v.*, p.name, p.phone, p.image_url, p.birthdate,
           public.next_birthday(p.birthdate, t.today) as next_birthday, t.today
      from vis v
      join public.persons p on p.id = v.person_id
      cross join t
  )
  select enrollment_id, person_id, church_id, service_id, class_id,
         name, phone, image_url, birthdate, next_birthday,
         (next_birthday - today)::int as days_left,
         (extract(year from next_birthday)::int - extract(year from birthdate)::int) as turns_age
    from nb
   where next_birthday - today between 0 and greatest(p_days, 0)
   order by next_birthday, name
$$;
grant execute on function public.birthdays_upcoming(integer, date) to authenticated;

-- ---------------------------------------------------------------------
-- 6. RPC: birthday_gift — give the yearly gift of points (ONE per year)
-- ---------------------------------------------------------------------
create or replace function public.birthday_gift(
  p_enrollment uuid, p_year integer, p_points integer, p_note text default null
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  s record;
  e public.enrollments;
  v_log uuid;
  v_greeting uuid;
begin
  select * into s from public.my_scope();
  if s.role is null then raise exception 'forbidden'; end if;
  if not public.module_visible('birthdays') then raise exception 'module_not_visible'; end if;
  if p_points is null or p_points <= 0 then raise exception 'invalid_points'; end if;

  select * into e from public.enrollments where id = p_enrollment for update;
  if e.id is null then raise exception 'enrollment_not_found'; end if;
  if not public.enrollment_visible(e.church_id, e.service_id, e.class_id, s.role, s.church_id, s.service_id, s.class_id) then
    raise exception 'forbidden';
  end if;
  if exists (select 1 from public.birthday_greetings g where g.person_id = e.person_id and g.year = p_year and g.kind = 'gift') then
    raise exception 'already_gifted';
  end if;

  insert into public.points_log (enrollment_id, cause_id, event_id, delta, recorded_by)
  values (e.id, null, null, p_points, auth.uid())
  returning id into v_log;

  insert into public.birthday_greetings (enrollment_id, person_id, church_id, service_id, class_id, year, kind, message, points, points_log_id, recorded_by)
  values (e.id, e.person_id, e.church_id, e.service_id, e.class_id, p_year, 'gift', p_note, p_points, v_log, auth.uid())
  returning id into v_greeting;

  return jsonb_build_object('greeting_id', v_greeting, 'points_log_id', v_log, 'points', p_points,
                            'balance_after', (select points from public.enrollments where id = e.id));
end $$;
grant execute on function public.birthday_gift(uuid, integer, integer, text) to authenticated;

-- revert a gift (owner / church / service managers)
create or replace function public.birthday_gift_cancel(p_greeting uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  s record;
  g public.birthday_greetings;
begin
  select * into s from public.my_scope();
  if s.role is null or s.role not in ('owner', 'church_manager', 'service_manager') then raise exception 'forbidden'; end if;
  if not public.module_visible('birthdays') then raise exception 'module_not_visible'; end if;
  select * into g from public.birthday_greetings where id = p_greeting and kind = 'gift' for update;
  if g.id is null then raise exception 'not_found'; end if;
  if not public.enrollment_visible(g.church_id, g.service_id, g.class_id, s.role, s.church_id, s.service_id, s.class_id) then
    raise exception 'forbidden';
  end if;
  -- points_log has no delete trigger (same as the store) → compensate with a −points row
  if g.points is not null and g.points > 0 then
    insert into public.points_log (enrollment_id, cause_id, event_id, delta, recorded_by)
    values (g.enrollment_id, null, null, -g.points, auth.uid());
  end if;
  delete from public.birthday_greetings where id = g.id;
  return jsonb_build_object('cancelled', true, 'points', g.points,
                            'balance_after', (select points from public.enrollments where id = g.enrollment_id));
end $$;
grant execute on function public.birthday_gift_cancel(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 7. CHILD PORTAL — label the gift rows in the points list + a small
--    "is it my birthday" RPC for the portal home
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
                    else 'cause'::text end as source,
               case when so.id is not null then 'إستبدال نقاط — ' || so.items_count || ' صنف'
                    when sr.id is not null then 'إلغاء عملية إستبدال — استرداد النقاط'
                    when ea.id is not null then 'امتحان — ' || coalesce(ex.title, '')
                    when bg.id is not null then 'هدية عيد ميلاد 🎂 ' || bg.year
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

-- is today (Cairo) the child's birthday? → the portal shows a greeting +
-- the birthday card of his scope (most specific template; module granted)
create or replace function public.child_portal_birthday(p_national_id text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  p public.persons;
  today date := (now() at time zone 'Africa/Cairo')::date;
  e public.enrollments;
  tpl public.birthday_card_templates;
  ch public.churches;
  sv public.services;
  cl public.classes;
  granted boolean := false;
  nb date;
begin
  p := public.child_portal_person(p_national_id);
  if p.birthdate is null then return jsonb_build_object('is_birthday', false, 'birthdate', null); end if;
  nb := public.next_birthday(p.birthdate, today);

  select * into e from public.enrollments where person_id = p.id order by created_at, id limit 1;
  if e.id is not null then
    granted := public.module_granted_for('birthdays', e.church_id, e.service_id, e.class_id);
    select * into ch from public.churches where id = e.church_id;
    select * into sv from public.services where id = e.service_id;
    select * into cl from public.classes  where id = e.class_id;
    if granted then
      select * into tpl from public.birthday_card_templates t
       where t.church_id = e.church_id
         and (t.service_id is null or t.service_id = e.service_id)
         and (t.class_id is null or t.class_id = e.class_id)
       -- most specific scope wins (class > service > church), then the default flag, then newest
       order by (t.class_id is not null) desc, (t.service_id is not null) desc, t.is_default desc, t.created_at desc
       limit 1;
    end if;
  end if;

  return jsonb_build_object(
    'is_birthday', nb = today,
    'birthdate', p.birthdate,
    'age', extract(year from age(today, p.birthdate))::int,
    'turns_age', extract(year from nb)::int - extract(year from p.birthdate)::int,
    'next_birthday', nb,
    'days_left', (nb - today),
    'module_granted', granted,
    'card', case when tpl.id is null then null else jsonb_build_object(
              'id', tpl.id, 'name', tpl.name, 'design', tpl.design) end,
    'constants', jsonb_build_object(
      'church_name', coalesce(ch.name, ''), 'service_name', coalesce(sv.name, ''),
      'class_name', coalesce(cl.name, ''), 'church_logo_url', ch.logo_url),
    'gift', (select jsonb_build_object('points', g.points, 'created_at', g.created_at)
               from public.birthday_greetings g
              where g.person_id = p.id and g.kind = 'gift' and g.year = extract(year from today)::int
              limit 1)
  );
end $$;
grant execute on function public.child_portal_birthday(text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 8. REALTIME
-- ---------------------------------------------------------------------
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'birthday_greetings') then
    alter publication supabase_realtime add table public.birthday_greetings;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'birthday_card_templates') then
    alter publication supabase_realtime add table public.birthday_card_templates;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'birthday_settings') then
    alter publication supabase_realtime add table public.birthday_settings;
  end if;
end $$;
alter table public.birthday_greetings replica identity full;

commit;
