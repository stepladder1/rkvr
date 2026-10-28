-- Storage for the RKVR HQ dashboard's own state: feature switches, settings,
-- paused spas, hidden products, recommendation history, request replies, the
-- change log and sent campaigns. Only HQ staff can read or write it.
-- Switches and settings are also copied into feature_flags and settings,
-- which the apps read.

create table if not exists public.hq_docs (
  path       text primary key,                 -- e.g. 'config/features'
  data       jsonb not null default '{}'::jsonb,
  updated_by uuid references public.profiles (id) on delete set null,
  updated_at timestamptz not null default now()
);

create table if not exists public.hq_items (
  id         uuid primary key default gen_random_uuid(),
  collection text not null,                    -- e.g. 'campaigns'
  data       jsonb not null,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists hq_items_collection_time on public.hq_items (collection, created_at desc);

alter table public.hq_docs  enable row level security;
alter table public.hq_items enable row level security;

drop policy if exists "hq docs" on public.hq_docs;
drop policy if exists "hq items" on public.hq_items;
create policy "hq docs"  on public.hq_docs  for all using (public.is_hq()) with check (public.is_hq());
create policy "hq items" on public.hq_items for all using (public.is_hq()) with check (public.is_hq());

grant select, insert, update, delete on public.hq_docs, public.hq_items to authenticated;
grant all on public.hq_docs, public.hq_items to service_role;
