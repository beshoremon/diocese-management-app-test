-- =====================================================================
-- NEON OWNER BOOTSTRAP  (replaces Supabase-Auth-specific 0002)
-- =====================================================================
-- Creates the first usable login on a brand-new Neon database:
--      login code : 000000
--      password   : 000000
-- ⚠  Change both after first login (الإعدادات → تعديل بياناتي).
--
-- Unlike 0002 (which wrote a Supabase auth.users row + Supabase identities),
-- this writes the Neon-owned identity set:
--   * auth.users             — the servant login account (bcrypt pw hash)
--   * persons                — the person (code = national_id)
--   * servant_enrollments    — owner role, approved, id = auth.users.id
--   * person_credentials     — bcrypt password for the unified account_login
-- Idempotent.
-- =====================================================================
do $$
declare
  c_code     constant text := '000000';
  c_password constant text := '000000';
  c_name     constant text := 'مالك التطبيق';
  c_phone    constant text := '0000000000';
  v_id    uuid := gen_random_uuid();
  v_login text;
  v_email text;
  v_pid   uuid;
begin
  perform set_config('search_path', 'public, extensions', true);

  if to_regprocedure('public.code_to_user_id(text)') is not null then
    execute 'select public.code_to_user_id($1)' into v_login using c_code;
  else
    v_login := lower(trim(c_code));
  end if;
  v_email := v_login || '@diocese.app';

  if exists (select 1 from auth.users where lower(email) = lower(v_email)) then
    raise notice '30_bootstrap: % already exists — nothing to do', v_email;
    return;
  end if;

  -- login account (Neon-owned auth.users)
  insert into auth.users (id, email, encrypted_password, raw_user_meta_data)
  values (v_id, v_email, crypt(c_password, gen_salt('bf', 10)),
          jsonb_build_object('code', c_code, 'full_name', c_name));

  -- person
  insert into public.persons (national_id, name, phone)
  values (c_code, c_name, c_phone)
  on conflict (national_id) do update set name = excluded.name, phone = excluded.phone
  returning id into v_pid;

  -- owner servant enrollment (id = login id)
  insert into public.servant_enrollments (id, full_name, user_id, phone, role, status, approved_at, person_id)
  values (v_id, c_name, v_login, c_phone, 'owner', 'approved', now(), v_pid)
  on conflict (id) do update set role = 'owner', status = 'approved', approved_at = now();

  -- unified password (so account_login works without Supabase Auth)
  insert into public.person_credentials (person_id, password_hash)
  values (v_pid, crypt(c_password, gen_salt('bf', 10)))
  on conflict (person_id) do update set password_hash = excluded.password_hash, updated_at = now();

  raise notice E'\n=== OWNER CREATED (Neon) ===\n  code: %  password: %  uuid: %\n  ⚠ change code + password after first login', c_code, c_password, v_id;
end $$;
