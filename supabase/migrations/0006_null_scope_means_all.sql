-- 0006: empty (null) scope at a lower level means "ALL" under the parent scope.
-- e.g. service_manager with null service_id => all services in his church;
--      class_servant with null class_id => all classes in his service (or church).

-- 1) can_access with cascading null semantics
create or replace function public.can_access(p_church uuid, p_service uuid, p_class uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select case public.my_role()
    when 'owner' then true
    when 'church_manager' then p_church = public.my_church()
    when 'service_manager' then
      (public.my_service() is null and p_church = public.my_church())
      or p_service = public.my_service()
    when 'class_servant' then
      (public.my_class() is null and (
        (public.my_service() is null and p_church = public.my_church())
        or p_service = public.my_service()
      ))
      or p_class = public.my_class()
    else false
  end
$$;

-- 2) services_select: null service scope => all services of own church
drop policy if exists services_select on public.services;
create policy services_select on public.services for select using (
  public.is_owner()
  or (public.my_role() = 'church_manager' and church_id = public.my_church())
  or (public.my_role() in ('service_manager','class_servant') and (
       id = public.my_service()
       or (public.my_service() is null and church_id = public.my_church())
  ))
);

-- 3) profiles_select: service manager with null service sees his whole church
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select using (
  id = auth.uid()
  or public.is_owner()
  or (public.my_role() = 'church_manager' and church_id = public.my_church())
  or (public.my_role() = 'service_manager' and (
       service_id = public.my_service()
       or (public.my_service() is null and church_id = public.my_church())
  ))
);

-- 4) profiles_update_mgmt / profiles_delete: same null-scope semantics
drop policy if exists profiles_update_mgmt on public.profiles;
create policy profiles_update_mgmt on public.profiles for update using (
  public.is_owner()
  or (public.my_role() = 'church_manager' and church_id = public.my_church())
  or (public.my_role() = 'service_manager' and (
       service_id = public.my_service()
       or (public.my_service() is null and church_id = public.my_church())
  ))
);

drop policy if exists profiles_delete on public.profiles;
create policy profiles_delete on public.profiles for delete using (
  public.is_owner()
  or (public.my_role() = 'church_manager' and church_id = public.my_church())
  or (public.my_role() = 'service_manager' and (
       service_id = public.my_service()
       or (public.my_service() is null and church_id = public.my_church())
  ))
);

-- 5) services_update: null-scope service manager may edit all services of his church
drop policy if exists services_update on public.services;
create policy services_update on public.services for update using (
  public.is_owner()
  or (public.my_role() = 'church_manager' and church_id = public.my_church())
  or (public.my_role() = 'service_manager' and (
       id = public.my_service()
       or (public.my_service() is null and church_id = public.my_church())
  ))
);

-- 6) classes insert/update/delete: null-scope semantics for service manager
drop policy if exists classes_insert on public.classes;
create policy classes_insert on public.classes for insert with check (
  public.is_owner()
  or (public.my_role() = 'church_manager' and church_id = public.my_church())
  or (public.my_role() = 'service_manager' and (
       service_id = public.my_service()
       or (public.my_service() is null and church_id = public.my_church())
  ))
);

drop policy if exists classes_update on public.classes;
create policy classes_update on public.classes for update using (
  public.is_owner()
  or (public.my_role() = 'church_manager' and church_id = public.my_church())
  or (public.my_role() = 'service_manager' and (
       service_id = public.my_service()
       or (public.my_service() is null and church_id = public.my_church())
  ))
  or (public.my_role() = 'class_servant' and id = public.my_class())
);

drop policy if exists classes_delete on public.classes;
create policy classes_delete on public.classes for delete using (
  public.is_owner()
  or (public.my_role() = 'church_manager' and church_id = public.my_church())
  or (public.my_role() = 'service_manager' and (
       service_id = public.my_service()
       or (public.my_service() is null and church_id = public.my_church())
  ))
);
