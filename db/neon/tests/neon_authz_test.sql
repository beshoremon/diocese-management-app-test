-- =====================================================================
-- NEON AUTHORIZATION & SECURITY TEST  (Phase 1 acceptance criteria)
-- =====================================================================
-- Proves, on the Neon identity layer (app.uid()/app.set_user + RLS), that:
--   * owner / church-manager / service-manager / class-servant scoping works
--   * cross-CHURCH, cross-SERVICE, cross-CLASS reads are blocked by RLS
--   * a FORGED identity (unknown uuid) sees nothing
--   * the new servant session flow (token, not Supabase ticket) works E2E
--   * identity is taken ONLY from the server-set GUC, never from client input
--
-- Run (fresh Neon build, incl. grants + servant auth):
--   psql -d neon_app -f db/neon/tests/neon_authz_test.sql
-- Ends with «NEON AUTHZ TESTS PASSED» or raises on the first failure.
-- Everything runs in one transaction and rolls back.
-- =====================================================================
\set ON_ERROR_STOP on
begin;

-- ---------- helper: run as a given identity (what the server does) ----------
create or replace function pg_temp.act_as(p_uid uuid) returns void
language plpgsql as $$
begin
  perform set_config('role', 'authenticated', true);
  perform public.app_set_user_shim(p_uid);
end $$;

-- wrappers so the test can set/clear identity though app.set_user/clear_user
-- are owner-only (mirrors the trusted server call)
create or replace function public.app_set_user_shim(p_uid uuid) returns void
language sql security definer as $$ select app.set_user(p_uid, 'authenticated') $$;
create or replace function public.app_clear_user_shim() returns void
language sql security definer as $$ select app.clear_user() $$;

-- =====================================================================
-- SEED: two churches, each with a service + class; four servants
-- =====================================================================
insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000000a1'),  -- owner
  ('00000000-0000-0000-0000-0000000000a2'),  -- church A manager
  ('00000000-0000-0000-0000-0000000000a3'),  -- church A, service-1 manager
  ('00000000-0000-0000-0000-0000000000a4'),  -- church A, service-1, class-1 servant
  ('00000000-0000-0000-0000-0000000000b2');  -- church B manager

insert into public.churches (id, name) values
  ('c0000000-0000-0000-0000-00000000000a', 'كنيسة أ'),
  ('c0000000-0000-0000-0000-00000000000b', 'كنيسة ب');
insert into public.services (id, church_id, name) values
  ('50000000-0000-0000-0000-0000000000a1', 'c0000000-0000-0000-0000-00000000000a', 'خدمة أ-1'),
  ('50000000-0000-0000-0000-0000000000b1', 'c0000000-0000-0000-0000-00000000000b', 'خدمة ب-1');
insert into public.classes (id, church_id, service_id, name) values
  ('c1000000-0000-0000-0000-0000000000a1', 'c0000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-0000000000a1', 'فصل أ-1'),
  ('c1000000-0000-0000-0000-0000000000a2', 'c0000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-0000000000a1', 'فصل أ-2'),
  ('c1000000-0000-0000-0000-0000000000b1', 'c0000000-0000-0000-0000-00000000000b', '50000000-0000-0000-0000-0000000000b1', 'فصل ب-1');

insert into public.servant_enrollments (id, full_name, user_id, phone, role, status, approved_at) values
  ('00000000-0000-0000-0000-0000000000a1', 'المالك', 'owner', '01', 'owner', 'approved', now());
insert into public.servant_enrollments (id, full_name, user_id, phone, role, status, church_id, approved_at) values
  ('00000000-0000-0000-0000-0000000000a2', 'مدير أ', 'mgrA', '02', 'church_manager', 'approved', 'c0000000-0000-0000-0000-00000000000a', now()),
  ('00000000-0000-0000-0000-0000000000b2', 'مدير ب', 'mgrB', '05', 'church_manager', 'approved', 'c0000000-0000-0000-0000-00000000000b', now());
insert into public.servant_enrollments (id, full_name, user_id, phone, role, status, church_id, service_id, approved_at) values
  ('00000000-0000-0000-0000-0000000000a3', 'مدير خدمة أ1', 'svcA1', '03', 'service_manager', 'approved', 'c0000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-0000000000a1', now());
insert into public.servant_enrollments (id, full_name, user_id, phone, role, status, church_id, service_id, class_id, approved_at) values
  ('00000000-0000-0000-0000-0000000000a4', 'خادم فصل أ1', 'clsA1', '04', 'class_servant', 'approved', 'c0000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-0000000000a1', 'c1000000-0000-0000-0000-0000000000a1', now());

-- =====================================================================
-- 1. IDENTITY SANITY
-- =====================================================================
set local role authenticated;
select public.app_set_user_shim('00000000-0000-0000-0000-0000000000a1');  -- owner
do $$ begin
  if app.uid() <> '00000000-0000-0000-0000-0000000000a1' then raise exception 'app.uid wrong'; end if;
  if auth.uid() <> app.uid() then raise exception 'auth.uid must delegate to app.uid'; end if;
  if public.my_role() <> 'owner' then raise exception 'owner role expected, got %', public.my_role(); end if;
  if not public.is_owner() then raise exception 'is_owner expected'; end if;
end $$;

-- =====================================================================
-- 2. OWNER sees ALL churches; managers/servants see only THEIRS
-- =====================================================================
do $$ begin
  if (select count(*) from public.churches) <> 2 then raise exception 'owner must see 2 churches, saw %', (select count(*) from public.churches); end if;
end $$;

select public.app_set_user_shim('00000000-0000-0000-0000-0000000000a2');  -- church A manager
do $$ begin
  if (select count(*) from public.churches) <> 1 then raise exception 'church A mgr must see 1 church'; end if;
  if (select id from public.churches) <> 'c0000000-0000-0000-0000-00000000000a' then raise exception 'church A mgr must see ONLY church A'; end if;
  if exists (select 1 from public.services where church_id = 'c0000000-0000-0000-0000-00000000000b') then raise exception 'CROSS-CHURCH LEAK: mgr A saw church B service'; end if;
  if exists (select 1 from public.classes  where church_id = 'c0000000-0000-0000-0000-00000000000b') then raise exception 'CROSS-CHURCH LEAK: mgr A saw church B class'; end if;
end $$;

select public.app_set_user_shim('00000000-0000-0000-0000-0000000000b2');  -- church B manager
do $$ begin
  if (select id from public.churches) <> 'c0000000-0000-0000-0000-00000000000b' then raise exception 'church B mgr must see ONLY church B'; end if;
  if exists (select 1 from public.classes where church_id = 'c0000000-0000-0000-0000-00000000000a') then raise exception 'CROSS-CHURCH LEAK: mgr B saw church A class'; end if;
end $$;

-- =====================================================================
-- 3. SERVICE manager: only his service (cross-service blocked)
-- =====================================================================
select public.app_set_user_shim('00000000-0000-0000-0000-0000000000a3');
do $$ begin
  if not public.can_access('c0000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-0000000000a1', null)
    then raise exception 'service mgr must access his own service'; end if;
  if public.can_access('c0000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-0000000000b1', null)
    then raise exception 'CROSS-SERVICE LEAK: service mgr accessed another service'; end if;
end $$;

-- =====================================================================
-- 4. CLASS servant: only his class (cross-class blocked)
-- =====================================================================
select public.app_set_user_shim('00000000-0000-0000-0000-0000000000a4');
do $$ begin
  if not public.can_access('c0000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-0000000000a1', 'c1000000-0000-0000-0000-0000000000a1')
    then raise exception 'class servant must access his own class'; end if;
  if public.can_access('c0000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-0000000000a1', 'c1000000-0000-0000-0000-0000000000a2')
    then raise exception 'CROSS-CLASS LEAK: class servant accessed another class'; end if;
end $$;

-- =====================================================================
-- 5. FORGED / UNKNOWN identity sees nothing; ANON sees nothing
-- =====================================================================
select public.app_set_user_shim('ffffffff-ffff-ffff-ffff-ffffffffffff');
do $$ begin
  if public.my_role() is not null then raise exception 'forged uid must have NULL role'; end if;
  if public.is_owner() then raise exception 'forged uid must NOT be owner'; end if;
  if (select count(*) from public.churches) <> 0 then raise exception 'FORGED-ID LEAK: unknown uid saw % churches', (select count(*) from public.churches); end if;
end $$;

select public.app_clear_user_shim();
do $$ begin
  if (select count(*) from public.churches) <> 0 then raise exception 'ANON LEAK: anon saw churches'; end if;
end $$;

-- =====================================================================
-- 6. Client cannot forge scope: RLS reads church_id from the DB, not input
-- =====================================================================
select public.app_set_user_shim('00000000-0000-0000-0000-0000000000a2');  -- church A manager
do $$ begin
  if public.can_access('c0000000-0000-0000-0000-00000000000b', null, null)
    then raise exception 'FORGED-SCOPE LEAK: mgr A was granted church B by passing its id'; end if;
end $$;

-- =====================================================================
-- 7. NEW SERVANT SESSION FLOW (token, not Supabase ticket) end-to-end
-- =====================================================================
reset role;
do $$
declare sess jsonb; token text; resolved uuid;
begin
  sess := public.account_mint(
            (select person_id from public.servant_enrollments where id='00000000-0000-0000-0000-0000000000a4'),
            'servant', null, true, 'test',
            'c0000000-0000-0000-0000-00000000000a', '50000000-0000-0000-0000-0000000000a1', 'c1000000-0000-0000-0000-0000000000a1');
  if sess->>'kind' <> 'servant' then raise exception 'expected servant kind'; end if;
  if sess->>'token' is null then raise exception 'NEON servant flow must return a TOKEN (not a Supabase ticket)'; end if;
  if sess ? 'ticket' then raise exception 'NEON servant flow must NOT return a ticket'; end if;
  token := sess->>'token';
  if length(token) <> 64 then raise exception 'token must be 64 hex chars'; end if;

  resolved := public.servant_session_resolve(token);
  if resolved <> '00000000-0000-0000-0000-0000000000a4' then raise exception 'token must resolve to the class servant'; end if;

  begin perform public.servant_session_resolve('deadbeef'); raise exception 'short token must fail';
  exception when others then if sqlerrm not like '%session_expired%' then raise; end if; end;
end $$;

do $$ begin raise notice 'NEON AUTHZ TESTS PASSED'; end $$;
rollback;
