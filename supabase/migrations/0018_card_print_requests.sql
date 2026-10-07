-- =====================================================================
-- 0018: CARD PRINT REQUESTS — "طباعة كارت" job on the children page
--
-- A servant taps the print-card button on a child → a request row is
-- created here. The print page (تصميم الكروت → الطباعة) can then print
-- from the requested list and delete one / a group / all of them.
--
-- One PENDING request per enrollment (unique) → inserting a duplicate
-- fails with 23505 and the app tells the user it's already requested.
-- =====================================================================

begin;

create table public.card_print_requests (
  id            uuid primary key default gen_random_uuid(),
  enrollment_id uuid not null references public.enrollments(id) on delete cascade,
  -- denormalized scope (copied from the enrollment) so the print page can
  -- filter by church / service / class without joins in RLS
  church_id     uuid not null references public.churches(id) on delete cascade,
  service_id    uuid not null references public.services(id) on delete cascade,
  class_id      uuid not null references public.classes(id) on delete cascade,
  requested_by  uuid references public.profiles(id),
  created_at    timestamptz not null default now(),
  unique (enrollment_id)
);

create index idx_card_print_requests_church  on public.card_print_requests(church_id);
create index idx_card_print_requests_service on public.card_print_requests(service_id);
create index idx_card_print_requests_class   on public.card_print_requests(class_id);

comment on table public.card_print_requests is
  'طلبات طباعة الكروت — يرسلها الخادم من صفحة المخدومين وتُطبع من صفحة الطباعة';

-- keep the denormalized scope in sync with the enrollment on insert
create or replace function public.card_print_request_fill_scope()
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

create trigger trg_card_print_request_scope
before insert on public.card_print_requests
for each row execute function public.card_print_request_fill_scope();

-- RLS: same scope rules as everything else
alter table public.card_print_requests enable row level security;

create policy card_print_requests_select on public.card_print_requests for select using (
  public.can_access(church_id, service_id, class_id)
);
create policy card_print_requests_insert on public.card_print_requests for insert with check (
  exists (
    select 1 from public.enrollments e
    where e.id = enrollment_id
      and public.can_access(e.church_id, e.service_id, e.class_id)
  )
);
create policy card_print_requests_delete on public.card_print_requests for delete using (
  public.can_access(church_id, service_id, class_id)
);

-- realtime so the requested list updates live on the print page
alter publication supabase_realtime add table public.card_print_requests;

commit;
