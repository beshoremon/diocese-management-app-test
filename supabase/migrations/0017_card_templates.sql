-- =====================================================================
-- 0017: CARD TEMPLATES — design ID cards for the children (persons)
--
-- One row per template. The visual design + print settings are stored
-- as JSONB (schema versioned in app code: src/lib/card-types.ts).
-- Scoped to church / service / class exactly like events & causes
-- (null service/class = whole church / whole service).
-- =====================================================================

begin;

create table public.card_templates (
  id          uuid primary key default gen_random_uuid(),
  church_id   uuid not null references public.churches(id) on delete cascade,
  service_id  uuid references public.services(id) on delete cascade,
  class_id    uuid references public.classes(id) on delete cascade,
  name        text not null,
  design         jsonb not null default '{}'::jsonb,
  print_settings jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now(),
  created_by  uuid references public.profiles(id),
  edited_at   timestamptz not null default now(),
  edited_by   uuid references public.profiles(id)
);

create index idx_card_templates_church on public.card_templates(church_id);

create trigger trg_card_templates_touch before update on public.card_templates
for each row execute function public.touch_edited();

-- RLS: same scope rules as events / causes
alter table public.card_templates enable row level security;

create policy card_templates_select on public.card_templates for select using (
  public.can_access(church_id, service_id, class_id)
);
create policy card_templates_insert on public.card_templates for insert with check (
  public.can_access(church_id, service_id, class_id)
);
create policy card_templates_update on public.card_templates for update using (
  public.can_access(church_id, service_id, class_id)
) with check (
  public.can_access(church_id, service_id, class_id)
);
create policy card_templates_delete on public.card_templates for delete using (
  public.can_access(church_id, service_id, class_id)
);

commit;
