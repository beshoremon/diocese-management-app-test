-- =====================================================================
-- SERVANT SESSIONS  (Phase 1 — Supabase Auth replacement for servants)
-- =====================================================================
-- Runs AFTER the application schema (references servant_enrollments, persons,
-- servant_active_places, servant_places(), child_sessions, priest_sessions).
--
-- Replaces the ONE Supabase-coupled auth path (servant login/switch via
-- Supabase Auth JWT + auth.admin.generateLink magiclink) by extending the
-- EXACT token mechanism child_sessions / priest_sessions use (task D2).
-- token = gen_random_bytes(32) hex, stored as sha256; 12h / 90d (remember);
-- sliding extension on touch. The server keeps the opaque token in an
-- HttpOnly cookie and resolves it per request → servant_enrollments.id →
-- app.set_user().
-- =====================================================================

create table if not exists public.servant_sessions (
  id           uuid primary key default gen_random_uuid(),
  servant_id   uuid not null references public.servant_enrollments(id) on delete cascade,
  token_hash   text not null unique,
  remember     boolean not null default false,
  created_at   timestamptz not null default now(),
  expires_at   timestamptz not null,
  last_seen_at timestamptz not null default now(),
  user_agent   text
);
create index if not exists idx_servant_sessions_servant on public.servant_sessions(servant_id);
create index if not exists idx_servant_sessions_expires on public.servant_sessions(expires_at);
comment on table public.servant_sessions is
  'جلسات الخادم (Neon) — تعويض جلسة Supabase Auth: التوكن مخزَّن كـ sha256، 12 ساعة أو 90 يومًا مع «تذكّرني».';
alter table public.servant_sessions enable row level security;
revoke all on public.servant_sessions from anon, authenticated;

-- Resolve a servant session token → servant_enrollments.id (= auth.uid()).
create or replace function public.servant_session_resolve(p_token text)
returns uuid language plpgsql stable security definer set search_path = public, extensions as $$
declare s public.servant_sessions;
begin
  if p_token is null or length(trim(p_token)) < 20 then
    raise exception 'session_expired' using errcode = 'P0002';
  end if;
  select * into s from public.servant_sessions
   where token_hash = encode(digest(trim(p_token), 'sha256'), 'hex');
  if not found or s.expires_at < now() then
    raise exception 'session_expired' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.servant_enrollments se
                 where se.id = s.servant_id and se.status = 'approved') then
    raise exception 'account_stopped' using errcode = 'P0001';
  end if;
  return s.servant_id;
end $$;
revoke all on function public.servant_session_resolve(text) from public, anon, authenticated;
grant execute on function public.servant_session_resolve(text) to service_role;

-- Mint a servant session (server-only). Validates + sets the active place.
create or replace function public.servant_session_mint(
  p_servant uuid, p_remember boolean default true, p_user_agent text default null,
  p_church uuid default null, p_service uuid default null, p_class uuid default null
) returns jsonb language plpgsql volatile security definer set search_path = public, extensions as $$
declare s public.servant_enrollments; v_token text; v_exp timestamptz;
begin
  select * into s from public.servant_enrollments where id = p_servant;
  if not found then raise exception 'no_such_account' using errcode = 'P0002'; end if;
  if s.status = 'pending' then raise exception 'pending_approval' using errcode = 'P0001'; end if;
  if s.status <> 'approved' then raise exception 'account_stopped' using errcode = 'P0001'; end if;

  if p_church is not null and not exists (
      select 1 from public.servant_places(s.id) x
       where x.church_id = p_church
         and x.service_id is not distinct from p_service
         and x.class_id   is not distinct from p_class) then
    raise exception 'scope_not_allowed' using errcode = '42501';
  end if;

  if p_church is not null then
    insert into public.servant_active_places (servant_id, church_id, service_id, class_id)
    values (s.id, p_church, p_service, p_class)
    on conflict (servant_id) do update
      set church_id = excluded.church_id, service_id = excluded.service_id,
          class_id = excluded.class_id, updated_at = now();
  else
    delete from public.servant_active_places where servant_id = s.id;
  end if;

  v_token := encode(gen_random_bytes(32), 'hex');
  v_exp := case when coalesce(p_remember, true) then now() + interval '90 days' else now() + interval '12 hours' end;
  insert into public.servant_sessions (servant_id, token_hash, remember, expires_at, user_agent)
  values (s.id, encode(digest(v_token, 'sha256'), 'hex'), coalesce(p_remember, true), v_exp, left(p_user_agent, 300));
  delete from public.servant_sessions where expires_at < now() - interval '1 day';

  return jsonb_build_object('kind','servant','token', v_token, 'expires_at', v_exp,
                            'servant_id', s.id, 'person_id', s.person_id);
end $$;
revoke all on function public.servant_session_mint(uuid, boolean, text, uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function public.servant_session_mint(uuid, boolean, text, uuid, uuid, uuid) to service_role;

create or replace function public.servant_session_touch(p_token text)
returns jsonb language plpgsql volatile security definer set search_path = public, extensions as $$
declare s public.servant_sessions;
begin
  if p_token is null or length(trim(p_token)) < 20 then raise exception 'session_expired' using errcode = 'P0002'; end if;
  select * into s from public.servant_sessions where token_hash = encode(digest(trim(p_token), 'sha256'), 'hex');
  if not found then raise exception 'session_expired' using errcode = 'P0002'; end if;
  if s.expires_at < now() then delete from public.servant_sessions where id = s.id; raise exception 'session_expired' using errcode = 'P0002'; end if;
  update public.servant_sessions
     set last_seen_at = now(),
         expires_at = case when remember then greatest(expires_at, now() + interval '90 days') else expires_at end
   where id = s.id returning * into s;
  return jsonb_build_object('servant_id', s.servant_id, 'expires_at', s.expires_at, 'remember', s.remember);
end $$;
revoke all on function public.servant_session_touch(text) from public, anon;
grant execute on function public.servant_session_touch(text) to service_role, authenticated;

create or replace function public.servant_session_logout(p_token text)
returns void language plpgsql volatile security definer set search_path = public, extensions as $$
begin
  if nullif(trim(coalesce(p_token,'')),'') is null then return; end if;
  delete from public.servant_sessions where token_hash = encode(digest(trim(p_token), 'sha256'), 'hex');
end $$;
revoke all on function public.servant_session_logout(text) from public, anon;
grant execute on function public.servant_session_logout(text) to service_role, authenticated;

-- Override account_mint's servant branch to issue a REAL servant session on
-- Neon (was: a 2-min account_switch_ticket for the Supabase magiclink). Only
-- the p_to_kind='servant' branch changed; child/priest branches identical.
create or replace function public.account_mint(
  p_person uuid, p_to_kind text, p_enrollment uuid, p_remember boolean, p_ua text,
  p_church uuid default null, p_service uuid default null, p_class uuid default null
) returns jsonb language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  p public.persons; s public.servant_enrollments; pr public.priests; e public.enrollments;
  v_token text; v_exp timestamptz;
begin
  select * into p from public.persons where id = p_person;
  v_exp := case when coalesce(p_remember, true) then now() + interval '90 days' else now() + interval '12 hours' end;

  if p_to_kind = 'child' then
    if p_enrollment is not null then
      select * into e from public.enrollments where id = p_enrollment and person_id = p_person and kind = 'child';
      if not found then raise exception 'no_such_account' using errcode = 'P0002'; end if;
      if e.status <> 'active' then raise exception 'account_stopped' using errcode = 'P0011'; end if;
    else
      if not exists (select 1 from public.enrollments x where x.person_id = p_person and x.kind = 'child') then
        raise exception 'no_such_account' using errcode = 'P0002';
      end if;
      if not exists (select 1 from public.enrollments x where x.person_id = p_person and x.kind = 'child' and x.status = 'active') then
        raise exception 'account_stopped' using errcode = 'P0011';
      end if;
    end if;
    v_token := encode(gen_random_bytes(32), 'hex');
    insert into public.child_sessions (person_id, token_hash, remember, expires_at, user_agent, enrollment_id)
    values (p_person, encode(digest(v_token, 'sha256'), 'hex'), coalesce(p_remember, true), v_exp, left(p_ua, 300), p_enrollment);
    return jsonb_build_object('kind', 'child', 'token', v_token, 'expires_at', v_exp, 'person_id', p_person, 'enrollment_id', p_enrollment);

  elsif p_to_kind = 'priest' then
    select * into pr from public.priests where person_id = p_person;
    if not found then raise exception 'no_such_account' using errcode = 'P0002'; end if;
    if pr.status = 'pending' then raise exception 'pending_approval' using errcode = 'P0001'; end if;
    if pr.status <> 'approved' then raise exception 'account_stopped' using errcode = 'P0001'; end if;
    v_token := encode(gen_random_bytes(32), 'hex');
    insert into public.priest_sessions (priest_id, token_hash, remember, expires_at, user_agent)
    values (pr.id, encode(digest(v_token, 'sha256'), 'hex'), coalesce(p_remember, true), v_exp, left(p_ua, 300));
    perform set_config('app.priest_actor', pr.id::text, true);
    return jsonb_build_object('kind', 'priest', 'token', v_token, 'expires_at', v_exp, 'priest_id', pr.id);

  elsif p_to_kind = 'servant' then
    select * into s from public.servant_enrollments where person_id = p_person;
    if not found then raise exception 'no_such_account' using errcode = 'P0002'; end if;
    return public.servant_session_mint(s.id, p_remember, p_ua, p_church, p_service, p_class);
  end if;
  raise exception 'invalid_kind' using errcode = '22023';
end $$;
revoke all on function public.account_mint(uuid, text, uuid, boolean, text, uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function public.account_mint(uuid, text, uuid, boolean, text, uuid, uuid, uuid) to service_role;
