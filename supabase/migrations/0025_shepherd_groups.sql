-- =====================================================================
-- 0025: SHEPHERDS MODULE — الأشابين (servant ↔ children groups)
--
-- Every servant (الأشبين) is bound to a number of children — HIS GROUP.
-- He opens the module, picks children from his scope into his group and
-- can add / remove them at any time. A child can belong to ONE group only:
-- a child already chosen by another servant cannot be chosen again
-- (enforced by the unique index on enrollment_id, not just by the UI).
--
-- On the children page a «مجموعتي» button (below the church / service /
-- class selectors) narrows the list to the caller's group — everything
-- else (attendance, calls, points, data …) works exactly the same.
--
-- The module is optional: its table is usable only when the owner granted
-- the `shepherds` module to the caller's scope (`module_visible`, 0024).
--
--   shepherd_groups — one row = one child in one servant's group
--     servant_id    → profiles   (the أشبين)
--     enrollment_id → enrollments (the child, bound to church/service/class)
--     church_id / service_id / class_id — denormalized from the enrollment
--                     (filled by trigger) for cheap RLS + realtime filters
--
-- Idempotent — safe to re-run. Depends on 0019 (my_scope / is_owner /
-- enrollment_visible) and 0024 (module_visible).
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. TABLE: shepherd_groups
-- ---------------------------------------------------------------------
create table if not exists public.shepherd_groups (
  id            uuid primary key default gen_random_uuid(),
  servant_id    uuid not null references public.profiles(id)    on delete cascade,
  enrollment_id uuid not null references public.enrollments(id) on delete cascade,
  -- denormalized scope (copied from the enrollment by trigger)
  church_id     uuid not null references public.churches(id) on delete cascade,
  service_id    uuid not null references public.services(id) on delete cascade,
  class_id      uuid not null references public.classes(id)  on delete cascade,
  created_at    timestamptz not null default now()
);

comment on table public.shepherd_groups is
  'الأشابين — كل صف = مخدوم واحد داخل مجموعة خادم واحد (المخدوم لا يكون إلا في مجموعة واحدة)';

-- A child is in ONE group only
create unique index if not exists uq_shepherd_groups_enrollment
  on public.shepherd_groups (enrollment_id);

create index if not exists idx_shepherd_groups_servant on public.shepherd_groups(servant_id);
create index if not exists idx_shepherd_groups_church  on public.shepherd_groups(church_id);
create index if not exists idx_shepherd_groups_service on public.shepherd_groups(service_id);
create index if not exists idx_shepherd_groups_class   on public.shepherd_groups(class_id);

-- keep the denormalized scope in sync with the enrollment on insert
create or replace function public.shepherd_group_fill_scope()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  select e.church_id, e.service_id, e.class_id
    into new.church_id, new.service_id, new.class_id
  from public.enrollments e where e.id = new.enrollment_id;
  if new.church_id is null then
    raise exception 'enrollment not found';
  end if;
  return new;
end $$;

drop trigger if exists trg_shepherd_group_scope on public.shepherd_groups;
create trigger trg_shepherd_group_scope
before insert on public.shepherd_groups
for each row execute function public.shepherd_group_fill_scope();

-- ---------------------------------------------------------------------
-- 2. RLS — usable only when the module is visible to the caller
--    read : every row of an enrollment I can see (so I know which children
--           are already taken)
--    write: I add children to MY OWN group only, within my scope
--    delete: my own rows; managers (owner / church / service) may also
--           free a child from any group in their scope
-- ---------------------------------------------------------------------
alter table public.shepherd_groups enable row level security;

drop policy if exists shepherd_groups_select on public.shepherd_groups;
create policy shepherd_groups_select on public.shepherd_groups for select using (
  (select public.module_visible('shepherds'))
  and public.enrollment_visible(church_id, service_id, class_id,
    (select role from public.my_scope()), (select church_id from public.my_scope()),
    (select service_id from public.my_scope()), (select class_id from public.my_scope()))
);

drop policy if exists shepherd_groups_insert on public.shepherd_groups;
create policy shepherd_groups_insert on public.shepherd_groups for insert with check (
  (select public.module_visible('shepherds'))
  and servant_id = auth.uid()
  and exists (
    select 1 from public.enrollments e
     where e.id = enrollment_id
       and public.enrollment_visible(e.church_id, e.service_id, e.class_id,
         (select role from public.my_scope()), (select church_id from public.my_scope()),
         (select service_id from public.my_scope()), (select class_id from public.my_scope()))
  )
);

drop policy if exists shepherd_groups_delete on public.shepherd_groups;
create policy shepherd_groups_delete on public.shepherd_groups for delete using (
  (select public.module_visible('shepherds'))
  and (
    servant_id = auth.uid()
    or (
      (select role from public.my_scope()) in ('owner', 'church_manager', 'service_manager')
      and public.enrollment_visible(church_id, service_id, class_id,
        (select role from public.my_scope()), (select church_id from public.my_scope()),
        (select service_id from public.my_scope()), (select class_id from public.my_scope()))
    )
  )
);

-- ---------------------------------------------------------------------
-- 3. RPC: shepherd_claims — who holds each child I can see?
--    A class servant cannot read other servants' profiles through RLS,
--    yet the picker must say «في مجموعة فلان». SECURITY DEFINER, but it
--    only returns claims of enrollments VISIBLE to the caller and only
--    when the module is granted to him. Optional scope narrowing.
-- ---------------------------------------------------------------------
create or replace function public.shepherd_claims(
  p_church uuid default null, p_service uuid default null, p_class uuid default null)
returns table (
  enrollment_id uuid,
  servant_id    uuid,
  servant_name  text,
  servant_photo text,
  created_at    timestamptz
)
language sql stable security definer set search_path = public as $$
  select g.enrollment_id, g.servant_id, p.full_name, p.photo_url, g.created_at
    from public.shepherd_groups g
    join public.profiles p on p.id = g.servant_id
   where (select public.module_visible('shepherds'))
     and public.enrollment_visible(g.church_id, g.service_id, g.class_id,
       (select role from public.my_scope()), (select church_id from public.my_scope()),
       (select service_id from public.my_scope()), (select class_id from public.my_scope()))
     and (p_church  is null or g.church_id  = p_church)
     and (p_service is null or g.service_id = p_service)
     and (p_class   is null or g.class_id   = p_class)
$$;

grant execute on function public.shepherd_claims(uuid, uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 4. RPC: shepherd_group_summary — per-servant group sizes in my scope
--    (managers' overview; a servant sees at least his own row)
-- ---------------------------------------------------------------------
create or replace function public.shepherd_group_summary(
  p_church uuid default null, p_service uuid default null, p_class uuid default null)
returns table (
  servant_id    uuid,
  servant_name  text,
  servant_photo text,
  children      bigint
)
language sql stable security definer set search_path = public as $$
  select g.servant_id, p.full_name, p.photo_url, count(*)::bigint
    from public.shepherd_groups g
    join public.profiles p on p.id = g.servant_id
   where (select public.module_visible('shepherds'))
     and public.enrollment_visible(g.church_id, g.service_id, g.class_id,
       (select role from public.my_scope()), (select church_id from public.my_scope()),
       (select service_id from public.my_scope()), (select class_id from public.my_scope()))
     and (p_church  is null or g.church_id  = p_church)
     and (p_service is null or g.service_id = p_service)
     and (p_class   is null or g.class_id   = p_class)
   group by g.servant_id, p.full_name, p.photo_url
   order by count(*) desc, p.full_name
$$;

grant execute on function public.shepherd_group_summary(uuid, uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 5. REALTIME — the picker / children page react the moment a child is
--    claimed or released by anyone
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'shepherd_groups'
  ) then
    alter publication supabase_realtime add table public.shepherd_groups;
  end if;
end $$;
alter table public.shepherd_groups replica identity full;

commit;
