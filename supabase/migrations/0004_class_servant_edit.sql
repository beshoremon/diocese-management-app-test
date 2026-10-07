-- 0004: allow class servant to edit his own class (name/description)
-- "every user can edit according to his level" — class servant's level is his class.

drop policy if exists classes_update on public.classes;
create policy classes_update on public.classes for update using (
  public.is_owner()
  or (public.my_role() = 'church_manager' and church_id = public.my_church())
  or (public.my_role() = 'service_manager' and service_id = public.my_service())
  or (public.my_role() = 'class_servant' and id = public.my_class())
);

-- Guard: class servant must not move his class to another church/service
create or replace function public.guard_class_update()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if public.my_role() = 'class_servant' then
    if new.church_id is distinct from old.church_id
       or new.service_id is distinct from old.service_id then
      raise exception 'class servants cannot move a class';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists trg_guard_class_update on public.classes;
create trigger trg_guard_class_update
  before update on public.classes
  for each row execute function public.guard_class_update();
