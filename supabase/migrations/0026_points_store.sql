-- =====================================================================
-- 0026: POINTS STORE MODULE — إستبدال النقاط (POS: spend points on items)
--
-- A small point-of-sale for the children's points:
--
--   1. INVENTORY  (store_items)  — every item has a code (= QR label),
--      name, picture, price in points, stock (available count), active
--      flag. Scoped church → service → class (null = all) exactly like
--      causes / events: an item applies to a child when its scope covers
--      the child's enrollment.
--   2. POS        (store_checkout RPC) — the servant scans / searches a
--      child, opens a basket, scans / picks items with quantities; the
--      DB re-checks EVERYTHING inside one transaction: module granted,
--      enrollment visible to the caller, items active + in scope,
--      stock, and total ≤ the child's balance. Then it writes the bill
--      (store_orders + store_order_items), decrements stock and inserts
--      ONE points_log row (delta = −total) → the existing trigger updates
--      enrollments.points, so the balance, the children page badges and
--      the child portal all see the redemption instantly.
--   3. ARCHIVE    (store_orders) — every bill with its lines, the
--      balance before / after and who sold. Managers (owner / church /
--      service) can CANCEL a bill (store_cancel_order): the points are
--      refunded through a +delta points_log row and stock is restored.
--   4. CHILD PORTAL — child_portal_points gets a new source 'store'
--      (reason «إستبدال نقاط», order_id) and child_portal_store_orders
--      returns the child's bills with their lines.
--
-- Idempotent — safe to re-run. Depends on 0019 (my_scope / is_owner /
-- enrollment_visible / scope_overlaps / scope_contains), 0021 (child
-- portal), 0022 (points_log.event_id) and 0024 (module_visible).
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. TABLE: store_items (المخزون)
-- ---------------------------------------------------------------------
create table if not exists public.store_items (
  id          uuid primary key default gen_random_uuid(),
  church_id   uuid not null references public.churches(id) on delete cascade,
  service_id  uuid references public.services(id) on delete cascade,   -- null = all services
  class_id    uuid references public.classes(id)  on delete cascade,   -- null = all classes
  code        text not null,                                            -- printed as the QR label
  name        text not null,
  description text,
  image_url   text,
  price       integer not null default 1 check (price >= 0),            -- in points
  stock       integer not null default 0 check (stock >= 0),            -- available count
  is_active   boolean not null default true,
  sort_order  integer not null default 0,
  created_at  timestamptz not null default now(),
  created_by  uuid references public.profiles(id),
  edited_at   timestamptz not null default now(),
  edited_by   uuid references public.profiles(id),
  constraint store_items_code_not_blank check (length(trim(code)) > 0),
  constraint store_items_scope_chain check (not (class_id is not null and service_id is null))
);

comment on table public.store_items is
  'إستبدال النقاط — أصناف المخزون: كود (QR) · اسم · صورة · السعر بالنقاط · الكمية المتاحة';

-- one code per church
create unique index if not exists uq_store_items_church_code
  on public.store_items (church_id, lower(trim(code)));
create index if not exists idx_store_items_church  on public.store_items(church_id);
create index if not exists idx_store_items_service on public.store_items(service_id);
create index if not exists idx_store_items_class   on public.store_items(class_id);
create index if not exists idx_store_items_active  on public.store_items(church_id, is_active);

drop trigger if exists trg_store_items_touch on public.store_items;
create trigger trg_store_items_touch before update on public.store_items
for each row execute function public.touch_edited();

-- the service must belong to the church, the class to the service
create or replace function public.check_store_item_scope()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.code := trim(new.code);
  if new.service_id is not null and not exists (
    select 1 from public.services s where s.id = new.service_id and s.church_id = new.church_id
  ) then
    raise exception 'service does not belong to the church';
  end if;
  if new.class_id is not null and not exists (
    select 1 from public.classes c
     where c.id = new.class_id and c.service_id = new.service_id and c.church_id = new.church_id
  ) then
    raise exception 'class does not belong to the service';
  end if;
  return new;
end $$;

drop trigger if exists trg_store_item_scope on public.store_items;
create trigger trg_store_item_scope before insert or update on public.store_items
for each row execute function public.check_store_item_scope();

-- ---------------------------------------------------------------------
-- 2. TABLES: store_orders (الفاتورة) + store_order_items (بنود الفاتورة)
-- ---------------------------------------------------------------------
create table if not exists public.store_orders (
  id                   uuid primary key default gen_random_uuid(),
  enrollment_id        uuid not null references public.enrollments(id) on delete cascade,
  person_id            uuid not null references public.persons(id)     on delete cascade,
  -- denormalized scope (from the enrollment) for cheap RLS + realtime filters
  church_id            uuid not null references public.churches(id) on delete cascade,
  service_id           uuid not null references public.services(id) on delete cascade,
  class_id             uuid not null references public.classes(id)  on delete cascade,
  status               text not null default 'completed' check (status in ('completed', 'cancelled')),
  items_count          integer not null default 0,            -- sum of quantities
  total_points         integer not null default 0 check (total_points >= 0),
  balance_before       integer not null default 0,
  balance_after        integer not null default 0,
  note                 text,
  points_log_id        uuid references public.points_log(id) on delete set null,   -- the −total row
  refund_points_log_id uuid references public.points_log(id) on delete set null,   -- the +total row (cancel)
  recorded_by          uuid references public.profiles(id),
  created_at           timestamptz not null default now(),
  cancelled_by         uuid references public.profiles(id),
  cancelled_at         timestamptz
);

comment on table public.store_orders is
  'إستبدال النقاط — أرشيف الفواتير: كل عملية شراء بالنقاط مع الرصيد قبل وبعد';

create index if not exists idx_store_orders_enrollment on public.store_orders(enrollment_id, created_at desc);
create index if not exists idx_store_orders_person     on public.store_orders(person_id, created_at desc);
create index if not exists idx_store_orders_created    on public.store_orders(created_at desc);
create index if not exists idx_store_orders_church     on public.store_orders(church_id);
create index if not exists idx_store_orders_service    on public.store_orders(service_id);
create index if not exists idx_store_orders_class      on public.store_orders(class_id);
create index if not exists idx_store_orders_points_log on public.store_orders(points_log_id);

create table if not exists public.store_order_items (
  id          uuid primary key default gen_random_uuid(),
  order_id    uuid not null references public.store_orders(id) on delete cascade,
  item_id     uuid references public.store_items(id) on delete set null,
  -- snapshot at sale time (the item may be renamed / deleted later)
  item_code   text not null,
  item_name   text not null,
  image_url   text,
  unit_price  integer not null check (unit_price >= 0),
  qty         integer not null check (qty > 0),
  line_total  integer not null check (line_total >= 0)
);

create index if not exists idx_store_order_items_order on public.store_order_items(order_id);
create index if not exists idx_store_order_items_item  on public.store_order_items(item_id);

-- ---------------------------------------------------------------------
-- 3. RLS — everything requires module_visible('store')
--    store_items : read via scope_overlaps, write via scope_contains
--    store_orders / store_order_items : read rows of enrollments I can see;
--    NO insert / update / delete policies — writes go through the RPCs
--    (security definer) which re-validate every rule.
-- ---------------------------------------------------------------------
alter table public.store_items       enable row level security;
alter table public.store_orders      enable row level security;
alter table public.store_order_items enable row level security;

drop policy if exists store_items_select on public.store_items;
create policy store_items_select on public.store_items for select using (
  (select public.module_visible('store'))
  and (select public.scope_overlaps(church_id, service_id, class_id))
);
drop policy if exists store_items_insert on public.store_items;
create policy store_items_insert on public.store_items for insert with check (
  (select public.module_visible('store'))
  and (select public.scope_contains(church_id, service_id, class_id))
);
drop policy if exists store_items_update on public.store_items;
create policy store_items_update on public.store_items for update using (
  (select public.module_visible('store'))
  and (select public.scope_contains(church_id, service_id, class_id))
) with check (
  (select public.module_visible('store'))
  and (select public.scope_contains(church_id, service_id, class_id))
);
drop policy if exists store_items_delete on public.store_items;
create policy store_items_delete on public.store_items for delete using (
  (select public.module_visible('store'))
  and (select public.scope_contains(church_id, service_id, class_id))
);

drop policy if exists store_orders_select on public.store_orders;
create policy store_orders_select on public.store_orders for select using (
  (select public.module_visible('store'))
  and public.enrollment_visible(church_id, service_id, class_id,
    (select role from public.my_scope()), (select church_id from public.my_scope()),
    (select service_id from public.my_scope()), (select class_id from public.my_scope()))
);

drop policy if exists store_order_items_select on public.store_order_items;
create policy store_order_items_select on public.store_order_items for select using (
  exists (
    select 1 from public.store_orders o
     where o.id = store_order_items.order_id
       and (select public.module_visible('store'))
       and public.enrollment_visible(o.church_id, o.service_id, o.class_id,
         (select role from public.my_scope()), (select church_id from public.my_scope()),
         (select service_id from public.my_scope()), (select class_id from public.my_scope()))
  )
);

-- ---------------------------------------------------------------------
-- 4. RPC: store_checkout — the whole sale in ONE transaction
--    p_lines = [{ "item_id": uuid, "qty": int }, ...]
--    Returns { order_id, total_points, items_count, balance_before, balance_after }
-- ---------------------------------------------------------------------
create or replace function public.store_checkout(
  p_enrollment uuid, p_lines jsonb, p_note text default null)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  s        record;                 -- caller scope
  e        public.enrollments;
  it       public.store_items;
  ln       record;
  v_order  uuid;
  v_total  integer := 0;
  v_count  integer := 0;
  v_before integer;
  v_after  integer;
  v_pl     uuid;
begin
  if auth.uid() is null then
    raise exception 'forbidden' using errcode = 'P0001';
  end if;
  if not public.module_visible('store') then
    raise exception 'module_not_visible' using errcode = 'P0001';
  end if;
  select * into s from public.my_scope();
  if not found then
    raise exception 'forbidden' using errcode = 'P0001';
  end if;

  -- lock the enrollment row: two cashiers can't overspend the same balance
  select * into e from public.enrollments where id = p_enrollment for update;
  if not found then
    raise exception 'enrollment_not_found' using errcode = 'P0002';
  end if;
  if not public.enrollment_visible(e.church_id, e.service_id, e.class_id,
                                   s.role, s.church_id, s.service_id, s.class_id) then
    raise exception 'forbidden' using errcode = 'P0001';
  end if;

  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'empty_basket' using errcode = 'P0001';
  end if;

  v_before := e.points;

  insert into public.store_orders (
    enrollment_id, person_id, church_id, service_id, class_id,
    balance_before, balance_after, note, recorded_by)
  values (e.id, e.person_id, e.church_id, e.service_id, e.class_id,
          v_before, v_before, nullif(trim(coalesce(p_note, '')), ''), auth.uid())
  returning id into v_order;

  -- merge duplicate lines of the same item, then process each one
  for ln in
    select (x->>'item_id')::uuid as item_id, sum((x->>'qty')::int) as qty
      from jsonb_array_elements(p_lines) x
     group by 1
  loop
    if ln.item_id is null or ln.qty is null or ln.qty <= 0 then
      raise exception 'invalid_line' using errcode = 'P0001';
    end if;

    -- lock the item row so stock can't go negative under concurrency
    select * into it from public.store_items where id = ln.item_id for update;
    if not found then
      raise exception 'item_not_found' using errcode = 'P0002';
    end if;
    if not it.is_active then
      raise exception 'item_inactive:%', it.name using errcode = 'P0001';
    end if;
    -- the item must apply to the child's scope
    if not (it.church_id = e.church_id
            and (it.service_id is null or it.service_id = e.service_id)
            and (it.class_id   is null or it.class_id   = e.class_id)) then
      raise exception 'item_out_of_scope:%', it.name using errcode = 'P0001';
    end if;
    if it.stock < ln.qty then
      raise exception 'insufficient_stock:%', it.name using errcode = 'P0001';
    end if;

    update public.store_items set stock = stock - ln.qty where id = it.id;

    insert into public.store_order_items (
      order_id, item_id, item_code, item_name, image_url, unit_price, qty, line_total)
    values (v_order, it.id, it.code, it.name, it.image_url, it.price, ln.qty, it.price * ln.qty);

    v_total := v_total + it.price * ln.qty;
    v_count := v_count + ln.qty;
  end loop;

  if v_total > v_before then
    raise exception 'insufficient_points' using errcode = 'P0001';
  end if;

  -- the redemption itself: ONE points_log row (trigger updates the balance)
  if v_total > 0 then
    insert into public.points_log (enrollment_id, cause_id, event_id, delta, recorded_by)
    values (e.id, null, null, -v_total, auth.uid())
    returning id into v_pl;
  end if;

  select points into v_after from public.enrollments where id = e.id;

  update public.store_orders
     set items_count = v_count, total_points = v_total,
         balance_after = v_after, points_log_id = v_pl
   where id = v_order;

  return jsonb_build_object(
    'order_id', v_order, 'total_points', v_total, 'items_count', v_count,
    'balance_before', v_before, 'balance_after', v_after);
end $$;

grant execute on function public.store_checkout(uuid, jsonb, text) to authenticated;

-- ---------------------------------------------------------------------
-- 5. RPC: store_cancel_order — managers void a bill: refund + restock
-- ---------------------------------------------------------------------
create or replace function public.store_cancel_order(p_order uuid, p_note text default null)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  s     record;
  o     public.store_orders;
  li    record;
  v_pl  uuid;
  v_after integer;
begin
  if auth.uid() is null then
    raise exception 'forbidden' using errcode = 'P0001';
  end if;
  if not public.module_visible('store') then
    raise exception 'module_not_visible' using errcode = 'P0001';
  end if;
  select * into s from public.my_scope();
  if not found or s.role not in ('owner', 'church_manager', 'service_manager') then
    raise exception 'forbidden' using errcode = 'P0001';
  end if;

  select * into o from public.store_orders where id = p_order for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if not public.enrollment_visible(o.church_id, o.service_id, o.class_id,
                                   s.role, s.church_id, s.service_id, s.class_id) then
    raise exception 'forbidden' using errcode = 'P0001';
  end if;
  if o.status <> 'completed' then
    raise exception 'not_completed' using errcode = 'P0001';
  end if;

  -- restock (items that were deleted since are skipped)
  for li in select item_id, qty from public.store_order_items where order_id = o.id loop
    if li.item_id is not null then
      update public.store_items set stock = stock + li.qty where id = li.item_id;
    end if;
  end loop;

  -- refund
  if o.total_points > 0 then
    insert into public.points_log (enrollment_id, cause_id, event_id, delta, recorded_by)
    values (o.enrollment_id, null, null, o.total_points, auth.uid())
    returning id into v_pl;
  end if;

  select points into v_after from public.enrollments where id = o.enrollment_id;

  update public.store_orders
     set status = 'cancelled', cancelled_by = auth.uid(), cancelled_at = now(),
         refund_points_log_id = v_pl,
         note = case when nullif(trim(coalesce(p_note, '')), '') is null then note
                     else concat_ws(' · ', note, trim(p_note)) end
   where id = o.id;

  return jsonb_build_object('order_id', o.id, 'refunded', o.total_points, 'balance_after', v_after);
end $$;

grant execute on function public.store_cancel_order(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- 6. RPC: store_lookup_item — resolve a scanned item code (QR label)
--    (RLS-scoped: security invoker; the code is unique per church, so a
--    servant of several churches may get several rows — the UI narrows
--    them to the child's church)
-- ---------------------------------------------------------------------
create or replace function public.store_lookup_item(p_code text)
returns setof public.store_items
language sql stable security invoker set search_path = public as $$
  select * from public.store_items
   where lower(trim(code)) = lower(trim(p_code))
   order by created_at
$$;

grant execute on function public.store_lookup_item(text) to authenticated;

-- ---------------------------------------------------------------------
-- 7. CHILD PORTAL — points list learns the 'store' source + order_id,
--    and a new RPC returns the child's bills with their lines
-- ---------------------------------------------------------------------
drop function if exists public.child_portal_points(text);
create or replace function public.child_portal_points(p_national_id text)
returns table (
  id uuid, enrollment_id uuid, source text, reason text,
  delta integer, created_at timestamptz, recorded_by_name text,
  class_name text, service_name text, church_name text,
  event_name text, order_id uuid
) language plpgsql stable security definer set search_path = public as $$
declare
  p public.persons;
begin
  p := public.child_portal_person(p_national_id);
  return query
    select x.id, x.enrollment_id, x.source, x.reason, x.delta, x.created_at,
           pr.full_name, cl.name, sv.name, ch.name, x.event_name, x.order_id
      from (
        select pl.id, pl.enrollment_id,
               case when so.id is not null or sr.id is not null then 'store'::text else 'cause'::text end as source,
               case when so.id is not null then 'إستبدال نقاط — ' || so.items_count || ' صنف'
                    when sr.id is not null then 'إلغاء عملية إستبدال — استرداد النقاط'
                    else ca.name end as reason,
               pl.delta, pl.created_at, pl.recorded_by,
               ev.name as event_name,
               coalesce(so.id, sr.id) as order_id
          from public.points_log pl
          join public.enrollments e on e.id = pl.enrollment_id
          left join public.causes ca on ca.id = pl.cause_id
          left join public.events ev on ev.id = pl.event_id
          left join public.store_orders so on so.points_log_id = pl.id
          left join public.store_orders sr on sr.refund_points_log_id = pl.id
         where e.person_id = p.id
        union all
        select a.id, a.enrollment_id, 'attendance'::text,
               ev.name, a.points_delta, a.created_at, a.recorded_by,
               ev.name, null::uuid
          from public.attendance_log a
          join public.enrollments e on e.id = a.enrollment_id
          left join public.events ev on ev.id = a.event_id
         where e.person_id = p.id and a.points_delta <> 0
      ) x
      join public.enrollments e2 on e2.id = x.enrollment_id
      left join public.profiles pr on pr.id = x.recorded_by
      join public.classes  cl on cl.id = e2.class_id
      join public.services sv on sv.id = e2.service_id
      join public.churches ch on ch.id = e2.church_id
     order by x.created_at desc;
end $$;
grant execute on function public.child_portal_points(text) to anon, authenticated;

-- the child's bills (with lines) — newest first
create or replace function public.child_portal_store_orders(p_national_id text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  p public.persons;
  res jsonb;
begin
  p := public.child_portal_person(p_national_id);
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', o.id,
           'enrollment_id', o.enrollment_id,
           'status', o.status,
           'items_count', o.items_count,
           'total_points', o.total_points,
           'balance_before', o.balance_before,
           'balance_after', o.balance_after,
           'created_at', o.created_at,
           'cancelled_at', o.cancelled_at,
           'recorded_by_name', pr.full_name,
           'class_name', cl.name,
           'service_name', sv.name,
           'church_name', ch.name,
           'items', (
             select coalesce(jsonb_agg(jsonb_build_object(
                      'id', li.id, 'item_name', li.item_name, 'item_code', li.item_code,
                      'image_url', li.image_url, 'unit_price', li.unit_price,
                      'qty', li.qty, 'line_total', li.line_total) order by li.item_name), '[]'::jsonb)
               from public.store_order_items li where li.order_id = o.id)
         ) order by o.created_at desc), '[]'::jsonb)
    into res
    from public.store_orders o
    join public.enrollments e on e.id = o.enrollment_id
    left join public.profiles pr on pr.id = o.recorded_by
    join public.classes  cl on cl.id = o.class_id
    join public.services sv on sv.id = o.service_id
    join public.churches ch on ch.id = o.church_id
   where e.person_id = p.id;
  return res;
end $$;
grant execute on function public.child_portal_store_orders(text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 8. REALTIME — inventory & archive update live on every screen
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'store_items'
  ) then
    alter publication supabase_realtime add table public.store_items;
  end if;
  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'store_orders'
  ) then
    alter publication supabase_realtime add table public.store_orders;
  end if;
end $$;
alter table public.store_items  replica identity full;
alter table public.store_orders replica identity full;

analyze public.store_items;
analyze public.store_orders;
analyze public.store_order_items;

commit;
