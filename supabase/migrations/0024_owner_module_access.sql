-- =====================================================================
-- 0024: OWNER MODULE — MODULE ACCESS CONTROL (وحدة المالك — صلاحيات الوحدات)
--
-- The app is made of a fixed core (الرئيسية · المخدومين · الماسح ·
-- الإحصائيات · الإعدادات) plus optional MODULES (الوحدات) — today only the
-- card designer / print module (`cards`). Modules are defined in app code
-- (`src/lib/modules.ts`); this migration adds the OWNER-controlled table
-- that decides WHO can see each module.
--
--   module_access — one row = one GRANT of a module to a scope:
--     church_id  null  → every church (the module is available to everyone)
--     service_id null  → all services of that church
--     class_id   null  → all classes of that (church, service)
--
-- A servant sees a module when at least one grant OVERLAPS his scope (same
-- `scope_overlaps` semantics used by events / causes / call feedbacks). The
-- OWNER always sees every module and is the ONLY one who can write grants.
--
-- The card tables (`card_templates`, `card_print_requests`) additionally
-- require `module_visible('cards')` in their RLS, so hiding the module in
-- the UI is backed by the database.
--
-- Seeds one global grant for `cards` so the current behaviour (everybody
-- sees the card module) is preserved until the owner restricts it.
--
-- Idempotent — safe to re-run. Depends on 0019 (my_scope / is_owner /
-- scope_overlaps / can_access / enrollment_visible) and 0017 / 0018.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. TABLE: module_access
-- ---------------------------------------------------------------------
create table if not exists public.module_access (
  id          uuid primary key default gen_random_uuid(),
  module_key  text not null,                                             -- app-code key (e.g. 'cards')
  church_id   uuid references public.churches(id) on delete cascade,    -- null = all churches
  service_id  uuid references public.services(id) on delete cascade,    -- null = all services
  class_id    uuid references public.classes(id)  on delete cascade,    -- null = all classes
  created_at  timestamptz not null default now(),
  created_by  uuid references public.profiles(id),
  constraint module_access_key_len check (module_key ~ '^[a-z][a-z0-9_]{1,40}$'),
  -- a service needs its church, a class needs its service
  constraint module_access_scope_chain check (
    (service_id is null or church_id is not null)
    and (class_id is null or service_id is not null)
  )
);

-- No duplicate grants for the exact same scope (nulls treated as equal)
create unique index if not exists uq_module_access_scope
  on public.module_access (
    module_key,
    coalesce(church_id,  '00000000-0000-0000-0000-000000000000'::uuid),
    coalesce(service_id, '00000000-0000-0000-0000-000000000000'::uuid),
    coalesce(class_id,   '00000000-0000-0000-0000-000000000000'::uuid)
  );

create index if not exists idx_module_access_key    on public.module_access(module_key);
create index if not exists idx_module_access_church on public.module_access(church_id);

-- The service / class must belong to the given church / service
create or replace function public.check_module_access_scope()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.service_id is not null then
    if not exists (
      select 1 from public.services s where s.id = new.service_id and s.church_id = new.church_id
    ) then
      raise exception 'service does not belong to the church';
    end if;
  end if;
  if new.class_id is not null then
    if not exists (
      select 1 from public.classes c
       where c.id = new.class_id and c.service_id = new.service_id and c.church_id = new.church_id
    ) then
      raise exception 'class does not belong to the service';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists trg_module_access_scope on public.module_access;
create trigger trg_module_access_scope before insert or update on public.module_access
for each row execute function public.check_module_access_scope();

-- ---------------------------------------------------------------------
-- 2. HELPER: module_visible(key) — can the caller see this module?
-- ---------------------------------------------------------------------
create or replace function public.module_visible(p_key text)
returns boolean language sql stable security definer set search_path = public as $$
  select (select public.is_owner())
      or exists (
           select 1 from public.module_access m
            where m.module_key = p_key
              and (m.church_id is null
                   or public.scope_overlaps(m.church_id, m.service_id, m.class_id))
         )
$$;

grant execute on function public.module_visible(text) to authenticated;

-- ---------------------------------------------------------------------
-- 3. RLS — everyone reads the grants that concern him (so the UI knows
--    which modules to show); only the OWNER writes.
-- ---------------------------------------------------------------------
alter table public.module_access enable row level security;

drop policy if exists module_access_select on public.module_access;
create policy module_access_select on public.module_access for select using (
  (select public.is_owner())
  or church_id is null
  or (select public.scope_overlaps(church_id, service_id, class_id))
);
drop policy if exists module_access_insert on public.module_access;
create policy module_access_insert on public.module_access for insert with check (
  (select public.is_owner())
);
drop policy if exists module_access_update on public.module_access;
create policy module_access_update on public.module_access for update using (
  (select public.is_owner())
) with check (
  (select public.is_owner())
);
drop policy if exists module_access_delete on public.module_access;
create policy module_access_delete on public.module_access for delete using (
  (select public.is_owner())
);

-- ---------------------------------------------------------------------
-- 4. CARD MODULE — its tables are only usable when the module is visible
-- ---------------------------------------------------------------------
drop policy if exists card_templates_select on public.card_templates;
create policy card_templates_select on public.card_templates for select using (
  (select public.module_visible('cards'))
  and (select public.can_access(church_id, service_id, class_id))
);
drop policy if exists card_templates_insert on public.card_templates;
create policy card_templates_insert on public.card_templates for insert with check (
  (select public.module_visible('cards'))
  and (select public.can_access(church_id, service_id, class_id))
);
drop policy if exists card_templates_update on public.card_templates;
create policy card_templates_update on public.card_templates for update using (
  (select public.module_visible('cards'))
  and (select public.can_access(church_id, service_id, class_id))
) with check (
  (select public.module_visible('cards'))
  and (select public.can_access(church_id, service_id, class_id))
);
drop policy if exists card_templates_delete on public.card_templates;
create policy card_templates_delete on public.card_templates for delete using (
  (select public.module_visible('cards'))
  and (select public.can_access(church_id, service_id, class_id))
);

drop policy if exists card_print_requests_select on public.card_print_requests;
create policy card_print_requests_select on public.card_print_requests for select using (
  (select public.module_visible('cards'))
  and public.enrollment_visible(church_id, service_id, class_id,
    (select role from public.my_scope()), (select church_id from public.my_scope()),
    (select service_id from public.my_scope()), (select class_id from public.my_scope()))
);
drop policy if exists card_print_requests_insert on public.card_print_requests;
create policy card_print_requests_insert on public.card_print_requests for insert with check (
  (select public.module_visible('cards'))
  and exists (
    select 1 from public.enrollments e
    where e.id = enrollment_id
      and public.can_access(e.church_id, e.service_id, e.class_id)
  )
);
drop policy if exists card_print_requests_delete on public.card_print_requests;
create policy card_print_requests_delete on public.card_print_requests for delete using (
  (select public.module_visible('cards'))
  and public.enrollment_visible(church_id, service_id, class_id,
    (select role from public.my_scope()), (select church_id from public.my_scope()),
    (select service_id from public.my_scope()), (select class_id from public.my_scope()))
);

-- ---------------------------------------------------------------------
-- 5. SEED — keep today's behaviour: the card module is open to everyone
--    until the owner restricts it from وحدة المالك → صلاحيات الوحدات.
-- ---------------------------------------------------------------------
insert into public.module_access (module_key, church_id, service_id, class_id)
select 'cards', null, null, null
where not exists (select 1 from public.module_access where module_key = 'cards');

-- ---------------------------------------------------------------------
-- 6. REALTIME — menus / settings update the moment the owner changes a grant
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'module_access'
  ) then
    alter publication supabase_realtime add table public.module_access;
  end if;
end $$;
alter table public.module_access replica identity full;

commit;
