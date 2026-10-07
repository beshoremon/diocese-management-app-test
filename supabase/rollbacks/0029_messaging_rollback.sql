-- =====================================================================
-- ROLLBACK of 0029_messaging.sql — إلغاء وحدة الرسائل والإشعارات
--
-- Restores the database to its state after 0028_birthdays.sql by
-- removing EVERYTHING migration 0029 created:
--   • triggers it attached to pre-existing tables (attendance_log,
--     points_log, enrollments, exam_attempts, store_orders,
--     data_change_requests, profiles)
--   • all msg_* / messaging_* functions and the child_portal_* RPCs that
--     0029 introduced (no earlier migration defines these names)
--   • the 10 messaging tables (with their policies, indexes, triggers,
--     realtime publication membership)
--   • the storage policy for the photos/messages folder
--   • the pg_cron job `messaging_tick` (when pg_cron exists)
--   • module_access grants for the 'messaging' module key
--
-- Nothing outside the messaging module is touched. Idempotent — safe to
-- re-run. Run it in the Supabase SQL editor (Dashboard → SQL Editor).
--
-- ⚠ Destructive: all notifications / conversations / messages /
--   automations / templates / campaigns / delivery logs are deleted.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Triggers on PRE-EXISTING tables (event-based automations)
-- ---------------------------------------------------------------------
drop trigger if exists zz_msg_on_attendance        on public.attendance_log;
drop trigger if exists zz_msg_on_points            on public.points_log;
drop trigger if exists zz_msg_on_enrollment        on public.enrollments;
drop trigger if exists zz_msg_on_exam_result       on public.exam_attempts;
drop trigger if exists zz_msg_on_store_order       on public.store_orders;
drop trigger if exists zz_msg_on_data_request      on public.data_change_requests;
drop trigger if exists zz_msg_on_data_request_new  on public.data_change_requests;
drop trigger if exists zz_msg_on_profile_change    on public.profiles;

-- ---------------------------------------------------------------------
-- 2. pg_cron job (only when the extension exists)
-- ---------------------------------------------------------------------
do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'messaging_tick';
  end if;
exception when others then
  raise notice 'pg_cron cleanup skipped: %', sqlerrm;
end $$;

-- ---------------------------------------------------------------------
-- 3. Storage policy added by 0029 (photos/messages folder)
-- ---------------------------------------------------------------------
do $$ begin
  if to_regclass('storage.objects') is not null then
    execute 'drop policy if exists "photos_messages_upload" on storage.objects';
  end if;
exception when others then
  raise notice 'storage policy cleanup skipped: %', sqlerrm;
end $$;

-- ---------------------------------------------------------------------
-- 4. Realtime publication membership (dropping the tables would do it,
--    but be explicit so the drop never fails on a publication lock)
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['notifications', 'messages', 'conversations', 'conversation_members',
                             'message_deliveries', 'outbound_queue', 'message_campaigns',
                             'messaging_settings', 'message_templates', 'message_automations'] loop
      if exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
        execute format('alter publication supabase_realtime drop table public.%I', t);
      end if;
    end loop;
  end if;
exception when others then
  raise notice 'publication cleanup skipped: %', sqlerrm;
end $$;

-- ---------------------------------------------------------------------
-- 5. Tables (cascade removes policies, indexes, own triggers, FKs)
-- ---------------------------------------------------------------------
drop table if exists public.outbound_queue        cascade;
drop table if exists public.message_deliveries    cascade;
drop table if exists public.messages              cascade;
drop table if exists public.conversation_members  cascade;
drop table if exists public.conversations         cascade;
drop table if exists public.notifications         cascade;
drop table if exists public.message_campaigns     cascade;
drop table if exists public.message_automations   cascade;
drop table if exists public.message_templates     cascade;
drop table if exists public.messaging_settings    cascade;

-- ---------------------------------------------------------------------
-- 6. Functions — every overload, by name. All of these names were
--    introduced by 0029 (verified: no migration 0001–0028 defines them).
-- ---------------------------------------------------------------------
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and (
        p.proname like 'msg\_%' escape '\'
        or p.proname in (
          'messaging_tick',
          'check_messaging_scope_chain',
          'messages_after_insert',
          'child_portal_notifications',
          'child_portal_notifications_read',
          'child_portal_conversations',
          'child_portal_messages',
          'child_portal_send',
          'child_portal_open_direct',
          'child_portal_badge'
        )
      )
  loop
    execute format('drop function if exists %s cascade', r.sig);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 7. Module visibility grants for the removed module key
-- ---------------------------------------------------------------------
delete from public.module_access where module_key = 'messaging';

commit;

-- ---------------------------------------------------------------------
-- Verification (run separately, expect 0 rows / 0 for each)
-- ---------------------------------------------------------------------
-- select tablename from pg_tables where schemaname = 'public'
--   and tablename in ('messaging_settings','message_templates','message_automations',
--                     'message_campaigns','notifications','conversations',
--                     'conversation_members','messages','message_deliveries','outbound_queue');
-- select proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--   where n.nspname = 'public' and (proname like 'msg\_%' or proname = 'messaging_tick');
-- select tgname from pg_trigger where tgname like 'zz_msg_%';
