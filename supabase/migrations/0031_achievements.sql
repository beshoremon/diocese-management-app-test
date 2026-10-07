-- =====================================================================
-- 0031: ACHIEVEMENTS MODULE — الإنجازات (simple v1)
--
-- Administrators define ACHIEVEMENTS and children EARN them (points are
-- added to the existing points system). Deliberately small:
--
--   1. achievements       — name · description · picture · points · scope
--      church → service? → class? → event? (null = all, same semantics as
--      events / causes / store items) · active flag ·
--      kind        : 'normal' (awarded by hand) | 'attendance' (automatic)
--      award_mode  : 'once' | 'multiple' (+ max_awards, min_interval_days)
--      attendance  : rule 'count' (N attendances) | 'streak' (N in a row)
--                    + attendance_target
--   2. user_achievements  — one row per award: enrollment (the child in a
--      church / service / class), achievement, points awarded, date,
--      awarded_by (null = automatic), source, related attendance / event,
--      and the points_log row that carried the points.
--   3. Awarding = ONE security-definer path (achievement_grant) used by the
--      manual RPC (achievement_award) and by the attendance trigger:
--        active → scope applies to the enrollment → module granted →
--        'once' not yet awarded → 'multiple' below max_awards and after
--        min_interval_days → insert points_log (+points, existing trigger
--        updates enrollments.points) → insert user_achievements.
--   4. AUTOMATIC awarding: after every attendance_log insert (the children
--      page, the scanner and the online-class finalize all write there —
--      an event participation IS an attendance row bound to that event)
--      the trigger evaluates the active attendance achievements that apply
--      to the enrollment and awards the ones whose requirement is reached.
--      Progress is measured on the attendance rows recorded AFTER the last
--      award of the same achievement (so a 'multiple' achievement like
--      «every 5 attendances» restarts its count after each award).
--        count  : distinct attended days
--        streak : distinct attended days in a row — a run ends when two
--                 consecutive attended days are more than 7 days apart
--                 (i.e. a weekly occurrence was missed)
--   5. Revoking (achievement_revoke, managers / the awarder): compensating
--      −points row + delete the award row (same pattern as store refunds).
--   6. Child portal: child_portal_achievements(nid) → earned cards +
--      progress of the attendance achievements; child_portal_points learns
--      source 'achievement'.
--
-- Permissions (existing RBAC — role + scope + module grant):
--   view    : module_visible('achievements') + scope_overlaps  (RLS select)
--   create  : module_visible + scope_contains                  (RLS insert)
--   edit    : module_visible + scope_contains                  (RLS update)
--   delete  : module_visible + scope_contains + role in
--             (owner, church_manager, service_manager)         (RLS delete)
--   award   : module_visible + enrollment_visible               (RPC)
--   achievement_permissions() returns the five flags for the caller.
--
-- Idempotent — safe to re-run. Depends on 0019 (my_scope / scope_* /
-- enrollment_visible), 0021 (child portal), 0022 (points_log.event_id),
-- 0024 (module_visible), 0027 (module_granted_for), 0030 (shape of
-- child_portal_points). NO module grant is seeded — the owner enables it
-- per scope in وحدة المالك → صلاحيات الوحدات.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. TABLE: achievements
-- ---------------------------------------------------------------------
create table if not exists public.achievements (
  id                 uuid primary key default gen_random_uuid(),
  church_id          uuid not null references public.churches(id) on delete cascade,
  service_id         uuid references public.services(id) on delete cascade,   -- null = all services
  class_id           uuid references public.classes(id)  on delete cascade,   -- null = all classes
  event_id           uuid references public.events(id)   on delete set null,  -- null = any event
  name               text not null,
  description        text,
  image_url          text,
  points             integer not null default 0 check (points >= 0),
  is_active          boolean not null default true,
  kind               text not null default 'normal' check (kind in ('normal', 'attendance')),
  award_mode         text not null default 'once'   check (award_mode in ('once', 'multiple')),
  max_awards         integer check (max_awards is null or max_awards >= 1),        -- multiple: null = unlimited
  min_interval_days  integer check (min_interval_days is null or min_interval_days >= 0),
  attendance_rule    text check (attendance_rule is null or attendance_rule in ('count', 'streak')),
  attendance_target  integer check (attendance_target is null or attendance_target >= 1),
  sort_order         integer not null default 0,
  created_at         timestamptz not null default now(),
  created_by         uuid references public.profiles(id),
  edited_at          timestamptz not null default now(),
  edited_by          uuid references public.profiles(id),
  constraint achievements_name_not_blank check (length(trim(name)) > 0),
  constraint achievements_scope_chain    check (not (class_id is not null and service_id is null)),
  -- attendance achievements need a rule and a target; normal ones have none
  constraint achievements_attendance_cfg check (
    (kind = 'attendance' and attendance_rule is not null and attendance_target is not null)
    or (kind = 'normal' and attendance_rule is null and attendance_target is null)
  ),
  -- repeat settings only make sense for 'multiple'
  constraint achievements_once_cfg check (
    award_mode = 'multiple' or (max_awards is null and min_interval_days is null)
  )
);

comment on table public.achievements is
  'الإنجازات — إنجاز بنقاط يُمنح للمخدوم يدوياً (normal) أو تلقائياً عند الوصول لعدد حضور / حضور متتالٍ (attendance)';

create index if not exists idx_achievements_church  on public.achievements(church_id);
create index if not exists idx_achievements_service on public.achievements(service_id);
create index if not exists idx_achievements_class   on public.achievements(class_id);
create index if not exists idx_achievements_event   on public.achievements(event_id);
create index if not exists idx_achievements_active  on public.achievements(church_id, is_active, kind);

drop trigger if exists trg_achievements_touch on public.achievements;
create trigger trg_achievements_touch before update on public.achievements
for each row execute function public.touch_edited();

-- the service must belong to the church, the class to the service, and the
-- bound event must be in the same church and overlap the achievement scope
create or replace function public.check_achievement_scope()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.name := trim(new.name);
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
  if new.event_id is not null and not exists (
    select 1 from public.events ev
     where ev.id = new.event_id and ev.church_id = new.church_id
       and (ev.service_id is null or new.service_id is null or ev.service_id = new.service_id)
       and (ev.class_id   is null or new.class_id   is null or ev.class_id   = new.class_id)
  ) then
    raise exception 'event_out_of_scope';
  end if;
  return new;
end $$;

drop trigger if exists trg_achievement_scope on public.achievements;
create trigger trg_achievement_scope before insert or update on public.achievements
for each row execute function public.check_achievement_scope();

-- ---------------------------------------------------------------------
-- 2. TABLE: user_achievements (الإنجازات الممنوحة)
-- ---------------------------------------------------------------------
create table if not exists public.user_achievements (
  id                 uuid primary key default gen_random_uuid(),
  achievement_id     uuid not null references public.achievements(id) on delete cascade,
  enrollment_id      uuid not null references public.enrollments(id)  on delete cascade,   -- the "user"
  person_id          uuid not null references public.persons(id)      on delete cascade,
  -- denormalized scope (from the enrollment) for cheap RLS + realtime filters
  church_id          uuid not null references public.churches(id) on delete cascade,
  service_id         uuid not null references public.services(id) on delete cascade,
  class_id           uuid not null references public.classes(id)  on delete cascade,
  points_awarded     integer not null default 0 check (points_awarded >= 0),
  awarded_at         timestamptz not null default now(),
  awarded_by         uuid references public.profiles(id),             -- null = automatic
  source             text not null default 'manual' check (source in ('manual', 'attendance')),
  attendance_log_id  uuid references public.attendance_log(id) on delete set null,   -- the attendance that completed it
  event_id           uuid references public.events(id) on delete set null,           -- the event it relates to
  points_log_id      uuid references public.points_log(id) on delete set null,       -- the +points row
  note               text
);

comment on table public.user_achievements is
  'الإنجازات الممنوحة — المخدوم (التسجيل) · الإنجاز · النقاط · التاريخ · من منحه · الحضور / المناسبة المرتبطة';

create index if not exists idx_user_achievements_enrollment  on public.user_achievements(enrollment_id, achievement_id, awarded_at desc);
create index if not exists idx_user_achievements_achievement on public.user_achievements(achievement_id, awarded_at desc);
create index if not exists idx_user_achievements_person      on public.user_achievements(person_id, awarded_at desc);
create index if not exists idx_user_achievements_points_log  on public.user_achievements(points_log_id);
create index if not exists idx_user_achievements_church      on public.user_achievements(church_id);
create index if not exists idx_user_achievements_service     on public.user_achievements(service_id);
create index if not exists idx_user_achievements_class       on public.user_achievements(class_id);

-- ---------------------------------------------------------------------
-- 3. RLS — everything requires module_visible('achievements')
-- ---------------------------------------------------------------------
alter table public.achievements      enable row level security;
alter table public.user_achievements enable row level security;

drop policy if exists achievements_select on public.achievements;
create policy achievements_select on public.achievements for select using (
  (select public.module_visible('achievements'))
  and (select public.scope_overlaps(church_id, service_id, class_id))
);
drop policy if exists achievements_insert on public.achievements;
create policy achievements_insert on public.achievements for insert with check (
  (select public.module_visible('achievements'))
  and (select public.scope_contains(church_id, service_id, class_id))
);
drop policy if exists achievements_update on public.achievements;
create policy achievements_update on public.achievements for update using (
  (select public.module_visible('achievements'))
  and (select public.scope_contains(church_id, service_id, class_id))
) with check (
  (select public.module_visible('achievements'))
  and (select public.scope_contains(church_id, service_id, class_id))
);
-- delete: managers only (owner / church manager / service manager)
drop policy if exists achievements_delete on public.achievements;
create policy achievements_delete on public.achievements for delete using (
  (select public.module_visible('achievements'))
  and (select public.scope_contains(church_id, service_id, class_id))
  and (select role from public.my_scope()) in ('owner', 'church_manager', 'service_manager')
);

-- awards: read rows of enrollments I can see; NO insert / update / delete
-- policies — writes go through the RPCs below.
drop policy if exists user_achievements_select on public.user_achievements;
create policy user_achievements_select on public.user_achievements for select using (
  (select public.module_visible('achievements'))
  and public.enrollment_visible(church_id, service_id, class_id,
    (select role from public.my_scope()), (select church_id from public.my_scope()),
    (select service_id from public.my_scope()), (select class_id from public.my_scope()))
);

-- ---------------------------------------------------------------------
-- 4. PERMISSIONS — the five flags for the caller (existing RBAC)
-- ---------------------------------------------------------------------
create or replace function public.achievement_permissions()
returns jsonb language sql stable security definer set search_path = public as $$
  select case
    when (select count(*) from public.my_scope()) = 0 or not public.module_visible('achievements') then
      jsonb_build_object('view', false, 'create', false, 'edit', false, 'delete', false, 'award', false)
    else
      jsonb_build_object(
        'view',   true,
        'create', true,
        'edit',   true,
        'delete', (select role from public.my_scope()) in ('owner', 'church_manager', 'service_manager'),
        'award',  true)
  end
$$;
grant execute on function public.achievement_permissions() to authenticated;

-- ---------------------------------------------------------------------
-- 5. PROGRESS — how far is an enrollment from an achievement?
--    Returns: current, target, awards_count, last_awarded_at, eligible
--    (the rule is reached), block ('inactive' | 'out_of_scope' |
--    'already_awarded' | 'max_reached' | 'too_soon' | null).
--    Attendance rows are counted AFTER the last award (per enrollment).
-- ---------------------------------------------------------------------
create or replace function public.achievement_progress(p_achievement uuid, p_enrollment uuid)
returns table (
  current_value integer, target_value integer, awards_count integer,
  last_awarded_at timestamptz, eligible boolean, block text
) language plpgsql stable security definer set search_path = public as $$
declare
  a      public.achievements;
  e      public.enrollments;
  v_cnt  integer := 0;
  v_last timestamptz;
  v_last_day date;     -- attended day of the attendance that completed the last award
  v_cur  integer := 0;
  v_tgt  integer;
  v_blk  text;
  d      date;
  prev   date;
begin
  select * into a from public.achievements where id = p_achievement;
  select * into e from public.enrollments  where id = p_enrollment;
  if a.id is null or e.id is null then
    return query select 0, 0, 0, null::timestamptz, false, 'not_found'::text;
    return;
  end if;

  select count(*), max(awarded_at) into v_cnt, v_last
    from public.user_achievements
   where achievement_id = a.id and enrollment_id = e.id;
  -- progress restarts AFTER the attendance day that completed the last award
  -- (anchoring on the day, not on awarded_at, keeps back-dated attendance
  -- correct); manual awards without an attendance row anchor on awarded_at.
  select al.attended_on into v_last_day
    from public.user_achievements ua
    left join public.attendance_log al on al.id = ua.attendance_log_id
   where ua.achievement_id = a.id and ua.enrollment_id = e.id
   order by ua.awarded_at desc limit 1;

  if not a.is_active then
    v_blk := 'inactive';
  elsif not (a.church_id = e.church_id
             and (a.service_id is null or a.service_id = e.service_id)
             and (a.class_id   is null or a.class_id   = e.class_id)) then
    v_blk := 'out_of_scope';
  elsif a.award_mode = 'once' and v_cnt > 0 then
    v_blk := 'already_awarded';
  elsif a.award_mode = 'multiple' and a.max_awards is not null and v_cnt >= a.max_awards then
    v_blk := 'max_reached';
  elsif a.award_mode = 'multiple' and a.min_interval_days is not null and v_last is not null
        and v_last + make_interval(days => a.min_interval_days) > now() then
    v_blk := 'too_soon';
  end if;

  if a.kind = 'attendance' then
    v_tgt := a.attendance_target;
    if a.attendance_rule = 'count' then
      select count(distinct al.attended_on) into v_cur
        from public.attendance_log al
       where al.enrollment_id = e.id
         and (a.event_id is null or al.event_id = a.event_id)
         and (v_last is null or (case when v_last_day is not null then al.attended_on > v_last_day else al.created_at > v_last end));
    else
      -- streak: walk the distinct attended days backwards from the latest;
      -- the run breaks when two consecutive days are > 7 days apart
      prev := null;
      for d in
        select distinct al.attended_on
          from public.attendance_log al
         where al.enrollment_id = e.id
           and (a.event_id is null or al.event_id = a.event_id)
           and (v_last is null or (case when v_last_day is not null then al.attended_on > v_last_day else al.created_at > v_last end))
         order by al.attended_on desc
      loop
        if prev is not null and (prev - d) > 7 then exit; end if;
        v_cur := v_cur + 1;
        prev := d;
      end loop;
    end if;
  else
    v_tgt := 1;          -- normal achievements are "reached" by the manual award itself
    v_cur := 0;
  end if;

  return query select v_cur, v_tgt, v_cnt, v_last,
                      (v_blk is null and (a.kind = 'normal' or v_cur >= v_tgt)),
                      v_blk;
end $$;
grant execute on function public.achievement_progress(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 6. GRANT — the single write path (internal; callers check permissions)
--    Returns the new user_achievements id, or NULL when a rule blocks
--    (p_strict = false → silent skip, used by the trigger;
--     p_strict = true  → raise the block as an exception, used manually).
-- ---------------------------------------------------------------------
create or replace function public.achievement_grant(
  p_achievement uuid, p_enrollment uuid, p_by uuid, p_source text,
  p_attendance_log uuid, p_event uuid, p_note text, p_strict boolean)
returns uuid language plpgsql volatile security definer set search_path = public as $$
declare
  a     public.achievements;
  e     public.enrollments;
  pr    record;
  v_pl  uuid;
  v_id  uuid;
begin
  -- lock the enrollment: two servants / two triggers can't double-award
  select * into e from public.enrollments where id = p_enrollment for update;
  if not found then
    if p_strict then raise exception 'enrollment_not_found' using errcode = 'P0002'; end if;
    return null;
  end if;
  select * into a from public.achievements where id = p_achievement;
  if not found then
    if p_strict then raise exception 'achievement_not_found' using errcode = 'P0002'; end if;
    return null;
  end if;

  select * into pr from public.achievement_progress(a.id, e.id);
  if pr.block is not null then
    if p_strict then raise exception '%', pr.block using errcode = 'P0001'; end if;
    return null;
  end if;
  -- automatic path: the requirement must be reached
  if p_source = 'attendance' and not pr.eligible then
    return null;
  end if;

  if a.points > 0 then
    insert into public.points_log (enrollment_id, cause_id, event_id, delta, recorded_by)
    values (e.id, null, coalesce(p_event, a.event_id), a.points, p_by)
    returning id into v_pl;
  end if;

  insert into public.user_achievements (
    achievement_id, enrollment_id, person_id, church_id, service_id, class_id,
    points_awarded, awarded_by, source, attendance_log_id, event_id, points_log_id, note)
  values (
    a.id, e.id, e.person_id, e.church_id, e.service_id, e.class_id,
    a.points, p_by, p_source, p_attendance_log, coalesce(p_event, a.event_id), v_pl,
    nullif(trim(coalesce(p_note, '')), ''))
  returning id into v_id;

  return v_id;
end $$;
revoke all on function public.achievement_grant(uuid, uuid, uuid, text, uuid, uuid, text, boolean) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 7. RPC: achievement_award — a servant awards an achievement by hand
--    Returns { award_id, points, balance_after }
-- ---------------------------------------------------------------------
create or replace function public.achievement_award(
  p_achievement uuid, p_enrollment uuid, p_note text default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  s     record;
  e     public.enrollments;
  a     public.achievements;
  v_id  uuid;
  v_bal integer;
begin
  if auth.uid() is null then raise exception 'forbidden' using errcode = 'P0001'; end if;
  if not public.module_visible('achievements') then
    raise exception 'module_not_visible' using errcode = 'P0001';
  end if;
  select * into s from public.my_scope();
  if not found then raise exception 'forbidden' using errcode = 'P0001'; end if;

  select * into e from public.enrollments where id = p_enrollment;
  if not found then raise exception 'enrollment_not_found' using errcode = 'P0002'; end if;
  if not public.enrollment_visible(e.church_id, e.service_id, e.class_id,
                                   s.role, s.church_id, s.service_id, s.class_id) then
    raise exception 'forbidden' using errcode = 'P0001';
  end if;
  select * into a from public.achievements where id = p_achievement;
  if not found then raise exception 'achievement_not_found' using errcode = 'P0002'; end if;
  -- the caller must at least SEE the achievement (its scope overlaps his)
  if not public.scope_overlaps(a.church_id, a.service_id, a.class_id) then
    raise exception 'forbidden' using errcode = 'P0001';
  end if;

  v_id := public.achievement_grant(a.id, e.id, auth.uid(), 'manual', null, null, p_note, true);
  select points into v_bal from public.enrollments where id = e.id;
  return jsonb_build_object('award_id', v_id, 'points', a.points, 'balance_after', v_bal);
end $$;
grant execute on function public.achievement_award(uuid, uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- 8. RPC: achievement_revoke — undo an award (managers, or the servant
--    who awarded it): compensating −points row + delete the award row
-- ---------------------------------------------------------------------
create or replace function public.achievement_revoke(p_award uuid, p_note text default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  s     record;
  ua    public.user_achievements;
  v_bal integer;
begin
  if auth.uid() is null then raise exception 'forbidden' using errcode = 'P0001'; end if;
  if not public.module_visible('achievements') then
    raise exception 'module_not_visible' using errcode = 'P0001';
  end if;
  select * into s from public.my_scope();
  if not found then raise exception 'forbidden' using errcode = 'P0001'; end if;

  select * into ua from public.user_achievements where id = p_award for update;
  if not found then raise exception 'not_found' using errcode = 'P0002'; end if;
  if not public.enrollment_visible(ua.church_id, ua.service_id, ua.class_id,
                                   s.role, s.church_id, s.service_id, s.class_id) then
    raise exception 'forbidden' using errcode = 'P0001';
  end if;
  if not (s.role in ('owner', 'church_manager', 'service_manager') or ua.awarded_by = auth.uid()) then
    raise exception 'forbidden' using errcode = 'P0001';
  end if;

  if ua.points_awarded > 0 then
    insert into public.points_log (enrollment_id, cause_id, event_id, delta, recorded_by)
    values (ua.enrollment_id, null, ua.event_id, -ua.points_awarded, auth.uid());
  end if;
  delete from public.user_achievements where id = ua.id;

  select points into v_bal from public.enrollments where id = ua.enrollment_id;
  return jsonb_build_object('award_id', ua.id, 'refunded', ua.points_awarded, 'balance_after', v_bal);
end $$;
grant execute on function public.achievement_revoke(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- 9. RPC: achievement_earners — who earned an achievement (names /
--    pictures resolved server-side; RLS-equivalent visibility check)
-- ---------------------------------------------------------------------
create or replace function public.achievement_earners(p_achievement uuid)
returns table (
  id uuid, enrollment_id uuid, person_id uuid, person_name text, person_image text,
  national_id text, class_name text, service_name text, church_name text,
  points_awarded integer, awarded_at timestamptz, awarded_by uuid, awarded_by_name text,
  source text, event_name text, note text
) language plpgsql stable security definer set search_path = public as $$
declare s record;
begin
  if auth.uid() is null or not public.module_visible('achievements') then return; end if;
  select * into s from public.my_scope();
  if not found then return; end if;
  return query
    select ua.id, ua.enrollment_id, ua.person_id, p.name, p.image_url, p.national_id,
           cl.name, sv.name, ch.name,
           ua.points_awarded, ua.awarded_at, ua.awarded_by, pr.full_name,
           ua.source, ev.name, ua.note
      from public.user_achievements ua
      join public.persons  p  on p.id  = ua.person_id
      join public.classes  cl on cl.id = ua.class_id
      join public.services sv on sv.id = ua.service_id
      join public.churches ch on ch.id = ua.church_id
      left join public.profiles pr on pr.id = ua.awarded_by
      left join public.events   ev on ev.id = ua.event_id
     where ua.achievement_id = p_achievement
       and public.enrollment_visible(ua.church_id, ua.service_id, ua.class_id,
                                     s.role, s.church_id, s.service_id, s.class_id)
     order by ua.awarded_at desc;
end $$;
grant execute on function public.achievement_earners(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 10. RPC: achievement_enrollment_progress — for ONE child: every active
--     achievement that applies to his enrollment with progress + block
--     (feeds the servant-side award picker)
-- ---------------------------------------------------------------------
create or replace function public.achievement_enrollment_progress(p_enrollment uuid)
returns table (
  achievement_id uuid, current_value integer, target_value integer,
  awards_count integer, last_awarded_at timestamptz, eligible boolean, block text
) language plpgsql stable security definer set search_path = public as $$
declare
  s record; e public.enrollments; a record;
begin
  if auth.uid() is null or not public.module_visible('achievements') then return; end if;
  select * into s from public.my_scope();
  if not found then return; end if;
  select * into e from public.enrollments where id = p_enrollment;
  if not found or not public.enrollment_visible(e.church_id, e.service_id, e.class_id,
                                                s.role, s.church_id, s.service_id, s.class_id) then
    return;
  end if;
  for a in
    select x.id from public.achievements x
     where x.church_id = e.church_id
       and (x.service_id is null or x.service_id = e.service_id)
       and (x.class_id   is null or x.class_id   = e.class_id)
       and public.scope_overlaps(x.church_id, x.service_id, x.class_id)
     order by x.sort_order, x.name
  loop
    return query
      select a.id, pr.current_value, pr.target_value, pr.awards_count, pr.last_awarded_at, pr.eligible, pr.block
        from public.achievement_progress(a.id, e.id) pr;
  end loop;
end $$;
grant execute on function public.achievement_enrollment_progress(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 11. AUTOMATIC AWARDING — after every attendance_log insert
--     (children page · scanner · online-class finalize). Best effort: an
--     error here must never block the attendance itself.
-- ---------------------------------------------------------------------
create or replace function public.achievements_on_attendance()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  e public.enrollments;
  a record;
begin
  begin
    select * into e from public.enrollments where id = new.enrollment_id;
    if not found then return new; end if;
    -- only where the module is granted for the child's scope
    if not public.module_granted_for('achievements', e.church_id, e.service_id, e.class_id) then
      return new;
    end if;
    for a in
      select x.id, x.event_id from public.achievements x
       where x.is_active and x.kind = 'attendance'
         and x.church_id = e.church_id
         and (x.service_id is null or x.service_id = e.service_id)
         and (x.class_id   is null or x.class_id   = e.class_id)
         and (x.event_id   is null or x.event_id   = new.event_id)
       order by x.sort_order, x.name
    loop
      perform public.achievement_grant(a.id, e.id, new.recorded_by, 'attendance',
                                       new.id, new.event_id, null, false);
    end loop;
  exception when others then
    raise warning 'achievements_on_attendance skipped: %', sqlerrm;
  end;
  return new;
end $$;

-- "zz_" so it runs after the counter trigger (alphabetical firing order)
drop trigger if exists zz_trg_achievements_on_attendance on public.attendance_log;
create trigger zz_trg_achievements_on_attendance after insert on public.attendance_log
for each row execute function public.achievements_on_attendance();

-- ---------------------------------------------------------------------
-- 12. CHILD PORTAL — earned achievements + progress (anon, token = nid)
--     { earned: [...], progress: [...] } — only for enrollments whose scope
--     has the module granted.
-- ---------------------------------------------------------------------
create or replace function public.child_portal_achievements(p_national_id text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  p public.persons;
  v_earned jsonb;
  v_progress jsonb := '[]'::jsonb;
  e record; ach public.achievements; pr record; v_ev text;
begin
  p := public.child_portal_person(p_national_id);

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', ua.id,
           'achievement_id', ua.achievement_id,
           'enrollment_id', ua.enrollment_id,
           'name', ach.name,
           'description', ach.description,
           'image_url', ach.image_url,
           'kind', a.kind,
           'points', ua.points_awarded,
           'awarded_at', ua.awarded_at,
           'source', ua.source,
           'event_name', ev.name,
           'class_name', cl.name,
           'service_name', sv.name,
           'church_name', ch.name
         ) order by ua.awarded_at desc), '[]'::jsonb)
    into v_earned
    from public.user_achievements ua
    join public.achievements a on a.id = ua.achievement_id
    join public.classes  cl on cl.id = ua.class_id
    join public.services sv on sv.id = ua.service_id
    join public.churches ch on ch.id = ua.church_id
    left join public.events ev on ev.id = ua.event_id
   where ua.person_id = p.id
     and public.module_granted_for('achievements', ua.church_id, ua.service_id, ua.class_id);

  for e in
    select en.id, en.church_id, en.service_id, en.class_id, cl.name as class_name
      from public.enrollments en join public.classes cl on cl.id = en.class_id
     where en.person_id = p.id
       and public.module_granted_for('achievements', en.church_id, en.service_id, en.class_id)
  loop
    for ach in
      select x.* from public.achievements x
       where x.is_active and x.kind = 'attendance'
         and x.church_id = e.church_id
         and (x.service_id is null or x.service_id = e.service_id)
         and (x.class_id   is null or x.class_id   = e.class_id)
       order by x.sort_order, x.name
    loop
      select * into pr from public.achievement_progress(ach.id, e.id);
      -- hide what can never be earned again (once + done, or max reached)
      if pr.block in ('already_awarded', 'max_reached') then continue; end if;
      v_ev := null;
      if ach.event_id is not null then select ev.name into v_ev from public.events ev where ev.id = ach.event_id; end if;
      v_progress := v_progress || jsonb_build_object(
        'achievement_id', ach.id,
        'enrollment_id', e.id,
        'class_name', e.class_name,
        'name', ach.name,
        'description', ach.description,
        'image_url', ach.image_url,
        'points', ach.points,
        'rule', ach.attendance_rule,
        'current', pr.current_value,
        'target', pr.target_value,
        'awards_count', pr.awards_count,
        'event_name', v_ev);
    end loop;
  end loop;

  return jsonb_build_object('earned', v_earned, 'progress', v_progress);
end $$;
grant execute on function public.child_portal_achievements(text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 13. CHILD PORTAL — points list learns the 'achievement' source
--     (same shape as 0030)
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
                    else 'cause'::text end as source,
               case when so.id is not null then 'إستبدال نقاط — ' || so.items_count || ' صنف'
                    when sr.id is not null then 'إلغاء عملية إستبدال — استرداد النقاط'
                    when ea.id is not null then 'امتحان — ' || coalesce(ex.title, '')
                    when bg.id is not null then 'هدية عيد ميلاد 🎂 ' || bg.year
                    when oa.id is not null then 'إجابة صحيحة في فصل أونلاين «' || coalesce(oc.title, '') || '»'
                    when ua.id is not null then 'إنجاز 🏆 ' || coalesce(ac.name, '')
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
-- 14. REALTIME
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['achievements', 'user_achievements'] loop
    if not exists (select 1 from pg_publication_tables
                    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;
alter table public.achievements      replica identity full;
alter table public.user_achievements replica identity full;

commit;
