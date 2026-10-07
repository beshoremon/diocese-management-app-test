-- =====================================================================
-- ROLE GRANTS (post-schema)  — Phase 1
-- =====================================================================
-- The BASELINE public grants are set as DEFAULT PRIVILEGES in
-- db/neon/00_identity.sql (BEFORE the migrations) so each created object
-- inherits them and the migrations' 184 explicit REVOKEs take final effect.
-- This file only covers what default-privileges can't: the app / storage /
-- auth identity objects (created in 00, before the default-privilege grantor
-- rule could apply to them).
--
-- It does NOT blanket-grant public tables — doing so would clobber the
-- migrations' security REVOKEs (person_credentials, *_password, admin_*,
-- app_bootstrap, token columns, …). Task D1: RLS + those revokes are the
-- security boundary and must stay functionally equivalent.
--
-- PRODUCTION CONNECTION MODEL (NEON_SETUP.md): the app connects as a LOGIN
-- role that is NOT superuser and NOT BYPASSRLS; per request lib/db does
--   SET LOCAL ROLE authenticated;  SELECT app.set_user(<uid>,'authenticated');
-- A forged request → no app.set_user → app.uid() NULL → RLS denies.
-- =====================================================================

-- app identity helpers: readable by all; the SETTER stays server/owner-only.
grant usage on schema app to anon, authenticated, service_role;
grant execute on function app.uid()  to anon, authenticated, service_role;
grant execute on function app.role() to anon, authenticated, service_role;
revoke all on function app.set_user(uuid, text, boolean) from anon, authenticated;
revoke all on function app.clear_user(boolean) from anon, authenticated;

-- auth compat
grant usage on schema auth to anon, authenticated, service_role;
grant execute on function auth.uid()  to anon, authenticated, service_role;
grant execute on function auth.role() to anon, authenticated, service_role;
-- auth.users is sensitive (login accounts + bcrypt): server/owner only.
revoke all on auth.users from anon, authenticated;

-- storage compat (inert; Phase 2 → Vercel Blob) — the migrations' storage RLS
-- policies reference these; grant the same access Supabase's anon/auth had.
grant usage on schema storage to anon, authenticated, service_role;
grant select, insert, update, delete on storage.objects to anon, authenticated;
grant select on storage.buckets to anon, authenticated;
