-- RKVR client app: check in from your phone, and see your own visits.

alter table public.visits drop constraint if exists visits_source_check;
alter table public.visits add constraint visits_source_check check (source in ('desk', 'kiosk', 'app'));

-- A client checks themselves in for today's booking. Asks for the waiver first if it isn't signed.
create or replace function public.client_check_in(p_booking uuid, p_waiver boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  bk public.bookings; s public.spas; today date; ls timestamp; vid uuid; mem boolean; signed boolean;
begin
  select * into bk from public.bookings where id = p_booking and client_id = auth.uid();
  if not found then raise exception 'Booking not found'; end if;
  if bk.status not in ('booked', 'checked_in') then return jsonb_build_object('error', 'not_active'); end if;
  select * into s from public.spas where id = bk.spa_id;
  today := (now() at time zone s.time_zone)::date;
  ls := bk.starts_at at time zone s.time_zone;
  if not (ls::date <= today and (bk.repeat_until is null or today <= bk.repeat_until)
          and ((bk.repeat = 'once' and ls::date = today)
            or (bk.repeat = 'weekly' and (today - ls::date) % 7 = 0)
            or (bk.repeat = 'monthly' and extract(day from ls) = extract(day from today)))) then
    return jsonb_build_object('error', 'not_today');
  end if;
  if p_waiver then update public.profiles set waiver_signed_at = coalesce(waiver_signed_at, now()) where id = bk.client_id; end if;
  select waiver_signed_at is not null into signed from public.profiles where id = bk.client_id;
  if not signed then return jsonb_build_object('error', 'needs_waiver'); end if;
  select exists (select 1 from public.memberships where client_id = bk.client_id and status in ('active', 'past_due')) into mem;
  insert into public.visits (spa_id, day, booking_id, client_id, pay, amount_cents, source, note)
  values (s.id, today, bk.id, bk.client_id,
          case when mem or bk.pay_method = 'member' then 'member' else 'alacarte' end,
          (select coalesce(sum(i.price_cents) filter (where not ((mem or bk.pay_method = 'member') and sv.member_included)), 0)
             from public.booking_items i join public.services sv on sv.id = i.service_id where i.booking_id = bk.id),
          'app', bk.note)
  on conflict (booking_id, day) do nothing
  returning id into vid;
  if bk.repeat = 'once' then update public.bookings set status = 'checked_in' where id = bk.id and status = 'booked'; end if;
  return jsonb_build_object('ok', true, 'visit_id', vid);
end;
$$;
revoke execute on function public.client_check_in(uuid, boolean) from public, anon;
grant execute on function public.client_check_in(uuid, boolean) to authenticated;
