-- 0015: default event/cause + points mode
--
-- 1. is_default: one event & one cause can be marked as the DEFAULT so the
--    children / scanner pages preselect it automatically.
--    (The app clears other defaults when a new one is set.)
--
-- 2. points_mode: how the points amount behaves when recording:
--    'fixed'    -> the bound number cannot be changed
--    'editable' -> the bound number is the default but can be changed
--    'open'     -> no bound number; the servant enters it each time

alter table public.events
  add column if not exists is_default boolean not null default false,
  add column if not exists points_mode text not null default 'fixed';

alter table public.causes
  add column if not exists is_default boolean not null default false,
  add column if not exists points_mode text not null default 'fixed';

-- check constraints (added separately so re-runs don't fail)
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'events_points_mode_check'
  ) then
    alter table public.events
      add constraint events_points_mode_check
      check (points_mode in ('open', 'editable', 'fixed'));
  end if;

  if not exists (
    select 1 from pg_constraint where conname = 'causes_points_mode_check'
  ) then
    alter table public.causes
      add constraint causes_points_mode_check
      check (points_mode in ('open', 'editable', 'fixed'));
  end if;
end $$;

-- helpful partial indexes for the "find the default" query
create index if not exists idx_events_default on public.events (church_id) where is_default;
create index if not exists idx_causes_default on public.causes (church_id) where is_default;
