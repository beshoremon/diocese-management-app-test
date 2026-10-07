-- =====================================================================
-- 0033: HOTFIX — occasion ticket code without pgcrypto
--
-- `occasion_new_ticket_code()` (0032) used `gen_random_bytes`, which on
-- Supabase lives in the `extensions` schema; the function pins
-- `search_path = public`, so every registration failed with
--   42883: function gen_random_bytes(integer) does not exist
-- Rebuilt on core `gen_random_uuid()` — same «T-» + 10 hex-char shape.
-- 0032 itself is patched the same way for fresh installs. Idempotent.
-- =====================================================================

begin;

create or replace function public.occasion_new_ticket_code()
returns text language plpgsql volatile security definer set search_path = public as $$
declare v text; i integer := 0;
begin
  loop
    v := 'T-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));
    exit when not exists (select 1 from public.occasion_registrations r where r.ticket_code = v);
    i := i + 1;
    if i > 20 then raise exception 'ticket_code_collision'; end if;
  end loop;
  return v;
end $$;
revoke all on function public.occasion_new_ticket_code() from public, anon, authenticated;

notify pgrst, 'reload schema';

commit;
