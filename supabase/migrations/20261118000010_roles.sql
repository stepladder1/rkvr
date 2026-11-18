-- Two HQ roles.
--   super_admin: every location, all Controls, Stripe, live data and permissions (was hq_admin).
--   hq_admin   : "HQ Staff", only the locations a Super Admin assigns them (hq_staff_spas).
-- Operators are unchanged. is_hq() now means Super Admin, so every existing HQ-only rule
-- (settings, flags, prices, team, roles) becomes Super Admin only.

alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check check (role in ('client', 'operator', 'hq_admin', 'super_admin'));

create table if not exists public.hq_staff_spas (
  profile_id uuid not null references public.profiles (id) on delete cascade,
  spa_id     uuid not null references public.spas (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (profile_id, spa_id)
);

create or replace function public.is_super() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'super_admin');
$$;
create or replace function public.is_hq() returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_super();
$$;
create or replace function public.is_hq_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role in ('super_admin', 'hq_admin'));
$$;

-- "My spas": the ones I operate, plus (for HQ Staff) the ones I'm assigned
create or replace function public.my_spa_ids() returns setof uuid
language sql stable security definer set search_path = public as $$
  select id from public.spas where operator_id = auth.uid()
  union
  select h.spa_id from public.hq_staff_spas h join public.profiles p on p.id = h.profile_id
   where h.profile_id = auth.uid() and p.role = 'hq_admin';
$$;
create or replace function public.is_my_spa(spa uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select spa in (select public.my_spa_ids());
$$;
grant execute on function public.my_spa_ids(), public.is_super(), public.is_hq_staff() to authenticated;

alter table public.hq_staff_spas enable row level security;
drop policy if exists "super manages staff spas" on public.hq_staff_spas;
create policy "super manages staff spas" on public.hq_staff_spas for all using (public.is_super()) with check (public.is_super());
drop policy if exists "staff reads own spas" on public.hq_staff_spas;
create policy "staff reads own spas" on public.hq_staff_spas for select using (profile_id = auth.uid());
grant select, insert, update, delete on public.hq_staff_spas to authenticated;
grant all on public.hq_staff_spas to service_role;

-- HQ Staff can read the dashboard's shared docs; only Super Admins change them
drop policy if exists "hq docs" on public.hq_docs;
drop policy if exists "hq docs read" on public.hq_docs;
drop policy if exists "hq docs write" on public.hq_docs;
create policy "hq docs read" on public.hq_docs for select using (public.is_hq_staff());
create policy "hq docs write" on public.hq_docs for all using (public.is_super()) with check (public.is_super());
drop policy if exists "hq items" on public.hq_items;
drop policy if exists "hq items read" on public.hq_items;
drop policy if exists "hq items write" on public.hq_items;
create policy "hq items read" on public.hq_items for select using (public.is_hq_staff());
create policy "hq items write" on public.hq_items for all using (public.is_super()) with check (public.is_super());

-- HQ Staff answer repair requests for their locations, as RKVR
drop policy if exists "hq staff replies" on public.request_messages;
create policy "hq staff replies" on public.request_messages for insert with check (
  author_id = auth.uid() and from_rkvr and public.is_hq_staff()
  and exists (select 1 from public.service_requests r where r.id = request_id and public.is_my_spa(r.spa_id)));
drop policy if exists "hq staff updates requests" on public.service_requests;
create policy "hq staff updates requests" on public.service_requests for update
  using (public.is_hq_staff() and public.is_my_spa(spa_id)) with check (public.is_hq_staff() and public.is_my_spa(spa_id));

-- Only a Super Admin changes a location's setup. Operators and HQ Staff may pause bookings and set hours.
create or replace function public.guard_spa_update() returns trigger
language plpgsql security definer set search_path = public as $$
declare paused boolean := new.bookings_paused; hrs text := new.hours;
begin
  if auth.uid() is not null and not public.is_super()
     and coalesce(current_setting('request.jwt.claims', true)::json ->> 'role', '') <> 'service_role' then
    new := old;
    new.bookings_paused := paused;
    new.hours := hrs;
  end if;
  return new;
end;
$$;
drop trigger if exists spas_guard on public.spas;
create trigger spas_guard before update on public.spas for each row execute function public.guard_spa_update();

-- Team invites can be for any of the three roles; HQ Staff get a list of locations
alter table public.team_invites drop constraint if exists team_invites_role_check;
alter table public.team_invites add constraint team_invites_role_check check (role in ('super_admin', 'hq_admin', 'operator'));
alter table public.team_invites add column if not exists spa_ids uuid[] not null default '{}';

create or replace function public.apply_team_invite(p_id uuid, p_email text) returns void
language plpgsql security definer set search_path = public as $$
declare
  inv public.team_invites;
begin
  select * into inv from public.team_invites where email = lower(p_email) and accepted_at is null;
  if not found then return; end if;
  update public.profiles set role = inv.role where id = p_id;
  if inv.role = 'operator' and inv.spa_id is not null then
    update public.spas set operator_id = p_id where id = inv.spa_id;
  end if;
  if inv.role = 'hq_admin' then
    insert into public.hq_staff_spas (profile_id, spa_id)
    select p_id, x from unnest(inv.spa_ids || case when inv.spa_id is null then '{}'::uuid[] else array[inv.spa_id] end) x
    on conflict do nothing;
  end if;
  update public.team_invites set accepted_at = now() where email = inv.email;
end;
$$;
drop trigger if exists team_invite_added on public.team_invites;
create trigger team_invite_added after insert or update of role, spa_id, spa_ids on public.team_invites
  for each row when (new.accepted_at is null) execute function public.team_invite_added();

-- Everyone who was HQ until now becomes a Super Admin
-- (only the first time: once a Super Admin exists, HQ Staff stay HQ Staff)
update public.profiles set role = 'super_admin'
 where role = 'hq_admin' and not exists (select 1 from public.profiles where role = 'super_admin');
