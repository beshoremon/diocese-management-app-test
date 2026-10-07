-- =====================================================================
-- 0029 — وحدة الرسائل (Messages module)
--
-- ONE table of messages, four kinds:
--   child              — conversation of ONE enrollment (the child and every
--                        servant whose scope covers that enrollment)
--   staff              — direct conversation between two servants
--   broadcast_children — a servant's announcement to a scope
--                        (class / service / church / all churches)
--   broadcast_staff    — a servant's announcement to the servants BELOW him
--
-- Permissions (enforced in the RPCs + RLS, all behind module_visible('messages')):
--   • a child writes in his own enrollment conversation(s) — every servant
--     allowed on that tenant (enrollment_visible) reads and replies
--   • a servant sends to a child / selected children (enrollment_visible),
--     to a class / service / church / everyone (scope_contains — «all
--     churches» is the owner only) and to servants below him in the
--     hierarchy (their scope is contained in his). A recipient may always
--     reply to whoever wrote to him.
--
-- Read state: chat_read_state(reader, bucket, last_read_at) where bucket is
--   'e:<enrollment_id>' (child conversation), 's:<other_profile_id>' (staff
--   conversation) or 'b' (the servant's announcements list).
--
-- Idempotent. Run after 0028.
-- =====================================================================
begin;

-- ---------------------------------------------------------------------
-- 1. TABLES
-- ---------------------------------------------------------------------
create table if not exists public.chat_messages (
  id                 uuid primary key default gen_random_uuid(),
  kind               text not null check (kind in ('child', 'staff', 'broadcast_children', 'broadcast_staff')),
  -- kind = child → the conversation (scope denormalized for RLS / indexes)
  enrollment_id      uuid references public.enrollments(id) on delete cascade,
  -- kind = staff → the other party
  to_profile_id      uuid references public.profiles(id) on delete cascade,
  -- scope: child → enrollment scope · broadcast_* → audience (null = all)
  church_id          uuid references public.churches(id) on delete cascade,
  service_id         uuid references public.services(id) on delete cascade,
  class_id           uuid references public.classes(id)  on delete cascade,
  -- exactly one sender
  sender_profile_id  uuid references public.profiles(id) on delete set null,
  sender_person_id   uuid references public.persons(id)  on delete set null,
  body               text not null default '',
  image_url          text,
  created_at         timestamptz not null default clock_timestamp(),
  constraint chat_messages_body_check check (length(body) <= 4000 and (length(trim(body)) > 0 or image_url is not null)),
  constraint chat_messages_shape_check check (
    case kind
      when 'child'              then enrollment_id is not null and to_profile_id is null and church_id is not null
      when 'staff'              then enrollment_id is null and to_profile_id is not null and sender_profile_id is not null
      when 'broadcast_children' then enrollment_id is null and to_profile_id is null and sender_profile_id is not null
      when 'broadcast_staff'    then enrollment_id is null and to_profile_id is null and sender_profile_id is not null
    end
  )
);

-- staff pair key (unordered) so a direct conversation is one group
alter table public.chat_messages
  add column if not exists staff_pair text generated always as (
    case when kind = 'staff'
         then least(sender_profile_id::text, to_profile_id::text) || '|' || greatest(sender_profile_id::text, to_profile_id::text)
    end
  ) stored;

create index if not exists idx_chat_messages_enrollment on public.chat_messages (enrollment_id, created_at desc) where kind = 'child';
create index if not exists idx_chat_messages_staff_pair on public.chat_messages (staff_pair, created_at desc) where kind = 'staff';
create index if not exists idx_chat_messages_to_profile on public.chat_messages (to_profile_id, created_at desc) where kind = 'staff';
create index if not exists idx_chat_messages_sender     on public.chat_messages (sender_profile_id, created_at desc);
create index if not exists idx_chat_messages_person     on public.chat_messages (sender_person_id, created_at desc);
create index if not exists idx_chat_messages_broadcast  on public.chat_messages (kind, church_id, service_id, class_id, created_at desc) where kind like 'broadcast%';
create index if not exists idx_chat_messages_scope      on public.chat_messages (church_id, service_id, class_id, created_at desc);
create index if not exists idx_chat_messages_created    on public.chat_messages (created_at desc);

create table if not exists public.chat_read_state (
  id                uuid primary key default gen_random_uuid(),
  reader_profile_id uuid references public.profiles(id) on delete cascade,
  reader_person_id  uuid references public.persons(id)  on delete cascade,
  bucket            text not null,
  last_read_at      timestamptz not null default clock_timestamp(),
  constraint chat_read_state_reader_check check (
    (reader_profile_id is not null)::int + (reader_person_id is not null)::int = 1
  )
);
create unique index if not exists uq_chat_read_state_profile on public.chat_read_state (reader_profile_id, bucket) where reader_profile_id is not null;
create unique index if not exists uq_chat_read_state_person  on public.chat_read_state (reader_person_id, bucket)  where reader_person_id  is not null;

-- sender: exactly one of profile / person at insert time (a later deletion
-- of the sender sets the column null → keep the row, so no CHECK here)
create or replace function public.check_chat_message_sender()
returns trigger language plpgsql as $$
begin
  if (new.sender_profile_id is not null)::int + (new.sender_person_id is not null)::int <> 1 then
    raise exception 'exactly one sender required' using errcode = '23514';
  end if;
  return new;
end $$;
drop trigger if exists trg_chat_message_sender on public.chat_messages;
create trigger trg_chat_message_sender before insert on public.chat_messages
for each row execute function public.check_chat_message_sender();

-- ---------------------------------------------------------------------
-- 2. HELPERS
-- ---------------------------------------------------------------------
-- Can the caller start a conversation with this servant? He must be
-- BELOW the caller: his scope is contained in the caller's (never the owner).
-- Anyone who already wrote to me may always be answered.
create or replace function public.chat_staff_reachable(p_profile uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select p_profile is not null and p_profile <> auth.uid() and (
    exists (
      select 1 from public.profiles t
       where t.id = p_profile and t.status = 'approved'
         and t.role <> 'owner'
         and public.scope_contains(t.church_id, t.service_id, t.class_id)
    )
    or exists (
      select 1 from public.chat_messages m
       where m.kind = 'staff' and m.sender_profile_id = p_profile and m.to_profile_id = auth.uid()
    )
  )
$$;
grant execute on function public.chat_staff_reachable(uuid) to authenticated;

-- One visibility rule for messages (used by RLS + the reading RPCs)
create or replace function public.chat_message_visible(
  p_kind text, p_enrollment uuid, p_to uuid, p_church uuid, p_service uuid, p_class uuid, p_sender uuid,
  s_role public.app_role, s_church uuid, s_service uuid, s_class uuid, s_uid uuid
) returns boolean language sql immutable as $$
  select case p_kind
    when 'child' then public.enrollment_visible(p_church, p_service, p_class, s_role, s_church, s_service, s_class)
    when 'staff' then p_sender = s_uid or p_to = s_uid
    when 'broadcast_children' then
      p_sender = s_uid or s_role = 'owner' or p_church is null or (
        p_church = s_church
        and (s_role = 'church_manager' or s_service is null or p_service is null or p_service = s_service)
        and (s_role in ('church_manager', 'service_manager') or s_class is null or p_class is null or p_class = s_class)
      )
    when 'broadcast_staff' then
      p_sender = s_uid or s_role = 'owner' or (
        (p_church  is null or s_church  = p_church)
        and (p_service is null or s_service = p_service)
        and (p_class   is null or s_class   = p_class)
      )
    else false
  end
$$;

-- Audience label «فصل أ — مدارس الأحد» for a scope
create or replace function public.chat_scope_label(p_church uuid, p_service uuid, p_class uuid)
returns text language sql stable security definer set search_path = public as $$
  select case
    when p_church is null then 'كل الكنائس'
    when p_service is null then 'كنيسة ' || coalesce((select name from public.churches where id = p_church), '—')
    when p_class is null then 'خدمة ' || coalesce((select name from public.services where id = p_service), '—')
                             || ' — ' || coalesce((select name from public.churches where id = p_church), '—')
    else 'فصل ' || coalesce((select name from public.classes where id = p_class), '—')
         || ' — ' || coalesce((select name from public.services where id = p_service), '—')
  end
$$;
grant execute on function public.chat_scope_label(uuid, uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 3. RLS — read what concerns you; writes only through the RPCs
--    (delete: own messages, or any child/broadcast message in a scope I contain)
-- ---------------------------------------------------------------------
alter table public.chat_messages   enable row level security;
alter table public.chat_read_state enable row level security;

drop policy if exists chat_messages_select on public.chat_messages;
create policy chat_messages_select on public.chat_messages for select to authenticated using (
  (select public.module_visible('messages'))
  and public.chat_message_visible(kind, enrollment_id, to_profile_id, church_id, service_id, class_id, sender_profile_id,
        (select role from public.my_scope()), (select church_id from public.my_scope()),
        (select service_id from public.my_scope()), (select class_id from public.my_scope()), auth.uid())
);
drop policy if exists chat_messages_delete on public.chat_messages;
create policy chat_messages_delete on public.chat_messages for delete to authenticated using (
  (select public.module_visible('messages'))
  and (
    sender_profile_id = auth.uid()
    or (kind <> 'staff' and (select public.is_owner()))
    or (kind <> 'staff' and church_id is not null and (select public.scope_contains(church_id, service_id, class_id))
        and (select role from public.my_scope()) in ('church_manager', 'service_manager'))
  )
);

drop policy if exists chat_read_state_select on public.chat_read_state;
create policy chat_read_state_select on public.chat_read_state for select to authenticated using (reader_profile_id = auth.uid());
-- inserts / updates through chat_mark_read (security definer)

-- realtime
do $$
begin
  if not exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'chat_messages') then
    alter publication supabase_realtime add table public.chat_messages;
  end if;
  if not exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'chat_read_state') then
    alter publication supabase_realtime add table public.chat_read_state;
  end if;
end $$;
alter table public.chat_messages   replica identity full;
alter table public.chat_read_state replica identity full;

-- ---------------------------------------------------------------------
-- 4. SERVANT RPCs
-- ---------------------------------------------------------------------
-- Internal: insert one message row (no permission checks — callers check)
create or replace function public.chat_insert(
  p_kind text, p_enrollment uuid, p_to uuid, p_church uuid, p_service uuid, p_class uuid,
  p_sender_profile uuid, p_sender_person uuid, p_body text, p_image text
) returns uuid language plpgsql volatile security definer set search_path = public as $$
declare v_id uuid;
begin
  insert into public.chat_messages (kind, enrollment_id, to_profile_id, church_id, service_id, class_id,
                                    sender_profile_id, sender_person_id, body, image_url)
  values (p_kind, p_enrollment, p_to, p_church, p_service, p_class, p_sender_profile, p_sender_person,
          coalesce(trim(p_body), ''), nullif(trim(coalesce(p_image, '')), ''))
  returning id into v_id;
  return v_id;
end $$;
revoke all on function public.chat_insert(text, uuid, uuid, uuid, uuid, uuid, uuid, uuid, text, text) from public, anon, authenticated;

-- mark a bucket read up to now
create or replace function public.chat_mark_read(p_bucket text)
returns void language plpgsql volatile security definer set search_path = public as $$
begin
  if auth.uid() is null then return; end if;
  insert into public.chat_read_state (reader_profile_id, bucket, last_read_at)
  values (auth.uid(), p_bucket, clock_timestamp())
  on conflict (reader_profile_id, bucket) where reader_profile_id is not null
  do update set last_read_at = excluded.last_read_at;
end $$;
grant execute on function public.chat_mark_read(text) to authenticated;

-- chat_send — the ONE write entry for servants.
--   p: { target: 'children' | 'staff',
--        enrollment_ids?: uuid[], profile_ids?: uuid[],          -- selected recipients
--        church_id?, service_id?, class_id?,                     -- OR an audience scope (null = all)
--        body, image_url? }
-- Returns { sent: n, message_ids: [...] }.
create or replace function public.chat_send(p jsonb)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_uid      uuid := auth.uid();
  v_target   text := coalesce(p->>'target', 'children');
  v_body     text := coalesce(p->>'body', '');
  v_image    text := nullif(trim(coalesce(p->>'image_url', '')), '');
  v_church   uuid := nullif(p->>'church_id', '')::uuid;
  v_service  uuid := nullif(p->>'service_id', '')::uuid;
  v_class    uuid := nullif(p->>'class_id', '')::uuid;
  v_ids      uuid[];
  v_id       uuid;
  v_out      uuid[] := '{}';
  e          public.enrollments;
  s          record;
  n          int := 0;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if not public.module_visible('messages') then raise exception 'module_not_visible' using errcode = '42501'; end if;
  if length(trim(v_body)) = 0 and v_image is null then raise exception 'empty_message' using errcode = '22023'; end if;
  if length(v_body) > 4000 then raise exception 'message_too_long' using errcode = '22023'; end if;
  select * into s from public.my_scope();
  if not found then raise exception 'not_approved' using errcode = '42501'; end if;

  if v_target = 'children' then
    if p ? 'enrollment_ids' and jsonb_typeof(p->'enrollment_ids') = 'array' and jsonb_array_length(p->'enrollment_ids') > 0 then
      select array_agg(distinct x::uuid) into v_ids from jsonb_array_elements_text(p->'enrollment_ids') x;
      if array_length(v_ids, 1) > 500 then raise exception 'too_many_recipients' using errcode = '22023'; end if;
      foreach v_id in array v_ids loop
        select * into e from public.enrollments where id = v_id;
        if not found then raise exception 'enrollment_not_found' using errcode = 'P0002'; end if;
        if not public.enrollment_visible(e.church_id, e.service_id, e.class_id, s.role, s.church_id, s.service_id, s.class_id) then
          raise exception 'enrollment_not_visible' using errcode = '42501';
        end if;
        v_out := v_out || public.chat_insert('child', e.id, null, e.church_id, e.service_id, e.class_id, v_uid, null, v_body, v_image);
        n := n + 1;
      end loop;
    else
      -- audience scope → one broadcast row. «all churches» = owner only.
      if not public.scope_contains(v_church, v_service, v_class) then raise exception 'scope_not_allowed' using errcode = '42501'; end if;
      if v_service is not null and not exists (select 1 from public.services where id = v_service and church_id = v_church) then
        raise exception 'scope_chain' using errcode = '22023';
      end if;
      if v_class is not null and not exists (select 1 from public.classes where id = v_class and service_id = v_service) then
        raise exception 'scope_chain' using errcode = '22023';
      end if;
      v_out := v_out || public.chat_insert('broadcast_children', null, null, v_church, v_service, v_class, v_uid, null, v_body, v_image);
      n := 1;
    end if;

  elsif v_target = 'staff' then
    if p ? 'profile_ids' and jsonb_typeof(p->'profile_ids') = 'array' and jsonb_array_length(p->'profile_ids') > 0 then
      select array_agg(distinct x::uuid) into v_ids from jsonb_array_elements_text(p->'profile_ids') x;
      if array_length(v_ids, 1) > 200 then raise exception 'too_many_recipients' using errcode = '22023'; end if;
      foreach v_id in array v_ids loop
        if not public.chat_staff_reachable(v_id) then raise exception 'staff_not_reachable' using errcode = '42501'; end if;
        v_out := v_out || public.chat_insert('staff', null, v_id, null, null, null, v_uid, null, v_body, v_image);
        n := n + 1;
      end loop;
    else
      if not public.scope_contains(v_church, v_service, v_class) then raise exception 'scope_not_allowed' using errcode = '42501'; end if;
      if v_service is not null and not exists (select 1 from public.services where id = v_service and church_id = v_church) then
        raise exception 'scope_chain' using errcode = '22023';
      end if;
      if v_class is not null and not exists (select 1 from public.classes where id = v_class and service_id = v_service) then
        raise exception 'scope_chain' using errcode = '22023';
      end if;
      v_out := v_out || public.chat_insert('broadcast_staff', null, null, v_church, v_service, v_class, v_uid, null, v_body, v_image);
      n := 1;
    end if;
  else
    raise exception 'bad_target' using errcode = '22023';
  end if;

  -- my own sends are read by me
  perform public.chat_mark_read(case
    when v_target = 'children' and v_ids is not null and array_length(v_ids, 1) = 1 then 'e:' || v_ids[1]
    when v_target = 'staff' and v_ids is not null and array_length(v_ids, 1) = 1 then 's:' || v_ids[1]
    else 'b' end);

  return jsonb_build_object('sent', n, 'message_ids', to_jsonb(v_out));
end $$;
grant execute on function public.chat_send(jsonb) to authenticated;

-- how many recipients an audience scope has (preview before sending)
create or replace function public.chat_audience_count(p_target text, p_church uuid, p_service uuid, p_class uuid)
returns integer language sql stable security definer set search_path = public as $$
  select case
    when not public.module_visible('messages') or not public.scope_contains(p_church, p_service, p_class) then 0
    when p_target = 'staff' then (
      select count(*)::int from public.profiles t
       where t.status = 'approved' and t.id <> auth.uid() and t.role <> 'owner'
         and (p_church  is null or t.church_id  = p_church)
         and (p_service is null or t.service_id = p_service)
         and (p_class   is null or t.class_id   = p_class))
    else (
      select count(*)::int from public.enrollments e
       where (p_church  is null or e.church_id  = p_church)
         and (p_service is null or e.service_id = p_service)
         and (p_class   is null or e.class_id   = p_class))
  end
$$;
grant execute on function public.chat_audience_count(text, uuid, uuid, uuid) to authenticated;

-- servants I may write to (below me in the hierarchy) + anyone who wrote to me
create or replace function public.chat_staff_recipients()
returns jsonb language sql stable security definer set search_path = public as $$
  select case when not public.module_visible('messages') then '[]'::jsonb else coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', t.id, 'full_name', t.full_name, 'role', t.role, 'photo_url', t.photo_url,
             'church_id', t.church_id, 'service_id', t.service_id, 'class_id', t.class_id,
             'church_name', ch.name, 'service_name', sv.name, 'class_name', cl.name)
           order by case t.role when 'church_manager' then 1 when 'service_manager' then 2 else 3 end, t.full_name)
      from public.profiles t
      left join public.churches ch on ch.id = t.church_id
      left join public.services sv on sv.id = t.service_id
      left join public.classes  cl on cl.id = t.class_id
     where t.status = 'approved' and t.id <> auth.uid()
       and public.chat_staff_reachable(t.id)
  ), '[]'::jsonb) end
$$;
grant execute on function public.chat_staff_recipients() to authenticated;


-- the inbox: every conversation I can see (child + staff) with last message
-- and unread count, plus the announcements bucket
create or replace function public.chat_inbox()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  s record;
  v_uid uuid := auth.uid();
  convs jsonb; b_unread int; b_last jsonb;
begin
  if not public.module_visible('messages') then return jsonb_build_object('conversations', '[]'::jsonb, 'broadcasts_unread', 0, 'total_unread', 0); end if;
  select * into s from public.my_scope();
  if not found then return jsonb_build_object('conversations', '[]'::jsonb, 'broadcasts_unread', 0, 'total_unread', 0); end if;

  with vis as (
    select m.* from public.chat_messages m
     where m.kind in ('child', 'staff')
       and public.chat_message_visible(m.kind, m.enrollment_id, m.to_profile_id, m.church_id, m.service_id, m.class_id,
             m.sender_profile_id, s.role, s.church_id, s.service_id, s.class_id, v_uid)
  ),
  keyed as (
    select v.*,
           case when v.kind = 'child' then 'e:' || v.enrollment_id
                else 's:' || case when v.sender_profile_id = v_uid then v.to_profile_id else v.sender_profile_id end end as bucket
      from vis v
  ),
  last as (
    select distinct on (bucket) * from keyed order by bucket, created_at desc
  ),
  unread as (
    select k.bucket, count(*)::int as n
      from keyed k
      left join public.chat_read_state r on r.reader_profile_id = v_uid and r.bucket = k.bucket
     where k.sender_profile_id is distinct from v_uid
       and (r.last_read_at is null or k.created_at > r.last_read_at)
     group by k.bucket
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'bucket', l.bucket,
           'kind', l.kind,
           'enrollment_id', l.enrollment_id,
           'person_id', e.person_id,
           'person_name', pe.name,
           'person_image', pe.image_url,
           'church_id', l.church_id, 'service_id', l.service_id, 'class_id', l.class_id,
           'church_name', ch.name, 'service_name', sv.name, 'class_name', cl.name,
           'other_profile_id', case when l.kind = 'staff' then substr(l.bucket, 3)::uuid end,
           'other_name', op.full_name, 'other_photo', op.photo_url, 'other_role', op.role,
           'last_body', l.body, 'last_image', l.image_url, 'last_at', l.created_at,
           'last_is_me', l.sender_profile_id = v_uid,
           'last_sender_name', coalesce(sp.full_name, spn.name),
           'unread', coalesce(u.n, 0)
         ) order by l.created_at desc), '[]'::jsonb)
    into convs
    from last l
    left join public.enrollments e  on e.id = l.enrollment_id
    left join public.persons pe     on pe.id = e.person_id
    left join public.churches ch    on ch.id = l.church_id
    left join public.services sv    on sv.id = l.service_id
    left join public.classes  cl    on cl.id = l.class_id
    left join public.profiles op    on l.kind = 'staff' and op.id = substr(l.bucket, 3)::uuid
    left join public.profiles sp    on sp.id = l.sender_profile_id
    left join public.persons  spn   on spn.id = l.sender_person_id
    left join unread u              on u.bucket = l.bucket;

  select count(*)::int into b_unread
    from public.chat_messages m
    left join public.chat_read_state r on r.reader_profile_id = v_uid and r.bucket = 'b'
   where m.kind like 'broadcast%'
     and m.sender_profile_id is distinct from v_uid
     and (r.last_read_at is null or m.created_at > r.last_read_at)
     and public.chat_message_visible(m.kind, m.enrollment_id, m.to_profile_id, m.church_id, m.service_id, m.class_id,
           m.sender_profile_id, s.role, s.church_id, s.service_id, s.class_id, v_uid);

  select to_jsonb(t) into b_last from (
    select m.body, m.image_url, m.created_at, m.kind, sp.full_name as sender_name,
           public.chat_scope_label(m.church_id, m.service_id, m.class_id) as audience_label
      from public.chat_messages m
      left join public.profiles sp on sp.id = m.sender_profile_id
     where m.kind like 'broadcast%'
       and public.chat_message_visible(m.kind, m.enrollment_id, m.to_profile_id, m.church_id, m.service_id, m.class_id,
             m.sender_profile_id, s.role, s.church_id, s.service_id, s.class_id, v_uid)
     order by m.created_at desc limit 1) t;

  return jsonb_build_object(
    'conversations', convs,
    'broadcasts_unread', b_unread,
    'broadcasts_last', b_last,
    'total_unread', b_unread + coalesce((select sum((c->>'unread')::int) from jsonb_array_elements(convs) c), 0)
  );
end $$;
grant execute on function public.chat_inbox() to authenticated;

-- total unread (header badge)
create or replace function public.chat_unread_total()
returns integer language sql stable security definer set search_path = public as $$
  select coalesce((public.chat_inbox()->>'total_unread')::int, 0)
$$;
grant execute on function public.chat_unread_total() to authenticated;

-- one conversation. bucket 'e:<enrollment>' merges the child's direct
-- conversation with the announcements that reached him (what the child sees);
-- 's:<profile>' = my direct conversation with that servant; 'b' = announcements.
create or replace function public.chat_thread(p_bucket text, p_before timestamptz default null, p_limit integer default 50)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  s record; v_uid uuid := auth.uid();
  v_kind text := left(p_bucket, 1); v_id uuid; e public.enrollments; res jsonb; header jsonb;
  lim int := greatest(1, least(coalesce(p_limit, 50), 200));
begin
  if not public.module_visible('messages') then raise exception 'module_not_visible' using errcode = '42501'; end if;
  select * into s from public.my_scope();
  if not found then raise exception 'not_approved' using errcode = '42501'; end if;

  if v_kind = 'e' then
    v_id := substr(p_bucket, 3)::uuid;
    select * into e from public.enrollments where id = v_id;
    if not found or not public.enrollment_visible(e.church_id, e.service_id, e.class_id, s.role, s.church_id, s.service_id, s.class_id) then
      raise exception 'enrollment_not_visible' using errcode = '42501';
    end if;
    select jsonb_build_object('kind', 'child', 'enrollment_id', e.id, 'person_id', pe.id, 'person_name', pe.name,
             'person_image', pe.image_url, 'person_phone', pe.phone, 'church_name', ch.name, 'service_name', sv.name, 'class_name', cl.name)
      into header
      from public.persons pe, public.churches ch, public.services sv, public.classes cl
     where pe.id = e.person_id and ch.id = e.church_id and sv.id = e.service_id and cl.id = e.class_id;
    select coalesce(jsonb_agg(x order by (x->>'created_at')::timestamptz), '[]'::jsonb) into res from (
      select jsonb_build_object(
               'id', m.id, 'kind', m.kind, 'body', m.body, 'image_url', m.image_url, 'created_at', m.created_at,
               'is_me', m.sender_profile_id = v_uid,
               'sender_kind', case when m.sender_person_id is not null then 'child' else 'servant' end,
               'sender_id', coalesce(m.sender_profile_id, m.sender_person_id),
               'sender_name', coalesce(sp.full_name, spn.name), 'sender_photo', coalesce(sp.photo_url, spn.image_url), 'sender_role', sp.role,
               'is_broadcast', m.kind <> 'child',
               'audience_label', case when m.kind <> 'child' then public.chat_scope_label(m.church_id, m.service_id, m.class_id) end,
               'can_delete', m.sender_profile_id = v_uid or s.role in ('owner', 'church_manager', 'service_manager')
             ) as x
        from public.chat_messages m
        left join public.profiles sp on sp.id = m.sender_profile_id
        left join public.persons spn on spn.id = m.sender_person_id
       where ((m.kind = 'child' and m.enrollment_id = e.id)
              or (m.kind = 'broadcast_children'
                  and (m.church_id is null or m.church_id = e.church_id)
                  and (m.service_id is null or m.service_id = e.service_id)
                  and (m.class_id is null or m.class_id = e.class_id)))
         and (p_before is null or m.created_at < p_before)
       order by m.created_at desc limit lim) q;

  elsif v_kind = 's' then
    v_id := substr(p_bucket, 3)::uuid;
    select jsonb_build_object('kind', 'staff', 'other_profile_id', t.id, 'other_name', t.full_name, 'other_photo', t.photo_url,
             'other_role', t.role, 'other_phone', t.phone, 'church_name', ch.name, 'service_name', sv.name, 'class_name', cl.name,
             'can_write', public.chat_staff_reachable(t.id))
      into header
      from public.profiles t
      left join public.churches ch on ch.id = t.church_id
      left join public.services sv on sv.id = t.service_id
      left join public.classes  cl on cl.id = t.class_id
     where t.id = v_id;
    if header is null then raise exception 'profile_not_found' using errcode = 'P0002'; end if;
    select coalesce(jsonb_agg(x order by (x->>'created_at')::timestamptz), '[]'::jsonb) into res from (
      select jsonb_build_object(
               'id', m.id, 'kind', m.kind, 'body', m.body, 'image_url', m.image_url, 'created_at', m.created_at,
               'is_me', m.sender_profile_id = v_uid, 'sender_kind', 'servant', 'sender_id', m.sender_profile_id,
               'sender_name', sp.full_name, 'sender_photo', sp.photo_url, 'sender_role', sp.role,
               'is_broadcast', false, 'audience_label', null, 'can_delete', m.sender_profile_id = v_uid
             ) as x
        from public.chat_messages m
        left join public.profiles sp on sp.id = m.sender_profile_id
       where m.kind = 'staff'
         and ((m.sender_profile_id = v_uid and m.to_profile_id = v_id) or (m.sender_profile_id = v_id and m.to_profile_id = v_uid))
         and (p_before is null or m.created_at < p_before)
       order by m.created_at desc limit lim) q;

  elsif p_bucket = 'b' then
    header := jsonb_build_object('kind', 'broadcast');
    select coalesce(jsonb_agg(x order by (x->>'created_at')::timestamptz), '[]'::jsonb) into res from (
      select jsonb_build_object(
               'id', m.id, 'kind', m.kind, 'body', m.body, 'image_url', m.image_url, 'created_at', m.created_at,
               'is_me', m.sender_profile_id = v_uid, 'sender_kind', 'servant', 'sender_id', m.sender_profile_id,
               'sender_name', sp.full_name, 'sender_photo', sp.photo_url, 'sender_role', sp.role,
               'is_broadcast', true,
               'audience_label', public.chat_scope_label(m.church_id, m.service_id, m.class_id),
               'can_delete', m.sender_profile_id = v_uid or s.role = 'owner'
                             or (s.role in ('church_manager', 'service_manager') and m.church_id is not null
                                 and public.scope_contains(m.church_id, m.service_id, m.class_id))
             ) as x
        from public.chat_messages m
        left join public.profiles sp on sp.id = m.sender_profile_id
       where m.kind like 'broadcast%'
         and public.chat_message_visible(m.kind, m.enrollment_id, m.to_profile_id, m.church_id, m.service_id, m.class_id,
               m.sender_profile_id, s.role, s.church_id, s.service_id, s.class_id, v_uid)
         and (p_before is null or m.created_at < p_before)
       order by m.created_at desc limit lim) q;
  else
    raise exception 'bad_bucket' using errcode = '22023';
  end if;

  return jsonb_build_object('header', header, 'messages', res, 'has_more', jsonb_array_length(res) >= lim);
end $$;
grant execute on function public.chat_thread(text, timestamptz, integer) to authenticated;

-- ---------------------------------------------------------------------
-- 5. CHILD PORTAL RPCs (anon, token = national id — pattern of 0021)
-- ---------------------------------------------------------------------
create or replace function public.child_chat_mark_read(p_national_id text, p_enrollment uuid)
returns void language plpgsql volatile security definer set search_path = public as $$
declare p public.persons;
begin
  p := public.child_portal_person(p_national_id);
  if not exists (select 1 from public.enrollments where id = p_enrollment and person_id = p.id) then
    raise exception 'enrollment_not_found' using errcode = 'P0002';
  end if;
  insert into public.chat_read_state (reader_person_id, bucket, last_read_at)
  values (p.id, 'e:' || p_enrollment, clock_timestamp())
  on conflict (reader_person_id, bucket) where reader_person_id is not null
  do update set last_read_at = excluded.last_read_at;
end $$;
grant execute on function public.child_chat_mark_read(text, uuid) to anon, authenticated;

-- per enrollment: does the module reach him, last message, unread
create or replace function public.child_chat_overview(p_national_id text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare p public.persons; res jsonb;
begin
  p := public.child_portal_person(p_national_id);
  select coalesce(jsonb_agg(to_jsonb(t) order by t.last_at desc nulls last, t.created_at), '[]'::jsonb) into res from (
    select e.id as enrollment_id, e.created_at, ch.name as church_name, ch.logo_url as church_logo,
           sv.name as service_name, cl.name as class_name,
           l.body as last_body, l.image_url as last_image, l.created_at as last_at,
           (l.sender_person_id is not null) as last_is_me, l.sender_name as last_sender_name,
           (select count(*)::int from public.chat_messages m
             where m.sender_person_id is distinct from p.id
               and ((m.kind = 'child' and m.enrollment_id = e.id)
                    or (m.kind = 'broadcast_children'
                        and (m.church_id is null or m.church_id = e.church_id)
                        and (m.service_id is null or m.service_id = e.service_id)
                        and (m.class_id is null or m.class_id = e.class_id)))
               and m.created_at > coalesce((select r.last_read_at from public.chat_read_state r
                                             where r.reader_person_id = p.id and r.bucket = 'e:' || e.id), '-infinity'::timestamptz)
           ) as unread
      from public.enrollments e
      join public.churches ch on ch.id = e.church_id
      join public.services sv on sv.id = e.service_id
      join public.classes  cl on cl.id = e.class_id
      left join lateral (
        select m.body, m.image_url, m.created_at, m.sender_person_id, coalesce(sp.full_name, 'أنا') as sender_name
          from public.chat_messages m
          left join public.profiles sp on sp.id = m.sender_profile_id
         where (m.kind = 'child' and m.enrollment_id = e.id)
            or (m.kind = 'broadcast_children'
                and (m.church_id is null or m.church_id = e.church_id)
                and (m.service_id is null or m.service_id = e.service_id)
                and (m.class_id is null or m.class_id = e.class_id))
         order by m.created_at desc limit 1) l on true
     where e.person_id = p.id
       and public.module_granted_for('messages', e.church_id, e.service_id, e.class_id)
  ) t;
  return res;
end $$;
grant execute on function public.child_chat_overview(text) to anon, authenticated;

create or replace function public.child_chat_unread(p_national_id text)
returns integer language sql stable security definer set search_path = public as $$
  select coalesce((select sum((c->>'unread')::int) from jsonb_array_elements(public.child_chat_overview(p_national_id)) c), 0)::int
$$;
grant execute on function public.child_chat_unread(text) to anon, authenticated;

create or replace function public.child_chat_messages(p_national_id text, p_enrollment uuid, p_before timestamptz default null, p_limit integer default 50)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare p public.persons; e public.enrollments; res jsonb; lim int := greatest(1, least(coalesce(p_limit, 50), 200));
begin
  p := public.child_portal_person(p_national_id);
  select * into e from public.enrollments where id = p_enrollment and person_id = p.id;
  if not found then raise exception 'enrollment_not_found' using errcode = 'P0002'; end if;
  if not public.module_granted_for('messages', e.church_id, e.service_id, e.class_id) then
    raise exception 'module_not_visible' using errcode = '42501';
  end if;
  select coalesce(jsonb_agg(x order by (x->>'created_at')::timestamptz), '[]'::jsonb) into res from (
    select jsonb_build_object(
             'id', m.id, 'kind', m.kind, 'body', m.body, 'image_url', m.image_url, 'created_at', m.created_at,
             'is_me', m.sender_person_id = p.id,
             'sender_kind', case when m.sender_person_id is not null then 'child' else 'servant' end,
             'sender_name', coalesce(sp.full_name, p.name), 'sender_photo', coalesce(sp.photo_url, p.image_url), 'sender_role', sp.role,
             'is_broadcast', m.kind <> 'child',
             'audience_label', case when m.kind <> 'child' then public.chat_scope_label(m.church_id, m.service_id, m.class_id) end
           ) as x
      from public.chat_messages m
      left join public.profiles sp on sp.id = m.sender_profile_id
     where ((m.kind = 'child' and m.enrollment_id = e.id)
            or (m.kind = 'broadcast_children'
                and (m.church_id is null or m.church_id = e.church_id)
                and (m.service_id is null or m.service_id = e.service_id)
                and (m.class_id is null or m.class_id = e.class_id)))
       and (p_before is null or m.created_at < p_before)
     order by m.created_at desc limit lim) q;
  return jsonb_build_object('messages', res, 'has_more', jsonb_array_length(res) >= lim);
end $$;
grant execute on function public.child_chat_messages(text, uuid, timestamptz, integer) to anon, authenticated;

create or replace function public.child_chat_send(p_national_id text, p_enrollment uuid, p_body text, p_image_url text default null)
returns uuid language plpgsql volatile security definer set search_path = public as $$
declare p public.persons; e public.enrollments; v_id uuid;
begin
  p := public.child_portal_person(p_national_id);
  select * into e from public.enrollments where id = p_enrollment and person_id = p.id;
  if not found then raise exception 'enrollment_not_found' using errcode = 'P0002'; end if;
  if not public.module_granted_for('messages', e.church_id, e.service_id, e.class_id) then
    raise exception 'module_not_visible' using errcode = '42501';
  end if;
  if length(trim(coalesce(p_body, ''))) = 0 and nullif(trim(coalesce(p_image_url, '')), '') is null then
    raise exception 'empty_message' using errcode = '22023';
  end if;
  if length(p_body) > 4000 then raise exception 'message_too_long' using errcode = '22023'; end if;
  -- gentle rate limit: 30 messages per 10 minutes per child
  if (select count(*) from public.chat_messages m where m.sender_person_id = p.id and m.created_at > now() - interval '10 minutes') >= 30 then
    raise exception 'rate_limited' using errcode = '54000';
  end if;
  v_id := public.chat_insert('child', e.id, null, e.church_id, e.service_id, e.class_id, null, p.id, p_body, p_image_url);
  perform public.child_chat_mark_read(p_national_id, p_enrollment);
  return v_id;
end $$;
grant execute on function public.child_chat_send(text, uuid, text, text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 6. STORAGE — the child portal may attach pictures under photos/child-messages/
-- ---------------------------------------------------------------------
do $$
begin
  if to_regclass('storage.objects') is not null then
    execute 'drop policy if exists "photos_child_messages_upload" on storage.objects';
    execute $p$create policy "photos_child_messages_upload" on storage.objects for insert to anon
      with check (bucket_id = 'photos' and (storage.foldername(name))[1] = 'child-messages')$p$;
  end if;
exception when others then
  raise notice 'storage policy skipped: %', sqlerrm;
end $$;

commit;

-- re-runs on an existing install: make sure the defaults are clock_timestamp()
alter table public.chat_messages   alter column created_at   set default clock_timestamp();
alter table public.chat_read_state alter column last_read_at set default clock_timestamp();
