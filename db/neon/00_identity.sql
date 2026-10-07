-- =====================================================================
-- NEON IDENTITY LAYER  (Phase 1 — Supabase → Neon)
-- =====================================================================
-- Runs ONCE on a fresh Neon database, BEFORE the application schema.
-- Replaces everything the Supabase platform provided for identity, WITHOUT
-- changing any of the 261 RLS policies or ~250 RPCs:
--   * `app` schema is the ONE place identity is defined (task D2);
--   * `auth.uid()` / `auth.role()` are THIN DELEGATES to `app.uid()` /
--     `app.role()`, so the 308 existing `auth.uid()` sites keep working —
--     the "auth.uid() → app.uid()" change is centralized as D2 requires;
--   * the server sets identity per request with `app.set_user(uuid, role)`
--     (SET LOCAL) AFTER validating the session server-side. A forged request
--     sets nothing → app.uid() NULL → RLS denies.
--
-- SECURITY INVARIANTS (D2): no plaintext passwords (bcrypt); DB creds/session
-- secret never reach the client; identity validated server-side & injected as
-- a GUC the client cannot influence; client-supplied user_id/role/church_id/
-- service_id/class_id never trusted (RLS reads them from the person's own rows
-- via SECURITY DEFINER helpers).
-- =====================================================================

-- ---------- extensions (Supabase used `extensions`; Neon → public) ----------
create extension if not exists pgcrypto;
create extension if not exists pg_trgm;
-- migrations use `set search_path = public, extensions`; provide the schema so
-- those paths resolve (extension fns live in public, found via search_path).
create schema if not exists extensions;

-- ---------- roles (anon / authenticated / service_role) ----------
do $$ begin
  if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname='service_role') then create role service_role nologin; end if;
end $$;

-- ---------- realtime publication (D4: no realtime provider yet) ----------
-- Migrations do `alter publication supabase_realtime add table …`; create an
-- EMPTY publication so those succeed. Nothing consumes it (refetch-on-focus).
do $$ begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
end $$;

-- =====================================================================
-- app  — the single identity authority
-- =====================================================================
create schema if not exists app;

-- Reuse the GUC names Supabase/PostgREST used (request.jwt.claim.sub/.role) so
-- the 40+ existing SQL tests and auth.uid() need no rewrite. app.* is the
-- documented surface; the GUC is the storage detail.

create or replace function app.uid() returns uuid
language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;

create or replace function app.role() returns text
language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claim.role', true), ''), 'anon')
$$;

-- Server-side identity setter (lib/db withUser at request start, AFTER the
-- session is validated). Never exposed over the data gateway.
create or replace function app.set_user(p_uid uuid, p_role text default 'authenticated', p_local boolean default true)
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub',  coalesce(p_uid::text, ''), p_local);
  perform set_config('request.jwt.claim.role', coalesce(nullif(p_role,''), 'authenticated'), p_local);
end $$;

create or replace function app.clear_user(p_local boolean default true)
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub',  '', p_local);
  perform set_config('request.jwt.claim.role', 'anon', p_local);
end $$;

revoke all on function app.set_user(uuid, text, boolean) from public, anon, authenticated;
revoke all on function app.clear_user(boolean) from public, anon, authenticated;
grant execute on function app.uid() to public;
grant execute on function app.role() to public;

-- =====================================================================
-- auth  — compatibility delegates (308 auth.uid() sites untouched)
-- =====================================================================
create schema if not exists auth;

create or replace function auth.uid() returns uuid
language sql stable as $$ select app.uid() $$;

create or replace function auth.role() returns text
language sql stable as $$ select app.role() $$;

grant usage on schema auth to anon, authenticated, service_role;

-- auth.users — now a PLAIN owned table: the servant login account.
-- `encrypted_password` carries the bcrypt hash imported from Supabase during
-- data migration. No Supabase Auth server involved any more.
create table if not exists auth.users (
  id                 uuid primary key default gen_random_uuid(),
  email              text,
  encrypted_password text,
  raw_user_meta_data jsonb default '{}'::jsonb,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
create unique index if not exists idx_auth_users_email on auth.users (lower(email)) where email is not null;
alter table auth.users enable row level security;
revoke all on auth.users from anon, authenticated;

comment on schema app is 'Neon identity authority: app.uid()/app.role()/app.set_user() — replaces Supabase Auth JWT context.';
comment on schema auth is 'Compatibility shim: auth.uid()/auth.role() delegate to app.*; auth.users is now a plain owned table.';
