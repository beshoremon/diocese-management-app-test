-- =====================================================================
-- 0021: CHILD PORTAL (بوابة المخدوم)
--
-- A child opens the app, taps "دخول المخدوم" and scans his card QR
-- (= persons.national_id). He has NO Supabase auth account; the scanned
-- code is his bearer token. Every read/write of the portal goes through a
-- SECURITY DEFINER RPC that takes `p_national_id` and returns / touches
-- ONLY that person's rows. The RPCs are granted to `anon`, so the portal
-- works with the public anon key and RLS on the base tables stays intact
-- (anon still has no direct table access).
--
--   child_portal_profile(nid)           person + enrollments (+ scope names / logo)
--   child_portal_attendance(nid)        every attendance_log row of the person
--   child_portal_points(nid)            points_log + attendance points, merged
--   child_portal_requests(nid)          his data change requests
--   child_portal_submit_request(...)    ask to change data / photo  -> pending
--   child_portal_cancel_request(...)    withdraw a pending request
--
-- Servants side:
--   data_change_requests                table (RLS: managers of ANY of the
--                                       person's enrollments — class servant,
--                                       service manager, church manager, owner)
--   review_data_change_request(...)     approve (applies to persons) / reject
--
-- Storage: anon may upload ONLY under photos/child-requests/ so a child can
-- propose a new photo; it is copied to persons.image_url on approval.
-- Idempotent.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. DATA CHANGE REQUESTS
-- ---------------------------------------------------------------------
create table if not exists public.data_change_requests (
  id             uuid primary key default gen_random_uuid(),
  person_id      uuid not null references public.persons(id) on delete cascade,
  kind           text not null check (kind in ('data', 'photo')),
  -- proposed values. data  -> {name?, birthdate?, gender?, phone?, address?}
  --                  photo -> {image_url}
  changes        jsonb not null default '{}'::jsonb,
  -- snapshot of the current values at request time (for the diff view)
  previous       jsonb not null default '{}'::jsonb,
  note           text,
  status         text not null default 'pending'
                 check (status in ('pending', 'approved', 'rejected', 'cancelled')),
  decision_note  text,
  decided_by     uuid references public.profiles(id),
  decided_at     timestamptz,
  created_at     timestamptz not null default now()
);
create index if not exists idx_dcr_person_created on public.data_change_requests(person_id, created_at desc);
create index if not exists idx_dcr_status_created on public.data_change_requests(status, created_at desc);

comment on table public.data_change_requests is
  'طلبات تعديل البيانات من بوابة المخدوم — يوافق عليها أو يرفضها خادم الفصل / مسؤول الخدمة / مدير الكنيسة';

alter table public.data_change_requests enable row level security;
alter table public.data_change_requests replica identity full;

-- a manager may see / decide a request if he can access ANY enrollment of the person
create or replace function public.can_access_person(p_person uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.enrollments e
     where e.person_id = p_person
       and public.can_access(e.church_id, e.service_id, e.class_id)
  )
$$;
grant execute on function public.can_access_person(uuid) to authenticated;

drop policy if exists dcr_select on public.data_change_requests;
create policy dcr_select on public.data_change_requests for select to authenticated
  using (public.can_access_person(person_id));

drop policy if exists dcr_delete on public.data_change_requests;
create policy dcr_delete on public.data_change_requests for delete to authenticated
  using (public.can_access_person(person_id));

-- inserts / updates happen only through the RPCs below (security definer)

do $$
begin
  alter publication supabase_realtime add table public.data_change_requests;
exception when duplicate_object then null;
end $$;

-- ---------------------------------------------------------------------
-- 2. Helper — resolve the token (national id) to a person, or raise
-- ---------------------------------------------------------------------
create or replace function public.child_portal_person(p_national_id text)
returns public.persons language plpgsql stable security definer set search_path = public as $$
declare
  v public.persons;
begin
  if p_national_id is null or length(trim(p_national_id)) = 0 then
    raise exception 'invalid_code' using errcode = 'P0001';
  end if;
  select * into v from public.persons where national_id = trim(p_national_id);
  if not found then
    raise exception 'unknown_code' using errcode = 'P0002';
  end if;
  return v;
end $$;
revoke all on function public.child_portal_person(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 3. PROFILE — person + enrollments with names, logo, counters
-- ---------------------------------------------------------------------
create or replace function public.child_portal_profile(p_national_id text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  p public.persons;
  enr jsonb;
begin
  p := public.child_portal_person(p_national_id);

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', e.id,
           'church_id', e.church_id,
           'service_id', e.service_id,
           'class_id', e.class_id,
           'attendance_count', e.attendance_count,
           'points', e.points,
           'created_at', e.created_at,
           'church_name', ch.name,
           'church_logo', ch.logo_url,
           'service_name', sv.name,
           'service_photo', sv.photo_url,
           'class_name', cl.name,
           'class_photo', cl.photo_url
         ) order by e.created_at), '[]'::jsonb)
    into enr
    from public.enrollments e
    join public.churches ch on ch.id = e.church_id
    join public.services sv on sv.id = e.service_id
    join public.classes  cl on cl.id = e.class_id
   where e.person_id = p.id;

  return jsonb_build_object(
    'person', jsonb_build_object(
      'id', p.id,
      'national_id', p.national_id,
      'name', p.name,
      'birthdate', p.birthdate,
      'gender', p.gender,
      'phone', p.phone,
      'address', p.address,
      'image_url', p.image_url,
      'created_at', p.created_at
    ),
    'enrollments', enr
  );
end $$;
grant execute on function public.child_portal_profile(text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 4. ATTENDANCE — every attendance row of the person (all enrollments)
-- ---------------------------------------------------------------------
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
    select a.id, a.enrollment_id, a.event_id, ev.name,
           a.points_delta, a.attended_on, a.created_at,
           pr.full_name, cl.name, sv.name, ch.name
      from public.attendance_log a
      join public.enrollments e on e.id = a.enrollment_id
      left join public.events   ev on ev.id = a.event_id
      left join public.profiles pr on pr.id = a.recorded_by
      join public.classes  cl on cl.id = e.class_id
      join public.services sv on sv.id = e.service_id
      join public.churches ch on ch.id = e.church_id
     where e.person_id = p.id
     order by a.attended_on desc, a.created_at desc;
end $$;
grant execute on function public.child_portal_attendance(text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 5. POINTS — cause points + attendance points, merged, newest first
-- ---------------------------------------------------------------------
create or replace function public.child_portal_points(p_national_id text)
returns table (
  id uuid, enrollment_id uuid, source text, reason text,
  delta integer, created_at timestamptz, recorded_by_name text,
  class_name text, service_name text, church_name text
) language plpgsql stable security definer set search_path = public as $$
declare
  p public.persons;
begin
  p := public.child_portal_person(p_national_id);
  return query
    select x.id, x.enrollment_id, x.source, x.reason, x.delta, x.created_at,
           pr.full_name, cl.name, sv.name, ch.name
      from (
        select pl.id, pl.enrollment_id, 'cause'::text as source,
               ca.name as reason, pl.delta, pl.created_at, pl.recorded_by
          from public.points_log pl
          join public.enrollments e on e.id = pl.enrollment_id
          left join public.causes ca on ca.id = pl.cause_id
         where e.person_id = p.id
        union all
        select a.id, a.enrollment_id, 'attendance'::text,
               ev.name, a.points_delta, a.created_at, a.recorded_by
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
-- 6. REQUESTS — list / submit / cancel
-- ---------------------------------------------------------------------
create or replace function public.child_portal_requests(p_national_id text)
returns setof public.data_change_requests
language plpgsql stable security definer set search_path = public as $$
declare
  p public.persons;
begin
  p := public.child_portal_person(p_national_id);
  return query
    select * from public.data_change_requests
     where person_id = p.id
     order by created_at desc
     limit 100;
end $$;
grant execute on function public.child_portal_requests(text) to anon, authenticated;

create or replace function public.child_portal_submit_request(
  p_national_id text, p_kind text, p_changes jsonb, p_note text default null)
returns public.data_change_requests
language plpgsql security definer set search_path = public as $$
declare
  p public.persons;
  clean jsonb := '{}'::jsonb;
  prev  jsonb := '{}'::jsonb;
  r public.data_change_requests;
  k text;
  allowed text[] := array['name', 'birthdate', 'gender', 'phone', 'address'];
begin
  p := public.child_portal_person(p_national_id);

  if p_kind not in ('data', 'photo') then
    raise exception 'invalid_kind' using errcode = 'P0003';
  end if;

  -- one pending request per kind at a time
  if exists (select 1 from public.data_change_requests
              where person_id = p.id and kind = p_kind and status = 'pending') then
    raise exception 'pending_exists' using errcode = 'P0004';
  end if;

  if p_kind = 'photo' then
    if coalesce(p_changes->>'image_url', '') = '' then
      raise exception 'invalid_changes' using errcode = 'P0005';
    end if;
    clean := jsonb_build_object('image_url', p_changes->>'image_url');
    prev  := jsonb_build_object('image_url', p.image_url);
  else
    -- whitelist fields + keep only the ones that actually differ
    foreach k in array allowed loop
      if p_changes ? k then
        if k = 'gender' and coalesce(p_changes->>k, '') not in ('', 'male', 'female') then
          raise exception 'invalid_changes' using errcode = 'P0005';
        end if;
        if coalesce(p_changes->>k, '') is distinct from coalesce(
             case k
               when 'name' then p.name
               when 'birthdate' then p.birthdate::text
               when 'gender' then p.gender
               when 'phone' then p.phone
               when 'address' then p.address
             end, '') then
          clean := clean || jsonb_build_object(k, nullif(trim(p_changes->>k), ''));
          prev  := prev  || jsonb_build_object(k,
                     case k
                       when 'name' then to_jsonb(p.name)
                       when 'birthdate' then to_jsonb(p.birthdate)
                       when 'gender' then to_jsonb(p.gender)
                       when 'phone' then to_jsonb(p.phone)
                       when 'address' then to_jsonb(p.address)
                     end);
        end if;
      end if;
    end loop;
    if clean = '{}'::jsonb then
      raise exception 'no_changes' using errcode = 'P0006';
    end if;
    -- name may never be emptied
    if clean ? 'name' and clean->>'name' is null then
      raise exception 'invalid_changes' using errcode = 'P0005';
    end if;
  end if;

  insert into public.data_change_requests (person_id, kind, changes, previous, note)
  values (p.id, p_kind, clean, prev, nullif(trim(coalesce(p_note, '')), ''))
  returning * into r;
  return r;
end $$;
grant execute on function public.child_portal_submit_request(text, text, jsonb, text) to anon, authenticated;

create or replace function public.child_portal_cancel_request(p_national_id text, p_request uuid)
returns public.data_change_requests
language plpgsql security definer set search_path = public as $$
declare
  p public.persons;
  r public.data_change_requests;
begin
  p := public.child_portal_person(p_national_id);
  update public.data_change_requests
     set status = 'cancelled', decided_at = now()
   where id = p_request and person_id = p.id and status = 'pending'
  returning * into r;
  if not found then
    raise exception 'not_pending' using errcode = 'P0007';
  end if;
  return r;
end $$;
grant execute on function public.child_portal_cancel_request(text, uuid) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 7. REVIEW (servants) — approve applies the change to persons
-- ---------------------------------------------------------------------
create or replace function public.review_data_change_request(
  p_request uuid, p_approve boolean, p_note text default null)
returns public.data_change_requests
language plpgsql security definer set search_path = public as $$
declare
  r public.data_change_requests;
begin
  select * into r from public.data_change_requests where id = p_request for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0008';
  end if;
  if r.status <> 'pending' then
    raise exception 'not_pending' using errcode = 'P0007';
  end if;
  if not public.can_access_person(r.person_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  if p_approve then
    if r.kind = 'photo' then
      update public.persons
         set image_url = r.changes->>'image_url',
             edited_at = now(), edited_by = auth.uid()
       where id = r.person_id;
    else
      update public.persons
         set name      = case when r.changes ? 'name'      then coalesce(r.changes->>'name', name) else name end,
             birthdate = case when r.changes ? 'birthdate' then (r.changes->>'birthdate')::date else birthdate end,
             gender    = case when r.changes ? 'gender'    then r.changes->>'gender' else gender end,
             phone     = case when r.changes ? 'phone'     then r.changes->>'phone' else phone end,
             address   = case when r.changes ? 'address'   then r.changes->>'address' else address end,
             edited_at = now(), edited_by = auth.uid()
       where id = r.person_id;
    end if;
  end if;

  update public.data_change_requests
     set status = case when p_approve then 'approved' else 'rejected' end,
         decision_note = nullif(trim(coalesce(p_note, '')), ''),
         decided_by = auth.uid(),
         decided_at = now()
   where id = p_request
  returning * into r;
  return r;
end $$;
revoke all on function public.review_data_change_request(uuid, boolean, text) from public, anon;
grant execute on function public.review_data_change_request(uuid, boolean, text) to authenticated;

-- pending requests count for the managers' badge (scoped by RLS through can_access_person)
create or replace function public.pending_data_requests_count()
returns integer language sql stable security invoker set search_path = public as $$
  select count(*)::int from public.data_change_requests where status = 'pending'
$$;
revoke all on function public.pending_data_requests_count() from public, anon;
grant execute on function public.pending_data_requests_count() to authenticated;

-- ---------------------------------------------------------------------
-- 8. STORAGE — child may upload a proposed photo under child-requests/
-- ---------------------------------------------------------------------
drop policy if exists "photos_child_request_upload" on storage.objects;
create policy "photos_child_request_upload" on storage.objects for insert to anon
  with check (bucket_id = 'photos' and (storage.foldername(name))[1] = 'child-requests');

commit;
