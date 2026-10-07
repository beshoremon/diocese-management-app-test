-- =====================================================================
-- 0016: DATA JOB — view / edit / delete a person from the children page
--
-- 1. Enrollment delete: anyone who can access the enrollment scope may
--    remove the person FROM that class/service/church (previously only
--    owner / church_manager / service_manager).
--    FK cascade: enrollment -> attendance, attendance_log, points_log.
--
-- 2. delete_person_cascade RPC: delete the person COMPLETELY from the
--    database. FK cascade removes ALL his enrollments and every log row
--    that references them (attendance / attendance_log / points_log).
--    Allowed for the owner, or for a user who can access EVERY
--    enrollment of the person (so nobody wipes data of another scope).
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Enrollment delete follows the same scope rule as insert/update
-- ---------------------------------------------------------------------
drop policy if exists enrollments_delete on public.enrollments;
create policy enrollments_delete on public.enrollments for delete using (
  public.can_access(church_id, service_id, class_id)
);

-- ---------------------------------------------------------------------
-- 2. Full cascade delete of a person (all enrollments + all logs)
-- ---------------------------------------------------------------------
create or replace function public.delete_person_cascade(p_person uuid)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if public.my_role() is null then
    raise exception 'not_approved' using errcode = '42501';
  end if;

  if not public.is_owner() then
    -- The user must be able to access EVERY enrollment of this person —
    -- otherwise he would be wiping data belonging to another scope.
    if exists (
      select 1 from public.enrollments e
       where e.person_id = p_person
         and not public.can_access(e.church_id, e.service_id, e.class_id)
    ) then
      raise exception 'no_access' using errcode = '42501';
    end if;

    -- Person without any enrollment: only his creator (or owner) may delete
    if not exists (select 1 from public.enrollments e where e.person_id = p_person) then
      if not exists (
        select 1 from public.persons p
         where p.id = p_person and p.created_by = auth.uid()
      ) then
        raise exception 'no_access' using errcode = '42501';
      end if;
    end if;
  end if;

  -- FK cascade: persons -> enrollments -> attendance / attendance_log / points_log
  delete from public.persons where id = p_person;
end $$;

commit;
