-- Client sign-up and booking support for the website and client app.

-- 1. New accounts: copy the details given at sign-up (name, mobile, text opt-in,
--    home spa) from the sign-in request into the profile.
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
  return new;
end;
$$;

-- 2. Busy times at a spa on one day, so booking can grey out taken slots without
--    revealing who booked. Includes weekly and monthly repeats.
drop function if exists public.spa_busy(text, date);
create or replace function public.spa_busy(spa_slug text, day date)
returns table (starts_at timestamptz, minutes int, category text)
language sql stable security definer set search_path = public as $$
  with s as (select id, time_zone from public.spas where slug = spa_slug),
  b as (
    select bk.id, bk.repeat, bk.repeat_until, (bk.starts_at at time zone s.time_zone) as local_start, s.time_zone
    from public.bookings bk join s on s.id = bk.spa_id
    where bk.status in ('pending_payment', 'booked', 'checked_in')
  ),
  hits as (
    select b.id, b.time_zone,
           ((day + (b.local_start::time)) - b.local_start) as shift
    from b
    where b.local_start::date <= day
      and (b.repeat_until is null or day <= b.repeat_until)
      and (
        (b.repeat = 'once' and b.local_start::date = day)
        or (b.repeat = 'weekly' and (day - b.local_start::date) % 7 = 0)
        or (b.repeat = 'monthly' and extract(day from b.local_start) = extract(day from day))
      )
  )
  select ((i.starts_at at time zone h.time_zone) + h.shift) at time zone h.time_zone, i.minutes, sv.category
  from hits h
  join public.booking_items i on i.booking_id = h.id
  join public.services sv on sv.id = i.service_id;
$$;
grant execute on function public.spa_busy(text, date) to anon, authenticated;
