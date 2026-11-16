-- Team invites from the HQ dashboard.
-- HQ adds an email with a role (HQ staff or spa operator, with a spa). When that
-- person signs in for the first time, or right away if they already have an
-- account, they get that role. No SQL needed for each new team member.

create table if not exists public.team_invites (
  email       text primary key check (email = lower(email)),
  role        text not null check (role in ('hq_admin', 'operator')),
  spa_id      uuid references public.spas (id) on delete set null,
  invited_by  uuid references public.profiles (id) on delete set null,
  created_at  timestamptz not null default now(),
  accepted_at timestamptz
);

alter table public.team_invites enable row level security;
drop policy if exists "hq team invites" on public.team_invites;
create policy "hq team invites" on public.team_invites for all using (public.is_hq()) with check (public.is_hq());
grant select, insert, update, delete on public.team_invites to authenticated;
grant all on public.team_invites to service_role;

-- Give a profile the role waiting for its email, if any
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
  update public.team_invites set accepted_at = now() where email = inv.email;
end;
$$;

-- New accounts: create the profile (as before), then apply any waiting invite
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  meta jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
begin
  insert into public.profiles (id, email, phone, full_name, sms_opt_in, home_spa_id)
  values (
    new.id,
    new.email,
    coalesce(nullif(meta ->> 'phone', ''), new.phone),
    coalesce(nullif(meta ->> 'full_name', ''), nullif(meta ->> 'name', '')),
    coalesce((meta ->> 'sms_opt_in')::boolean, false),
    (select id from public.spas where slug = meta ->> 'home_spa')
  )
  on conflict (id) do nothing;
  if new.email is not null then
    perform public.apply_team_invite(new.id, new.email);
  end if;
  return new;
end;
$$;

-- Someone who already has an account gets the role as soon as HQ adds them
create or replace function public.team_invite_added() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  pid uuid;
begin
  select id into pid from public.profiles where lower(email) = new.email limit 1;
  if pid is not null then
    perform public.apply_team_invite(pid, new.email);
  end if;
  return null;
end;
$$;
drop trigger if exists team_invite_added on public.team_invites;
create trigger team_invite_added after insert or update of role, spa_id on public.team_invites
  for each row when (new.accepted_at is null) execute function public.team_invite_added();
