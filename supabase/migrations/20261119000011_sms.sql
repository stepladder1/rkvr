-- Text messages (Twilio): booking confirmations, day-before reminders, membership welcomes and
-- staff alerts. A scheduled Netlify function sends them; these columns mark each one as handled
-- so nobody is texted twice. Texts go only to clients who ticked "Text me reminders" (sms_opt_in).

alter table public.bookings    add column if not exists confirm_sms_at  timestamptz;
alter table public.bookings    add column if not exists staff_sms_at    timestamptz;
alter table public.bookings    add column if not exists reminder_sms_at timestamptz;
alter table public.memberships add column if not exists welcome_sms_at  timestamptz;

-- Everything that already exists counts as handled, so switching texts on doesn't send old news.
-- Upcoming visits keep their reminder.
update public.bookings    set confirm_sms_at = now() where confirm_sms_at is null;
update public.bookings    set staff_sms_at   = now() where staff_sms_at is null;
update public.bookings    set reminder_sms_at = now() where reminder_sms_at is null and starts_at < now();
update public.memberships set welcome_sms_at = now() where welcome_sms_at is null;

-- Clients can't set these markers themselves (keeps the insert policy honest)
create or replace function public.guard_sms_markers() returns trigger
language plpgsql as $$
begin
  if current_user in ('anon', 'authenticated') then
    if tg_op = 'INSERT' then
      new.confirm_sms_at := null; new.staff_sms_at := null; new.reminder_sms_at := null;
    else
      new.confirm_sms_at := old.confirm_sms_at; new.staff_sms_at := old.staff_sms_at; new.reminder_sms_at := old.reminder_sms_at;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists bookings_sms_markers on public.bookings;
create trigger bookings_sms_markers before insert or update on public.bookings
  for each row execute function public.guard_sms_markers();

-- A record of every text, for HQ
create table if not exists public.sms_log (
  id          uuid primary key default gen_random_uuid(),
  kind        text not null check (kind in ('confirm', 'reminder', 'welcome', 'staff', 'test', 'inbound')),
  spa_id      uuid references public.spas (id) on delete set null,
  profile_id  uuid references public.profiles (id) on delete set null,
  booking_id  uuid references public.bookings (id) on delete set null,
  to_phone    text,
  body        text,
  status      text not null,          -- sent, failed, skipped, stop, start
  twilio_sid  text,
  error       text,
  created_at  timestamptz not null default now()
);
create index if not exists sms_log_recent on public.sms_log (created_at desc);

alter table public.sms_log enable row level security;
drop policy if exists "sms log read" on public.sms_log;
create policy "sms log read" on public.sms_log for select
  using (public.is_hq() or (spa_id is not null and public.is_my_spa(spa_id)));
grant select on public.sms_log to authenticated;
grant all on public.sms_log to service_role;

-- STOP / START replies: Twilio tells us, we update the client's opt-in (matched on the phone's last 10 digits)
create or replace function public.sms_set_opt_in(p_phone text, p_on boolean) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if length(public.digits10(p_phone)) <> 10 then return 0; end if;
  update public.profiles set sms_opt_in = p_on where public.digits10(phone) = public.digits10(p_phone);
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.sms_set_opt_in(text, boolean) from public, anon, authenticated;
grant execute on function public.sms_set_opt_in(text, boolean) to service_role;
