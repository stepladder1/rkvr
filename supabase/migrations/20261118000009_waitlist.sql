-- "Notify me" for coming-soon spas: saves the email so HQ can tell people when a spa opens.

create table if not exists public.spa_waitlist (
  id         uuid primary key default gen_random_uuid(),
  spa_id     uuid not null references public.spas (id) on delete cascade,
  email      text not null check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  client_id  uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  notified_at timestamptz
);
create unique index if not exists spa_waitlist_once on public.spa_waitlist (spa_id, lower(email));

alter table public.spa_waitlist enable row level security;
drop policy if exists "waitlist staff read" on public.spa_waitlist;
create policy "waitlist staff read" on public.spa_waitlist for select using (public.is_hq() or public.is_my_spa(spa_id));
drop policy if exists "waitlist hq manage" on public.spa_waitlist;
create policy "waitlist hq manage" on public.spa_waitlist for all using (public.is_hq()) with check (public.is_hq());
grant select, insert, update, delete on public.spa_waitlist to authenticated;
grant all on public.spa_waitlist to service_role;

-- Anyone (signed in or not) can add an email; nobody but staff can read the list
create or replace function public.join_waitlist(spa_slug text, email text) returns void
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare sid uuid; e text := lower(trim(join_waitlist.email));
begin
  select id into sid from public.spas where slug = spa_slug and status <> 'closed';
  if sid is null then raise exception 'Unknown spa'; end if;
  if e !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' or length(e) > 254 then raise exception 'Enter a valid email address'; end if;
  insert into public.spa_waitlist (spa_id, email, client_id) values (sid, e, auth.uid())
  on conflict (spa_id, lower(email)) do nothing;
end;
$$;
grant execute on function public.join_waitlist(text, text) to anon, authenticated;
