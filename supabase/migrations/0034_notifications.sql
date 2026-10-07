-- =====================================================================
-- 0034: NOTIFICATIONS MODULE — الإشعارات (simple v1)
--
-- Create → choose recipients → send / schedule → receive → history, plus
-- App event → automatic notification. Web-push delivery (device tray) is
-- done by the Next.js API route /api/notifications/dispatch with the
-- VAPID keys; the database only decides WHO gets WHAT and WHEN.
--
--   1. notifications             — one send (manual or automatic): title ·
--      body · image · link · target (all | church | service | class |
--      group | person) · audience (children | staff) · schedule · status
--      (scheduled | sent | failed | cancelled) · recipients_count · source.
--   2. notification_recipients   — one row per recipient (the inbox):
--      enrollment (child) OR profile (servant) · snapshot of the text ·
--      read_at · push_status (pending | sent | failed | no_device).
--   3. notification_automations  — Trigger → Recipient → Notification:
--      trigger_key (attendance · points_added · points_deducted ·
--      online_class_started · exam_published · achievement_earned ·
--      occasion_reminder) · recipient (student | class_servants) ·
--      title / body templates with [variables] · link · scope church →
--      service → class (null = all) · is_active · config (jsonb).
--      Adding a trigger later = one new trigger function that calls
--      notif_fire_enrollment() or notif_fire_scope().
--   4. notification_automation_runs — «fired once» guard.
--   5. push_subscriptions         — one device (Web Push endpoint) bound
--      to a servant (profile_id) or a child (person_id).
--   6. notif_tick()               — materializes due scheduled sends and
--      the occasion reminders; scheduled with pg_cron when available and
--      also called by the dispatch API route.
--
-- Permissions (existing RBAC — role + scope + module grant):
--   see history : module_visible('notifications') + scope_overlaps / own
--   send        : module_visible + scope_contains (all churches = owner;
--                 group = my own group, managers may pick a servant in scope;
--                 person = enrollment_visible)
--   automations : select scope_overlaps · write scope_contains
--   delete      : creator, or owner / church_manager / service_manager in scope
--   inbox       : my own recipient rows (profile_id = auth.uid()); the child
--                 reads through child_notifications(national id).
--
-- Idempotent — safe to re-run. Depends on 0019 (my_scope / scope_* /
-- enrollment_visible), 0021 (child portal), 0024 (module_visible),
-- 0025 (shepherd_groups), 0027 (exams), 0030 (online_classes), 0031
-- (user_achievements), 0032 (occasions). NO module grant is seeded — the
-- owner enables it per scope in وحدة المالك → صلاحيات الوحدات.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. TABLE: notifications
-- ---------------------------------------------------------------------
create table if not exists public.notifications (
  id                 uuid primary key default gen_random_uuid(),
  church_id          uuid references public.churches(id) on delete cascade,   -- null = all churches (owner)
  service_id         uuid references public.services(id) on delete cascade,   -- null = all services
  class_id           uuid references public.classes(id)  on delete cascade,   -- null = all classes
  title              text not null,
  body               text not null default '',
  image_url          text,
  link_url           text,                                                     -- in-app path ('/child/points') or https URL
  target_kind        text not null default 'class'
                     check (target_kind in ('all', 'church', 'service', 'class', 'group', 'person')),
  audience           text not null default 'children' check (audience in ('children', 'staff')),
  target_servant_id  uuid references public.profiles(id) on delete set null,   -- group = this servant's shepherd group
  enrollment_ids     uuid[],                                                   -- person = these enrollments
  status             text not null default 'sent'
                     check (status in ('scheduled', 'sent', 'failed', 'cancelled')),
  scheduled_at       timestamptz,                                              -- null = sent immediately
  sent_at            timestamptz,
  recipients_count   integer not null default 0,
  error              text,
  source             text not null default 'manual' check (source in ('manual', 'automation')),
  automation_id      uuid,                                                     -- fk added after the automations table
  created_at         timestamptz not null default now(),
  created_by         uuid references public.profiles(id) on delete set null,
  constraint notifications_title_not_blank check (length(trim(title)) > 0),
  constraint notifications_title_len       check (length(title) <= 120),
  constraint notifications_body_len        check (length(body) <= 1000),
  constraint notifications_scope_chain     check (not (class_id is not null and service_id is null)),
  constraint notifications_scope_chain2    check (not (service_id is not null and church_id is null))
);

comment on table public.notifications is
  'الإشعارات — إرسال واحد (يدوي أو تلقائي): عنوان، نص، صورة، رابط، المستلمون (كنيسة / خدمة / فصل / مجموعة / مخدوم)، موعد الإرسال، الحالة';

create index if not exists idx_notifications_church     on public.notifications(church_id, created_at desc);
create index if not exists idx_notifications_created_by on public.notifications(created_by, created_at desc);
create index if not exists idx_notifications_scheduled  on public.notifications(scheduled_at) where status = 'scheduled';
create index if not exists idx_notifications_source     on public.notifications(source, created_at desc);

-- ---------------------------------------------------------------------
-- 2. TABLE: notification_recipients (the inbox rows)
-- ---------------------------------------------------------------------
create table if not exists public.notification_recipients (
  id               uuid primary key default gen_random_uuid(),
  notification_id  uuid not null references public.notifications(id) on delete cascade,
  enrollment_id    uuid references public.enrollments(id) on delete cascade,
  person_id        uuid references public.persons(id)     on delete cascade,   -- child recipient
  profile_id       uuid references public.profiles(id)    on delete cascade,   -- servant recipient
  title            text not null,
  body             text not null default '',
  image_url        text,
  link_url         text,
  read_at          timestamptz,
  push_status      text not null default 'pending'
                   check (push_status in ('pending', 'sent', 'failed', 'no_device')),
  push_error       text,
  pushed_at        timestamptz,
  created_at       timestamptz not null default now(),
  constraint notif_recipient_one_target check (
    (person_id is not null and profile_id is null) or (person_id is null and profile_id is not null)
  )
);

comment on table public.notification_recipients is
  'مستلمو الإشعار — صف لكل مستلم (مخدوم أو خادم) مع نسخة من النص وحالة القراءة وحالة إشعار الجهاز';

create index if not exists idx_notif_rcpt_notification on public.notification_recipients(notification_id);
create index if not exists idx_notif_rcpt_person       on public.notification_recipients(person_id, created_at desc);
create index if not exists idx_notif_rcpt_profile      on public.notification_recipients(profile_id, created_at desc);
create index if not exists idx_notif_rcpt_push_pending on public.notification_recipients(created_at) where push_status = 'pending';

-- ---------------------------------------------------------------------
-- 3. TABLE: notification_automations (Trigger → Recipient → Notification)
-- ---------------------------------------------------------------------
create table if not exists public.notification_automations (
  id              uuid primary key default gen_random_uuid(),
  church_id       uuid references public.churches(id) on delete cascade,   -- null = all churches (owner)
  service_id      uuid references public.services(id) on delete cascade,   -- null = all services
  class_id        uuid references public.classes(id)  on delete cascade,   -- null = all classes
  trigger_key     text not null check (trigger_key in (
                    'attendance', 'points_added', 'points_deducted', 'online_class_started',
                    'exam_published', 'achievement_earned', 'occasion_reminder')),
  recipient       text not null default 'student' check (recipient in ('student', 'class_servants')),
  name            text not null,
  title_template  text not null,
  body_template   text not null default '',
  image_url       text,
  link_url        text,                    -- null = the trigger's default page
  is_active       boolean not null default true,
  config          jsonb not null default '{}'::jsonb,   -- e.g. {"min_points": 5, "hours_before": 24}
  created_at      timestamptz not null default now(),
  created_by      uuid references public.profiles(id) on delete set null,
  edited_at       timestamptz not null default now(),
  edited_by       uuid references public.profiles(id) on delete set null,
  constraint notif_auto_name_not_blank  check (length(trim(name)) > 0),
  constraint notif_auto_title_not_blank check (length(trim(title_template)) > 0),
  constraint notif_auto_title_len       check (length(title_template) <= 120),
  constraint notif_auto_body_len        check (length(body_template) <= 1000),
  constraint notif_auto_scope_chain     check (not (class_id is not null and service_id is null)),
  constraint notif_auto_scope_chain2    check (not (service_id is not null and church_id is null))
);

comment on table public.notification_automations is
  'الإشعارات التلقائية — حدث في التطبيق ← مستلم ← إشعار بقالب فيه متغيرات مثل [الاسم] و[النقاط]';

create index if not exists idx_notif_auto_trigger on public.notification_automations(trigger_key, is_active);
create index if not exists idx_notif_auto_church  on public.notification_automations(church_id);

drop trigger if exists trg_notif_auto_touch on public.notification_automations;
create trigger trg_notif_auto_touch before update on public.notification_automations
for each row execute function public.touch_edited();

do $$ begin
  alter table public.notifications
    add constraint notifications_automation_fk
    foreign key (automation_id) references public.notification_automations(id) on delete set null;
exception when duplicate_object then null; end $$;

-- «fired once» guard for the automations
create table if not exists public.notification_automation_runs (
  automation_id uuid not null references public.notification_automations(id) on delete cascade,
  ref_key       text not null,          -- 'exam:<id>' · 'online:<id>:<day>' · 'occasion:<id>' · 'att:<event>:<day>:<enrollment>'
  fired_at      timestamptz not null default now(),
  primary key (automation_id, ref_key)
);

-- ---------------------------------------------------------------------
-- 4. TABLE: push_subscriptions (one device)
-- ---------------------------------------------------------------------
create table if not exists public.push_subscriptions (
  id            uuid primary key default gen_random_uuid(),
  endpoint      text not null unique,
  p256dh        text not null,
  auth          text not null,
  profile_id    uuid references public.profiles(id) on delete cascade,   -- servant device
  person_id     uuid references public.persons(id)  on delete cascade,   -- child device
  user_agent    text,
  created_at    timestamptz not null default now(),
  last_seen_at  timestamptz not null default now(),
  failed_at     timestamptz,
  constraint push_sub_one_owner check (
    (profile_id is not null and person_id is null) or (profile_id is null and person_id is not null)
  )
);

comment on table public.push_subscriptions is
  'اشتراكات إشعارات الجهاز (Web Push) — جهاز واحد لخادم أو لمخدوم';

create index if not exists idx_push_sub_profile on public.push_subscriptions(profile_id);
create index if not exists idx_push_sub_person  on public.push_subscriptions(person_id);

-- scope chain checks (service ∈ church, class ∈ service)
create or replace function public.check_notif_scope()
returns trigger language plpgsql security definer set search_path = public as $$
begin
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

drop trigger if exists trg_notifications_scope on public.notifications;
create trigger trg_notifications_scope before insert or update on public.notifications
for each row execute function public.check_notif_scope();
drop trigger if exists trg_notif_auto_scope on public.notification_automations;
create trigger trg_notif_auto_scope before insert or update on public.notification_automations
for each row execute function public.check_notif_scope();

-- ---------------------------------------------------------------------
-- 5. RLS
-- ---------------------------------------------------------------------
alter table public.notifications                enable row level security;
alter table public.notification_recipients      enable row level security;
alter table public.notification_automations     enable row level security;
alter table public.notification_automation_runs enable row level security;
alter table public.push_subscriptions           enable row level security;

-- notifications: history is visible inside my scope (or my own sends)
drop policy if exists notifications_select on public.notifications;
create policy notifications_select on public.notifications for select using (
  public.module_visible('notifications') and (
    created_by = auth.uid()
    or (church_id is null and public.is_owner())
    or (church_id is not null and public.scope_overlaps(church_id, service_id, class_id))
  )
);
-- writes go through notif_send / notif_cancel (security definer); deleting = creator or managers in scope
drop policy if exists notifications_delete on public.notifications;
create policy notifications_delete on public.notifications for delete using (
  public.module_visible('notifications') and (
    created_by = auth.uid()
    or (public.my_role() in ('owner', 'church_manager', 'service_manager')
        and ((church_id is null and public.is_owner()) or public.scope_contains(church_id, service_id, class_id)))
  )
);

-- recipients: a servant reads his own inbox rows; senders / managers read the
-- delivery rows of the notifications they can see (for the history counts)
drop policy if exists notif_rcpt_select on public.notification_recipients;
create policy notif_rcpt_select on public.notification_recipients for select using (
  profile_id = auth.uid()
  -- delivery rows of a send I made, or (managers) of any send visible to me — RLS of notifications applies
  or exists (select 1 from public.notifications n
              where n.id = notification_id
                and (n.created_by = auth.uid() or public.my_role() in ('owner', 'church_manager', 'service_manager')))
);
drop policy if exists notif_rcpt_update on public.notification_recipients;
create policy notif_rcpt_update on public.notification_recipients for update using (
  profile_id = auth.uid()
) with check (
  profile_id = auth.uid()
);

-- automations
drop policy if exists notif_auto_select on public.notification_automations;
create policy notif_auto_select on public.notification_automations for select using (
  public.module_visible('notifications') and (
    church_id is null or public.scope_overlaps(church_id, service_id, class_id)
  )
);
drop policy if exists notif_auto_insert on public.notification_automations;
create policy notif_auto_insert on public.notification_automations for insert with check (
  public.module_visible('notifications')
  and ((church_id is null and public.is_owner()) or public.scope_contains(church_id, service_id, class_id))
);
drop policy if exists notif_auto_update on public.notification_automations;
create policy notif_auto_update on public.notification_automations for update using (
  public.module_visible('notifications')
  and ((church_id is null and public.is_owner()) or public.scope_contains(church_id, service_id, class_id))
) with check (
  public.module_visible('notifications')
  and ((church_id is null and public.is_owner()) or public.scope_contains(church_id, service_id, class_id))
);
drop policy if exists notif_auto_delete on public.notification_automations;
create policy notif_auto_delete on public.notification_automations for delete using (
  public.module_visible('notifications')
  and ((church_id is null and public.is_owner()) or public.scope_contains(church_id, service_id, class_id))
);

drop policy if exists notif_auto_runs_select on public.notification_automation_runs;
create policy notif_auto_runs_select on public.notification_automation_runs for select using (
  exists (select 1 from public.notification_automations a where a.id = automation_id)
);

-- push subscriptions: my own devices only (children use the anon RPCs)
drop policy if exists push_sub_select on public.push_subscriptions;
create policy push_sub_select on public.push_subscriptions for select using (profile_id = auth.uid());
drop policy if exists push_sub_insert on public.push_subscriptions;
create policy push_sub_insert on public.push_subscriptions for insert with check (profile_id = auth.uid());
drop policy if exists push_sub_update on public.push_subscriptions;
create policy push_sub_update on public.push_subscriptions for update using (profile_id = auth.uid()) with check (profile_id = auth.uid());
drop policy if exists push_sub_delete on public.push_subscriptions;
create policy push_sub_delete on public.push_subscriptions for delete using (profile_id = auth.uid());

-- the anon role never reads these tables directly
revoke all on public.notifications, public.notification_recipients, public.notification_automations,
           public.notification_automation_runs, public.push_subscriptions from anon;

-- ---------------------------------------------------------------------
-- 6. HELPERS
-- ---------------------------------------------------------------------
-- [متغير] substitution: every key of p_vars replaces "[key]" in the text
create or replace function public.notif_render(p_text text, p_vars jsonb)
returns text language plpgsql immutable as $$
declare
  k text; v text; out text := coalesce(p_text, '');
begin
  if p_vars is null then return out; end if;
  for k, v in select key, value from jsonb_each_text(p_vars) loop
    out := replace(out, '[' || k || ']', coalesce(v, ''));
  end loop;
  return out;
end $$;

-- link must be an in-app path or an https URL
create or replace function public.notif_clean_link(p text)
returns text language sql immutable as $$
  select case
    when p is null or length(trim(p)) = 0 then null
    when trim(p) like '/%' or trim(p) like 'https://%' then left(trim(p), 500)
    else null end
$$;

-- «كنيسة ← خدمة ← فصل» label of a target, for the history list
create or replace function public.notif_target_label(
  p_kind text, p_church uuid, p_service uuid, p_class uuid, p_servant uuid, p_ids uuid[], p_audience text)
returns text language sql stable security definer set search_path = public as $$
  select case p_kind
    when 'all'     then case when p_audience = 'staff' then 'كل الخدام' else 'كل الكنائس' end
    when 'church'  then coalesce((select 'كنيسة ' || name from public.churches where id = p_church), 'كنيسة')
    when 'service' then coalesce((select 'خدمة ' || name from public.services where id = p_service), 'خدمة')
    when 'class'   then coalesce((select 'فصل ' || name from public.classes where id = p_class), 'فصل')
    when 'group'   then coalesce((select 'مجموعة ' || full_name from public.profiles where id = p_servant), 'مجموعة')
    when 'person'  then case
      when coalesce(array_length(p_ids, 1), 0) = 1 then coalesce((
        select pe.name from public.enrollments e join public.persons pe on pe.id = e.person_id where e.id = p_ids[1]), 'مخدوم')
      else coalesce(array_length(p_ids, 1), 0) || ' مخدوم' end
    else p_kind end
    || case when p_audience = 'staff' and p_kind <> 'all' then ' (الخدام)' else '' end
$$;

-- the servant profiles that cover a scope (recipient = staff / class_servants)
create or replace function public.notif_staff_in_scope(p_church uuid, p_service uuid, p_class uuid)
returns setof uuid language sql stable security definer set search_path = public as $$
  select t.id from public.profiles t
   where t.status = 'approved' and t.role <> 'owner'
     and (p_church is null or t.church_id = p_church)
     and (p_service is null or t.service_id is null or t.service_id = p_service)
     and (p_class   is null or t.class_id   is null or t.class_id   = p_class)
$$;

-- ---------------------------------------------------------------------
-- 7. MATERIALIZE the recipient rows of a notification (internal)
-- ---------------------------------------------------------------------
create or replace function public.notif_materialize(p_id uuid)
returns integer language plpgsql volatile security definer set search_path = public as $$
declare
  n public.notifications;
  cnt integer := 0;
begin
  select * into n from public.notifications where id = p_id for update;
  if not found then return 0; end if;
  delete from public.notification_recipients where notification_id = n.id;

  if n.audience = 'staff' then
    insert into public.notification_recipients (notification_id, profile_id, title, body, image_url, link_url)
    select n.id, t, n.title, n.body, n.image_url, n.link_url
      from public.notif_staff_in_scope(n.church_id, n.service_id, n.class_id) t
     where t is distinct from n.created_by;
    get diagnostics cnt = row_count;
  else
    insert into public.notification_recipients (notification_id, enrollment_id, person_id, title, body, image_url, link_url)
    select n.id, e.id, e.person_id, n.title, n.body, n.image_url, n.link_url
      from public.enrollments e
     where case n.target_kind
             when 'person' then e.id = any(coalesce(n.enrollment_ids, '{}'))
             when 'group'  then exists (select 1 from public.shepherd_groups g where g.enrollment_id = e.id and g.servant_id = n.target_servant_id)
             else (n.church_id  is null or e.church_id  = n.church_id)
              and (n.service_id is null or e.service_id = n.service_id)
              and (n.class_id   is null or e.class_id   = n.class_id)
           end;
    get diagnostics cnt = row_count;
  end if;

  update public.notifications
     set status = case when cnt > 0 then 'sent' else 'failed' end,
         error  = case when cnt > 0 then null else 'no_recipients' end,
         sent_at = now(), recipients_count = cnt
   where id = n.id;
  return cnt;
end $$;
revoke all on function public.notif_materialize(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 8. RPC: notif_audience_count — preview «سيصل إلى N» before sending
-- ---------------------------------------------------------------------
create or replace function public.notif_audience_count(p jsonb)
returns integer language plpgsql stable security definer set search_path = public as $$
declare
  v_kind     text := coalesce(p->>'target_kind', 'class');
  v_aud      text := coalesce(p->>'audience', 'children');
  v_church   uuid := nullif(p->>'church_id', '')::uuid;
  v_service  uuid := nullif(p->>'service_id', '')::uuid;
  v_class    uuid := nullif(p->>'class_id', '')::uuid;
  v_servant  uuid := coalesce(nullif(p->>'target_servant_id', '')::uuid, auth.uid());
  v_ids      uuid[];
  s record;
begin
  if not public.module_visible('notifications') then return 0; end if;
  select * into s from public.my_scope();
  if not found then return 0; end if;
  if p ? 'enrollment_ids' and jsonb_typeof(p->'enrollment_ids') = 'array' then
    select array_agg(distinct x::uuid) into v_ids from jsonb_array_elements_text(p->'enrollment_ids') x;
  end if;

  if v_aud = 'staff' then
    if v_kind = 'all' and s.role <> 'owner' then return 0; end if;
    if v_kind <> 'all' and not public.scope_contains(v_church, v_service, v_class) then return 0; end if;
    return (select count(*)::int from public.notif_staff_in_scope(v_church, v_service, v_class) t where t <> auth.uid());
  end if;

  return (
    select count(*)::int from public.enrollments e
     where case v_kind
             when 'person' then e.id = any(coalesce(v_ids, '{}'))
               and public.enrollment_visible(e.church_id, e.service_id, e.class_id, s.role, s.church_id, s.service_id, s.class_id)
             when 'group'  then exists (select 1 from public.shepherd_groups g where g.enrollment_id = e.id and g.servant_id = v_servant)
               and public.enrollment_visible(e.church_id, e.service_id, e.class_id, s.role, s.church_id, s.service_id, s.class_id)
             when 'all'    then s.role = 'owner'
             else public.scope_contains(v_church, v_service, v_class)
              and (v_church  is null or e.church_id  = v_church)
              and (v_service is null or e.service_id = v_service)
              and (v_class   is null or e.class_id   = v_class)
           end);
end $$;
grant execute on function public.notif_audience_count(jsonb) to authenticated;

-- ---------------------------------------------------------------------
-- 9. RPC: notif_send — the ONE write entry for servants
--    p: { title, body?, image_url?, link_url?, audience?: 'children'|'staff',
--         target_kind: 'all'|'church'|'service'|'class'|'group'|'person',
--         church_id?, service_id?, class_id?, target_servant_id?,
--         enrollment_ids?: uuid[], scheduled_at?: timestamptz }
-- ---------------------------------------------------------------------
create or replace function public.notif_send(p jsonb)
returns public.notifications language plpgsql volatile security definer set search_path = public as $$
declare
  v_uid      uuid := auth.uid();
  v_title    text := trim(coalesce(p->>'title', ''));
  v_body     text := trim(coalesce(p->>'body', ''));
  v_image    text := nullif(trim(coalesce(p->>'image_url', '')), '');
  v_link     text := public.notif_clean_link(p->>'link_url');
  v_kind     text := coalesce(p->>'target_kind', 'class');
  v_aud      text := coalesce(p->>'audience', 'children');
  v_church   uuid := nullif(p->>'church_id', '')::uuid;
  v_service  uuid := nullif(p->>'service_id', '')::uuid;
  v_class    uuid := nullif(p->>'class_id', '')::uuid;
  v_servant  uuid := nullif(p->>'target_servant_id', '')::uuid;
  v_when     timestamptz := nullif(p->>'scheduled_at', '')::timestamptz;
  v_ids      uuid[];
  v_id       uuid;
  e          public.enrollments;
  t          public.profiles;
  s          record;
  n          public.notifications;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if not public.module_visible('notifications') then raise exception 'module_not_visible' using errcode = '42501'; end if;
  select * into s from public.my_scope();
  if not found then raise exception 'not_approved' using errcode = '42501'; end if;
  if length(v_title) = 0 then raise exception 'empty_title' using errcode = '22023'; end if;
  if length(v_title) > 120 or length(v_body) > 1000 then raise exception 'text_too_long' using errcode = '22023'; end if;
  if v_aud not in ('children', 'staff') then raise exception 'bad_audience' using errcode = '22023'; end if;
  if v_when is not null and v_when < now() - interval '1 minute' then raise exception 'schedule_in_past' using errcode = '22023'; end if;
  if v_when is not null and v_when < now() + interval '30 seconds' then v_when := null; end if;   -- «now» in effect

  -- normalize the scope per target kind + permission check
  if v_kind = 'all' then
    if s.role <> 'owner' then raise exception 'scope_not_allowed' using errcode = '42501'; end if;
    v_church := null; v_service := null; v_class := null;
  elsif v_kind = 'church' then
    v_service := null; v_class := null;
    if v_church is null or not public.scope_contains(v_church, null, null) then raise exception 'scope_not_allowed' using errcode = '42501'; end if;
  elsif v_kind = 'service' then
    v_class := null;
    if v_church is null or v_service is null or not public.scope_contains(v_church, v_service, null) then raise exception 'scope_not_allowed' using errcode = '42501'; end if;
  elsif v_kind = 'class' then
    if v_church is null or v_service is null or v_class is null or not public.scope_contains(v_church, v_service, v_class) then raise exception 'scope_not_allowed' using errcode = '42501'; end if;
  elsif v_kind = 'group' then
    if v_aud = 'staff' then raise exception 'bad_target' using errcode = '22023'; end if;
    v_servant := coalesce(v_servant, v_uid);
    if v_servant <> v_uid then
      select * into t from public.profiles where id = v_servant;
      if not found or s.role = 'class_servant' or not public.can_access(t.church_id, t.service_id, t.class_id) then
        raise exception 'scope_not_allowed' using errcode = '42501';
      end if;
    end if;
    -- keep the group's scope for the history label
    select g.church_id, g.service_id, g.class_id into v_church, v_service, v_class
      from public.shepherd_groups g where g.servant_id = v_servant limit 1;
    if v_church is null then v_service := null; v_class := null; end if;
    if v_service is not null and exists (select 1 from public.shepherd_groups g where g.servant_id = v_servant and g.service_id <> v_service) then v_service := null; v_class := null; end if;
    if v_class is not null and exists (select 1 from public.shepherd_groups g where g.servant_id = v_servant and g.class_id <> v_class) then v_class := null; end if;
  elsif v_kind = 'person' then
    if v_aud = 'staff' then raise exception 'bad_target' using errcode = '22023'; end if;
    if not (p ? 'enrollment_ids' and jsonb_typeof(p->'enrollment_ids') = 'array' and jsonb_array_length(p->'enrollment_ids') > 0) then
      raise exception 'no_recipients' using errcode = '22023';
    end if;
    select array_agg(distinct x::uuid) into v_ids from jsonb_array_elements_text(p->'enrollment_ids') x;
    if array_length(v_ids, 1) > 500 then raise exception 'too_many_recipients' using errcode = '22023'; end if;
    v_church := null; v_service := null; v_class := null;
    foreach v_id in array v_ids loop
      select * into e from public.enrollments where id = v_id;
      if not found then raise exception 'enrollment_not_found' using errcode = 'P0002'; end if;
      if not public.enrollment_visible(e.church_id, e.service_id, e.class_id, s.role, s.church_id, s.service_id, s.class_id) then
        raise exception 'enrollment_not_visible' using errcode = '42501';
      end if;
      if array_length(v_ids, 1) = 1 then v_church := e.church_id; v_service := e.service_id; v_class := e.class_id; end if;
    end loop;
  else
    raise exception 'bad_target' using errcode = '22023';
  end if;

  insert into public.notifications (church_id, service_id, class_id, title, body, image_url, link_url, target_kind, audience,
                                    target_servant_id, enrollment_ids, status, scheduled_at, source, created_by)
  values (v_church, v_service, v_class, v_title, v_body, v_image, v_link, v_kind, v_aud,
          case when v_kind = 'group' then v_servant end, v_ids,
          case when v_when is null then 'sent' else 'scheduled' end, v_when, 'manual', v_uid)
  returning * into n;

  if v_when is null then
    perform public.notif_materialize(n.id);
    select * into n from public.notifications where id = n.id;
  end if;
  return n;
end $$;
grant execute on function public.notif_send(jsonb) to authenticated;

-- cancel a scheduled send (creator or managers in scope)
create or replace function public.notif_cancel(p_id uuid)
returns public.notifications language plpgsql volatile security definer set search_path = public as $$
declare
  n public.notifications; s record;
begin
  if not public.module_visible('notifications') then raise exception 'module_not_visible' using errcode = '42501'; end if;
  select * into s from public.my_scope();
  select * into n from public.notifications where id = p_id for update;
  if not found then raise exception 'not_found' using errcode = 'P0002'; end if;
  if n.status <> 'scheduled' then raise exception 'not_scheduled' using errcode = 'P0001'; end if;
  if not (n.created_by = auth.uid()
          or (s.role in ('owner', 'church_manager', 'service_manager')
              and ((n.church_id is null and s.role = 'owner') or public.scope_contains(n.church_id, n.service_id, n.class_id)))) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  update public.notifications set status = 'cancelled' where id = n.id returning * into n;
  return n;
end $$;
grant execute on function public.notif_cancel(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 10. RPC: notif_history — sent / scheduled / failed list for the servant
-- ---------------------------------------------------------------------
create or replace function public.notif_history(p_limit integer default 60, p_before timestamptz default null)
returns jsonb language sql stable security definer set search_path = public as $$
  select case when not public.module_visible('notifications') then '[]'::jsonb else coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', n.id, 'title', n.title, 'body', n.body, 'image_url', n.image_url, 'link_url', n.link_url,
             'target_kind', n.target_kind, 'audience', n.audience,
             'church_id', n.church_id, 'service_id', n.service_id, 'class_id', n.class_id,
             'target_label', public.notif_target_label(n.target_kind, n.church_id, n.service_id, n.class_id, n.target_servant_id, n.enrollment_ids, n.audience),
             'status', n.status, 'scheduled_at', n.scheduled_at, 'sent_at', n.sent_at, 'created_at', n.created_at,
             'recipients_count', n.recipients_count, 'error', n.error, 'source', n.source,
             'automation_id', n.automation_id, 'automation_name', a.name,
             'sender_name', sp.full_name, 'is_mine', n.created_by = auth.uid(),
             'read_count', (select count(*) from public.notification_recipients r where r.notification_id = n.id and r.read_at is not null),
             'push_sent',  (select count(*) from public.notification_recipients r where r.notification_id = n.id and r.push_status = 'sent'),
             'can_cancel', n.status = 'scheduled' and (n.created_by = auth.uid() or public.my_role() in ('owner', 'church_manager', 'service_manager'))
           ) order by coalesce(n.scheduled_at, n.created_at) desc)
      from (
        select * from public.notifications n
         where (p_before is null or coalesce(n.scheduled_at, n.created_at) < p_before)
           and (n.created_by = auth.uid()
                or (n.church_id is null and public.is_owner())
                or (n.church_id is not null and public.scope_overlaps(n.church_id, n.service_id, n.class_id)))
         order by coalesce(n.scheduled_at, n.created_at) desc
         limit greatest(1, least(coalesce(p_limit, 60), 200))
      ) n
      left join public.profiles sp on sp.id = n.created_by
      left join public.notification_automations a on a.id = n.automation_id
  ), '[]'::jsonb) end
$$;
grant execute on function public.notif_history(integer, timestamptz) to authenticated;

-- ---------------------------------------------------------------------
-- 11. SERVANT INBOX (the bell) — my own recipient rows
-- ---------------------------------------------------------------------
create or replace function public.notif_inbox(p_limit integer default 50)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', r.id, 'notification_id', r.notification_id, 'title', r.title, 'body', r.body,
             'image_url', r.image_url, 'link_url', r.link_url, 'read_at', r.read_at, 'created_at', r.created_at,
             'sender_name', sp.full_name, 'source', n.source
           ) order by r.created_at desc)
      from (select * from public.notification_recipients where profile_id = auth.uid()
             order by created_at desc limit greatest(1, least(coalesce(p_limit, 50), 200))) r
      left join public.notifications n on n.id = r.notification_id
      left join public.profiles sp on sp.id = n.created_by
  ), '[]'::jsonb)
$$;
grant execute on function public.notif_inbox(integer) to authenticated;

create or replace function public.notif_unread_count()
returns integer language sql stable security definer set search_path = public as $$
  select count(*)::int from public.notification_recipients where profile_id = auth.uid() and read_at is null
$$;
grant execute on function public.notif_unread_count() to authenticated;

-- p_ids null = mark everything read
create or replace function public.notif_mark_read(p_ids uuid[] default null)
returns integer language plpgsql volatile security definer set search_path = public as $$
declare n integer;
begin
  update public.notification_recipients
     set read_at = now()
   where profile_id = auth.uid() and read_at is null
     and (p_ids is null or id = any(p_ids));
  get diagnostics n = row_count;
  return n;
end $$;
grant execute on function public.notif_mark_read(uuid[]) to authenticated;

-- ---------------------------------------------------------------------
-- 12. CHILD PORTAL (anon, token = national id)
-- ---------------------------------------------------------------------
create or replace function public.child_notifications(p_national_id text, p_limit integer default 50)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare p public.persons;
begin
  p := public.child_portal_person(p_national_id);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', r.id, 'notification_id', r.notification_id, 'title', r.title, 'body', r.body,
             'image_url', r.image_url, 'link_url', r.link_url, 'read_at', r.read_at, 'created_at', r.created_at,
             'sender_name', sp.full_name, 'source', n.source
           ) order by r.created_at desc)
      from (select * from public.notification_recipients where person_id = p.id
             order by created_at desc limit greatest(1, least(coalesce(p_limit, 50), 200))) r
      left join public.notifications n on n.id = r.notification_id
      left join public.profiles sp on sp.id = n.created_by
  ), '[]'::jsonb);
end $$;
grant execute on function public.child_notifications(text, integer) to anon, authenticated;

create or replace function public.child_notif_unread(p_national_id text)
returns integer language plpgsql stable security definer set search_path = public as $$
declare p public.persons;
begin
  p := public.child_portal_person(p_national_id);
  return (select count(*)::int from public.notification_recipients where person_id = p.id and read_at is null);
end $$;
grant execute on function public.child_notif_unread(text) to anon, authenticated;

create or replace function public.child_notif_mark_read(p_national_id text, p_ids uuid[] default null)
returns integer language plpgsql volatile security definer set search_path = public as $$
declare p public.persons; n integer;
begin
  p := public.child_portal_person(p_national_id);
  update public.notification_recipients set read_at = now()
   where person_id = p.id and read_at is null and (p_ids is null or id = any(p_ids));
  get diagnostics n = row_count;
  return n;
end $$;
grant execute on function public.child_notif_mark_read(text, uuid[]) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 13. PUSH SUBSCRIPTIONS (device registration)
-- ---------------------------------------------------------------------
-- servant: {endpoint, keys:{p256dh, auth}, user_agent?}
create or replace function public.push_subscribe(p jsonb)
returns uuid language plpgsql volatile security definer set search_path = public as $$
declare
  v_endpoint text := trim(coalesce(p->>'endpoint', ''));
  v_p256 text := coalesce(p->'keys'->>'p256dh', p->>'p256dh');
  v_auth text := coalesce(p->'keys'->>'auth', p->>'auth');
  v_id uuid;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if v_endpoint not like 'https://%' or v_p256 is null or v_auth is null then raise exception 'bad_subscription' using errcode = '22023'; end if;
  insert into public.push_subscriptions (endpoint, p256dh, auth, profile_id, person_id, user_agent)
  values (v_endpoint, v_p256, v_auth, auth.uid(), null, left(p->>'user_agent', 300))
  on conflict (endpoint) do update
    set p256dh = excluded.p256dh, auth = excluded.auth, profile_id = excluded.profile_id, person_id = null,
        user_agent = excluded.user_agent, last_seen_at = now(), failed_at = null
  returning id into v_id;
  return v_id;
end $$;
grant execute on function public.push_subscribe(jsonb) to authenticated;

create or replace function public.push_unsubscribe(p_endpoint text)
returns boolean language plpgsql volatile security definer set search_path = public as $$
begin
  delete from public.push_subscriptions where endpoint = p_endpoint and profile_id = auth.uid();
  return found;
end $$;
grant execute on function public.push_unsubscribe(text) to authenticated;

-- child device (anon, token = national id)
create or replace function public.child_push_subscribe(p_national_id text, p jsonb)
returns uuid language plpgsql volatile security definer set search_path = public as $$
declare
  pe public.persons;
  v_endpoint text := trim(coalesce(p->>'endpoint', ''));
  v_p256 text := coalesce(p->'keys'->>'p256dh', p->>'p256dh');
  v_auth text := coalesce(p->'keys'->>'auth', p->>'auth');
  v_id uuid;
begin
  pe := public.child_portal_person(p_national_id);
  if v_endpoint not like 'https://%' or v_p256 is null or v_auth is null then raise exception 'bad_subscription' using errcode = '22023'; end if;
  insert into public.push_subscriptions (endpoint, p256dh, auth, profile_id, person_id, user_agent)
  values (v_endpoint, v_p256, v_auth, null, pe.id, left(p->>'user_agent', 300))
  on conflict (endpoint) do update
    set p256dh = excluded.p256dh, auth = excluded.auth, person_id = excluded.person_id, profile_id = null,
        user_agent = excluded.user_agent, last_seen_at = now(), failed_at = null
  returning id into v_id;
  return v_id;
end $$;
grant execute on function public.child_push_subscribe(text, jsonb) to anon, authenticated;

create or replace function public.child_push_unsubscribe(p_national_id text, p_endpoint text)
returns boolean language plpgsql volatile security definer set search_path = public as $$
declare pe public.persons;
begin
  pe := public.child_portal_person(p_national_id);
  delete from public.push_subscriptions where endpoint = p_endpoint and person_id = pe.id;
  return found;
end $$;
grant execute on function public.child_push_unsubscribe(text, text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 14. PUSH QUEUE for the dispatcher (service role ONLY)
-- ---------------------------------------------------------------------
create or replace function public.notif_push_queue(p_limit integer default 200)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare out jsonb;
begin
  -- recipients without any device → no_device (done)
  update public.notification_recipients r set push_status = 'no_device'
   where r.push_status = 'pending'
     and not exists (select 1 from public.push_subscriptions s
                      where s.failed_at is null
                        and ((r.person_id is not null and s.person_id = r.person_id)
                          or (r.profile_id is not null and s.profile_id = r.profile_id)));
  select coalesce(jsonb_agg(jsonb_build_object(
           'recipient_id', r.id, 'subscription_id', s.id,
           'endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth,
           'title', r.title, 'body', r.body, 'image_url', r.image_url, 'link_url', r.link_url,
           'is_child', r.person_id is not null, 'notification_id', r.notification_id
         )), '[]'::jsonb) into out
    from (select * from public.notification_recipients where push_status = 'pending'
           order by created_at limit greatest(1, least(coalesce(p_limit, 200), 1000))) r
    join public.push_subscriptions s
      on s.failed_at is null
     and ((r.person_id is not null and s.person_id = r.person_id) or (r.profile_id is not null and s.profile_id = r.profile_id));
  return out;
end $$;
revoke all on function public.notif_push_queue(integer) from public, anon, authenticated;
grant execute on function public.notif_push_queue(integer) to service_role;

-- p: [{recipient_id, subscription_id, ok: bool, gone: bool, error?}]
create or replace function public.notif_push_mark(p jsonb)
returns integer language plpgsql volatile security definer set search_path = public as $$
declare x jsonb; n integer := 0;
begin
  for x in select * from jsonb_array_elements(coalesce(p, '[]'::jsonb)) loop
    if (x->>'ok')::boolean then
      update public.notification_recipients set push_status = 'sent', pushed_at = now(), push_error = null
       where id = (x->>'recipient_id')::uuid and push_status in ('pending', 'failed');
      update public.push_subscriptions set last_seen_at = now(), failed_at = null where id = (x->>'subscription_id')::uuid;
    else
      if coalesce((x->>'gone')::boolean, false) then
        delete from public.push_subscriptions where id = (x->>'subscription_id')::uuid;
      else
        update public.push_subscriptions set failed_at = now() where id = (x->>'subscription_id')::uuid;
      end if;
      update public.notification_recipients set push_status = 'failed', push_error = left(x->>'error', 300)
       where id = (x->>'recipient_id')::uuid and push_status = 'pending';
    end if;
    n := n + 1;
  end loop;
  -- recipients whose every device is now gone / failed
  update public.notification_recipients r set push_status = 'no_device'
   where r.push_status = 'pending'
     and not exists (select 1 from public.push_subscriptions s
                      where s.failed_at is null
                        and ((r.person_id is not null and s.person_id = r.person_id)
                          or (r.profile_id is not null and s.profile_id = r.profile_id)));
  return n;
end $$;
revoke all on function public.notif_push_mark(jsonb) from public, anon, authenticated;
grant execute on function public.notif_push_mark(jsonb) to service_role;

-- ---------------------------------------------------------------------
-- 15. AUTOMATIONS ENGINE — App event → automatic notification
--     Two entry points, reusable for future triggers:
--       notif_fire_enrollment(trigger, enrollment, vars, default_link, ref)
--         → the event concerns ONE child (attendance, points, achievement)
--       notif_fire_scope(trigger, church, service, class, vars, link, ref, ids)
--         → the event concerns a whole scope (class live, exam published)
--     Every automation whose trigger + scope match creates ONE notification
--     (source = 'automation') with the rendered title / body and the
--     recipient rows (student → the child · class_servants → the servants
--     covering the class). Triggers never break the parent operation.
-- ---------------------------------------------------------------------
create or replace function public.notif_module_covers(p_church uuid, p_service uuid, p_class uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.module_access m
     where m.module_key = 'notifications'
       and (m.church_id is null
            or (m.church_id = p_church
                and (m.service_id is null or p_service is null or m.service_id = p_service)
                and (m.class_id   is null or p_class   is null or m.class_id   = p_class)))
  )
$$;
revoke all on function public.notif_module_covers(uuid, uuid, uuid) from public, anon, authenticated;

-- the standard variables of a child (merged with the trigger's own)
create or replace function public.notif_enrollment_vars(p_enrollment uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
           'الاسم', pe.name,
           'الاسم الأول', split_part(pe.name, ' ', 1),
           'الرصيد', e.points,
           'عدد الحضور', e.attendance_count,
           'الفصل', cl.name, 'الخدمة', sv.name, 'الكنيسة', ch.name,
           'التاريخ', to_char(now() at time zone 'Africa/Cairo', 'YYYY-MM-DD'),
           'الوقت', to_char(now() at time zone 'Africa/Cairo', 'HH24:MI'))
    from public.enrollments e
    join public.persons pe on pe.id = e.person_id
    join public.churches ch on ch.id = e.church_id
    join public.services sv on sv.id = e.service_id
    join public.classes  cl on cl.id = e.class_id
   where e.id = p_enrollment
$$;
revoke all on function public.notif_enrollment_vars(uuid) from public, anon, authenticated;

create or replace function public.notif_fire_enrollment(
  p_trigger text, p_enrollment uuid, p_vars jsonb default '{}'::jsonb,
  p_default_link text default null, p_ref text default null)
returns integer language plpgsql volatile security definer set search_path = public as $$
declare
  e public.enrollments;
  a public.notification_automations;
  vars jsonb;
  n_id uuid;
  fired integer := 0;
  v_title text; v_body text; v_link text;
begin
  select * into e from public.enrollments where id = p_enrollment;
  if not found then return 0; end if;
  if not exists (select 1 from public.notification_automations where trigger_key = p_trigger and is_active) then return 0; end if;
  if not public.notif_module_covers(e.church_id, e.service_id, e.class_id) then return 0; end if;
  vars := coalesce(public.notif_enrollment_vars(e.id), '{}'::jsonb) || coalesce(p_vars, '{}'::jsonb);

  for a in
    select * from public.notification_automations x
     where x.trigger_key = p_trigger and x.is_active
       and (x.church_id  is null or x.church_id  = e.church_id)
       and (x.service_id is null or x.service_id = e.service_id)
       and (x.class_id   is null or x.class_id   = e.class_id)
  loop
    -- per-trigger config filters
    if p_trigger in ('points_added', 'points_deducted')
       and abs(coalesce((p_vars->>'_delta')::int, 0)) < coalesce((a.config->>'min_points')::int, 1) then
      continue;
    end if;
    -- «once per ref» guard (e.g. one attendance notification per day per child)
    if p_ref is not null then
      begin
        insert into public.notification_automation_runs (automation_id, ref_key) values (a.id, p_ref || ':' || e.id);
      exception when unique_violation then continue; end;
    end if;

    v_title := left(public.notif_render(a.title_template, vars), 120);
    v_body  := left(public.notif_render(a.body_template, vars), 1000);
    v_link  := coalesce(public.notif_clean_link(a.link_url), public.notif_clean_link(p_default_link));
    if length(trim(v_title)) = 0 then v_title := a.name; end if;

    insert into public.notifications (church_id, service_id, class_id, title, body, image_url, link_url, target_kind, audience,
                                      enrollment_ids, status, sent_at, source, automation_id, created_by)
    values (e.church_id, e.service_id, e.class_id, v_title, v_body, a.image_url, v_link,
            'person', case when a.recipient = 'class_servants' then 'staff' else 'children' end,
            array[e.id], 'sent', now(), 'automation', a.id, null)
    returning id into n_id;

    if a.recipient = 'class_servants' then
      insert into public.notification_recipients (notification_id, profile_id, title, body, image_url, link_url)
      select n_id, t, v_title, v_body, a.image_url, v_link
        from public.notif_staff_in_scope(e.church_id, e.service_id, e.class_id) t;
    else
      insert into public.notification_recipients (notification_id, enrollment_id, person_id, title, body, image_url, link_url)
      values (n_id, e.id, e.person_id, v_title, v_body, a.image_url, v_link);
    end if;
    update public.notifications set recipients_count = (select count(*) from public.notification_recipients where notification_id = n_id),
           status = case when exists (select 1 from public.notification_recipients where notification_id = n_id) then 'sent' else 'failed' end
     where id = n_id;
    fired := fired + 1;
  end loop;
  return fired;
end $$;
revoke all on function public.notif_fire_enrollment(text, uuid, jsonb, text, text) from public, anon, authenticated;

create or replace function public.notif_fire_scope(
  p_trigger text, p_church uuid, p_service uuid, p_class uuid, p_vars jsonb default '{}'::jsonb,
  p_default_link text default null, p_ref text default null, p_enrollment_ids uuid[] default null)
returns integer language plpgsql volatile security definer set search_path = public as $$
declare
  a public.notification_automations;
  vars jsonb;
  n_id uuid;
  fired integer := 0;
  v_title text; v_body text; v_link text;
  v_church uuid; v_service uuid; v_class uuid;
  cnt integer;
begin
  if p_church is null then return 0; end if;
  if not exists (select 1 from public.notification_automations where trigger_key = p_trigger and is_active) then return 0; end if;
  if not public.notif_module_covers(p_church, p_service, p_class) then return 0; end if;
  vars := jsonb_build_object(
            'الكنيسة', (select name from public.churches where id = p_church),
            'الخدمة',  (select name from public.services where id = p_service),
            'الفصل',   (select name from public.classes  where id = p_class),
            'التاريخ', to_char(now() at time zone 'Africa/Cairo', 'YYYY-MM-DD'),
            'الوقت',   to_char(now() at time zone 'Africa/Cairo', 'HH24:MI'))
          || coalesce(p_vars, '{}'::jsonb);

  for a in
    select * from public.notification_automations x
     where x.trigger_key = p_trigger and x.is_active
       and (x.church_id  is null or x.church_id  = p_church)
       and (x.service_id is null or p_service is null or x.service_id = p_service)
       and (x.class_id   is null or p_class   is null or x.class_id   = p_class)
  loop
    if p_ref is not null then
      begin
        insert into public.notification_automation_runs (automation_id, ref_key) values (a.id, p_ref);
      exception when unique_violation then continue; end;
    end if;
    -- effective scope = the narrower of the event's and the automation's
    v_church  := p_church;
    v_service := coalesce(p_service, a.service_id);
    v_class   := coalesce(p_class, a.class_id);
    if v_class is not null and v_service is null then
      select service_id into v_service from public.classes where id = v_class;
    end if;

    v_title := left(public.notif_render(a.title_template, vars), 120);
    v_body  := left(public.notif_render(a.body_template, vars), 1000);
    v_link  := coalesce(public.notif_clean_link(a.link_url), public.notif_clean_link(p_default_link));
    if length(trim(v_title)) = 0 then v_title := a.name; end if;

    insert into public.notifications (church_id, service_id, class_id, title, body, image_url, link_url, target_kind, audience,
                                      enrollment_ids, status, sent_at, source, automation_id, created_by)
    values (v_church, v_service, v_class, v_title, v_body, a.image_url, v_link,
            case when p_enrollment_ids is not null then 'person' when v_class is not null then 'class' when v_service is not null then 'service' else 'church' end,
            case when a.recipient = 'class_servants' then 'staff' else 'children' end,
            p_enrollment_ids, 'sent', now(), 'automation', a.id, null)
    returning id into n_id;

    if a.recipient = 'class_servants' then
      insert into public.notification_recipients (notification_id, profile_id, title, body, image_url, link_url)
      select n_id, t, v_title, v_body, a.image_url, v_link
        from public.notif_staff_in_scope(v_church, v_service, v_class) t;
    else
      insert into public.notification_recipients (notification_id, enrollment_id, person_id, title, body, image_url, link_url)
      select n_id, e.id, e.person_id, v_title, v_body, a.image_url, v_link
        from public.enrollments e
       where e.church_id = v_church
         and (v_service is null or e.service_id = v_service)
         and (v_class   is null or e.class_id   = v_class)
         and (p_enrollment_ids is null or e.id = any(p_enrollment_ids));
    end if;
    select count(*) into cnt from public.notification_recipients where notification_id = n_id;
    update public.notifications set recipients_count = cnt, status = case when cnt > 0 then 'sent' else 'failed' end,
           error = case when cnt > 0 then null else 'no_recipients' end
     where id = n_id;
    fired := fired + 1;
  end loop;
  return fired;
end $$;
revoke all on function public.notif_fire_scope(text, uuid, uuid, uuid, jsonb, text, text, uuid[]) from public, anon, authenticated;

-- ---- trigger: attendance (attendance_log insert) — once per event per day ----
create or replace function public.notif_on_attendance()
returns trigger language plpgsql security definer set search_path = public as $$
declare ev text;
begin
  begin
    select name into ev from public.events where id = new.event_id;
    perform public.notif_fire_enrollment('attendance', new.enrollment_id,
      jsonb_build_object('المناسبة', coalesce(ev, 'الحضور'), 'النقاط', new.points_delta, '_delta', new.points_delta),
      '/child/attendance', 'att:' || coalesce(new.event_id::text, '-') || ':' || (now() at time zone 'Africa/Cairo')::date);
  exception when others then
    raise notice 'notif_on_attendance skipped: %', sqlerrm;
  end;
  return new;
end $$;
drop trigger if exists zz_notif_on_attendance on public.attendance_log;
create trigger zz_notif_on_attendance after insert on public.attendance_log
for each row execute function public.notif_on_attendance();

-- ---- trigger: points added / deducted (points_log insert) ----
create or replace function public.notif_on_points()
returns trigger language plpgsql security definer set search_path = public as $$
declare cause text; ev text;
begin
  if new.delta = 0 then return new; end if;
  begin
    select name into cause from public.causes where id = new.cause_id;
    select name into ev from public.events where id = new.event_id;
    perform public.notif_fire_enrollment(
      case when new.delta > 0 then 'points_added' else 'points_deducted' end, new.enrollment_id,
      jsonb_build_object('النقاط', abs(new.delta), 'السبب', coalesce(cause, ''), 'المناسبة', coalesce(ev, ''), '_delta', new.delta),
      '/child/points', null);
  exception when others then
    raise notice 'notif_on_points skipped: %', sqlerrm;
  end;
  return new;
end $$;
drop trigger if exists zz_notif_on_points on public.points_log;
create trigger zz_notif_on_points after insert on public.points_log
for each row execute function public.notif_on_points();

-- ---- trigger: achievement earned (user_achievements insert) ----
create or replace function public.notif_on_achievement()
returns trigger language plpgsql security definer set search_path = public as $$
declare a_name text;
begin
  begin
    select name into a_name from public.achievements where id = new.achievement_id;
    perform public.notif_fire_enrollment('achievement_earned', new.enrollment_id,
      jsonb_build_object('الإنجاز', coalesce(a_name, ''), 'النقاط', new.points_awarded, '_delta', new.points_awarded),
      '/child/achievements', null);
  exception when others then
    raise notice 'notif_on_achievement skipped: %', sqlerrm;
  end;
  return new;
end $$;
do $$ begin
  if to_regclass('public.user_achievements') is not null then
    drop trigger if exists zz_notif_on_achievement on public.user_achievements;
    create trigger zz_notif_on_achievement after insert on public.user_achievements
    for each row execute function public.notif_on_achievement();
  end if;
end $$;

-- ---- trigger: online class started (online_classes status → live) ----
create or replace function public.notif_on_online_live()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'live' and (tg_op = 'INSERT' or old.status is distinct from 'live') then
    begin
      perform public.notif_fire_scope('online_class_started', new.church_id, new.service_id, new.class_id,
        jsonb_build_object('العنوان', new.title, 'المنصة', new.platform,
                           'الوقت', to_char(new.starts_at at time zone 'Africa/Cairo', 'HH24:MI')),
        '/child/online/' || new.id, 'online:' || new.id || ':' || coalesce(new.started_at, now())::date);
    exception when others then
      raise notice 'notif_on_online_live skipped: %', sqlerrm;
    end;
  end if;
  return new;
end $$;
do $$ begin
  if to_regclass('public.online_classes') is not null then
    drop trigger if exists zz_notif_on_online_live on public.online_classes;
    create trigger zz_notif_on_online_live after insert or update of status on public.online_classes
    for each row execute function public.notif_on_online_live();
  end if;
end $$;

-- ---- trigger: exam published (exams status → published, already open) ----
create or replace function public.notif_on_exam_published()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'published' and (tg_op = 'INSERT' or old.status is distinct from 'published')
     and (new.opens_at is null or new.opens_at <= now()) then
    begin
      perform public.notif_fire_scope('exam_published', new.church_id, new.service_id, new.class_id,
        jsonb_build_object('العنوان', new.title,
                           'آخر موعد', coalesce(to_char(new.closes_at at time zone 'Africa/Cairo', 'YYYY-MM-DD HH24:MI'), '')),
        '/child/exams/' || new.id, 'exam:' || new.id);
    exception when others then
      raise notice 'notif_on_exam_published skipped: %', sqlerrm;
    end;
  end if;
  return new;
end $$;
do $$ begin
  if to_regclass('public.exams') is not null then
    drop trigger if exists zz_notif_on_exam_published on public.exams;
    create trigger zz_notif_on_exam_published after insert or update of status, opens_at on public.exams
    for each row execute function public.notif_on_exam_published();
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 16. notif_tick() — due scheduled sends + occasion reminders + exams
--     whose opens_at has arrived. Called by pg_cron (every minute, when
--     the extension exists) and by the dispatch API route.
-- ---------------------------------------------------------------------
create or replace function public.notif_tick()
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  r record; au record; released integer := 0; reminders integer := 0; exams_n integer := 0;
  ids uuid[];
begin
  -- 1) scheduled sends whose time has come
  for r in select id from public.notifications where status = 'scheduled' and scheduled_at <= now()
           order by scheduled_at limit 100 loop
    perform public.notif_materialize(r.id);
    released := released + 1;
  end loop;

  -- 2) occasion reminders: every active automation × published occasion that
  --    starts within `hours_before` (default 24) — once per (automation, occasion)
  if to_regclass('public.occasions') is not null then
    for au in select * from public.notification_automations where trigger_key = 'occasion_reminder' and is_active loop
      for r in
        select o.* from public.occasions o
         where o.status = 'published'
           and o.starts_at > now()
           and o.starts_at <= now() + make_interval(hours => coalesce((au.config->>'hours_before')::int, 24))
           and (au.church_id  is null or au.church_id  = o.church_id)
           and (au.service_id is null or o.service_id is null or au.service_id = o.service_id)
           and (au.class_id   is null or o.class_id   is null or au.class_id   = o.class_id)
           and not exists (select 1 from public.notification_automation_runs x where x.automation_id = au.id and x.ref_key = 'occasion:' || o.id)
      loop
        -- registered participants only; when nobody registered → the whole scope
        select array_agg(enrollment_id) into ids
          from public.occasion_registrations g where g.occasion_id = r.id and g.status in ('pending', 'confirmed');
        reminders := reminders + public.notif_fire_scope('occasion_reminder', r.church_id, r.service_id, r.class_id,
          jsonb_build_object('العنوان', r.title, 'المكان', coalesce(r.location, ''),
                             'التاريخ', to_char(r.starts_at at time zone 'Africa/Cairo', 'YYYY-MM-DD'),
                             'الوقت', to_char(r.starts_at at time zone 'Africa/Cairo', 'HH24:MI')),
          '/child/occasions/' || r.id, 'occasion:' || r.id, ids);
      end loop;
    end loop;
  end if;

  -- 3) exams published earlier with a future opens_at that has now arrived
  if to_regclass('public.exams') is not null then
    for r in select x.* from public.exams x
              where x.status = 'published' and x.opens_at is not null and x.opens_at <= now() and x.opens_at > now() - interval '1 day'
                and exists (select 1 from public.notification_automations a where a.trigger_key = 'exam_published' and a.is_active
                            and not exists (select 1 from public.notification_automation_runs z where z.automation_id = a.id and z.ref_key = 'exam:' || x.id))
    loop
      exams_n := exams_n + public.notif_fire_scope('exam_published', r.church_id, r.service_id, r.class_id,
        jsonb_build_object('العنوان', r.title, 'آخر موعد', coalesce(to_char(r.closes_at at time zone 'Africa/Cairo', 'YYYY-MM-DD HH24:MI'), '')),
        '/child/exams/' || r.id, 'exam:' || r.id);
    end loop;
  end if;

  return jsonb_build_object('released', released, 'reminders', reminders, 'exams', exams_n, 'at', now());
end $$;
revoke all on function public.notif_tick() from public, anon, authenticated;
grant execute on function public.notif_tick() to service_role;

-- pg_cron (Supabase: Database → Extensions → pg_cron). Skipped silently elsewhere.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'notif_tick';
    perform cron.schedule('notif_tick', '* * * * *', 'select public.notif_tick()');
  end if;
exception when others then
  raise notice 'pg_cron schedule skipped: %', sqlerrm;
end $$;

-- ---------------------------------------------------------------------
-- 17. PERMISSIONS summary for the UI
-- ---------------------------------------------------------------------
create or replace function public.notif_permissions()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'visible', public.module_visible('notifications'),
    'can_send_all', public.is_owner(),
    'can_manage', public.my_role() in ('owner', 'church_manager', 'service_manager'),
    'role', public.my_role()
  )
$$;
grant execute on function public.notif_permissions() to authenticated;

-- ---------------------------------------------------------------------
-- 18. REALTIME
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['notifications', 'notification_recipients', 'notification_automations'] loop
    if not exists (select 1 from pg_publication_tables
                    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;
alter table public.notifications            replica identity full;
alter table public.notification_recipients  replica identity full;
alter table public.notification_automations replica identity full;

-- storage: notification images go to photos/notifications (authenticated write — policy from 0005)

commit;
