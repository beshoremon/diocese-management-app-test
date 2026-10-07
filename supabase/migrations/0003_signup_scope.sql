-- =====================================================================
-- 0003 — Signup scope support
-- 1) Allow anonymous (pre-login) reading of churches/services/classes
--    so the signup page can show selection lists and resolve invite links.
--    (Structure names only — children & profiles remain fully protected.)
-- 2) Request visibility is already scoped by the existing profiles_select
--    policy:
--      pending profile with NO church  -> visible to owner only
--      with church                     -> owner + that church's manager
--      with church + service           -> + that service's manager
-- =====================================================================

create policy churches_select_anon on public.churches
  for select to anon using (true);

create policy services_select_anon on public.services
  for select to anon using (true);

create policy classes_select_anon on public.classes
  for select to anon using (true);
