-- Online payments: à la carte visits paid by card ahead of time (website and app),
-- and at the front-desk iPad. Stripe's webhook sets bookings.paid_at or visits.paid_at.

alter table public.bookings add column if not exists paid_at timestamptz;

-- Only Stripe (through the server) can mark a booking paid
drop policy if exists "client creates own bookings" on public.bookings;
create policy "client creates own bookings" on public.bookings for insert
  with check (client_id = auth.uid() and status in ('pending_payment', 'booked') and paid_at is null and stripe_payment_intent_id is null);

-- A prepaid visit is cancelled (and refunded) by the spa, not from the app
create or replace function public.cancel_booking(booking uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.bookings where id = booking and client_id = auth.uid() and paid_at is not null) then
    raise exception 'This visit is prepaid. Call or message the spa to cancel and get your refund.';
  end if;
  update public.bookings
     set status = 'canceled', canceled_at = now()
   where id = booking
     and client_id = auth.uid()
     and status in ('pending_payment', 'booked');
  if not found then
    raise exception 'Booking not found or can no longer be canceled';
  end if;
end;
$$;

-- Check-ins carry over a prepaid booking's payment to the visit
create or replace function public.desk_check_in(p_booking uuid, p_source text default 'desk', p_waiver boolean default false)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  bk public.bookings; s public.spas; today date; vid uuid; mem boolean;
begin
  select * into bk from public.bookings where id = p_booking;
  if not found then raise exception 'Booking not found'; end if;
  select * into s from public.spas where id = bk.spa_id;
  perform public.desk_spa(s.slug);
  today := (now() at time zone s.time_zone)::date;
  if p_waiver then update public.profiles set waiver_signed_at = coalesce(waiver_signed_at, now()) where id = bk.client_id; end if;
  select exists (select 1 from public.memberships where client_id = bk.client_id and status in ('active', 'past_due')) into mem;
  insert into public.visits (spa_id, day, booking_id, client_id, pay, amount_cents, source, note, paid_at, paid_how)
  values (s.id, today, bk.id, bk.client_id,
          case when mem or bk.pay_method = 'member' then 'member' else 'alacarte' end,
          (select coalesce(sum(i.price_cents) filter (where not ((mem or bk.pay_method = 'member') and sv.member_included)), 0)
             from public.booking_items i join public.services sv on sv.id = i.service_id where i.booking_id = bk.id),
          coalesce(p_source, 'desk'), bk.note,
          case when bk.paid_at is not null and bk.repeat = 'once' then bk.paid_at end,
          case when bk.paid_at is not null and bk.repeat = 'once' then 'online' end)
  on conflict (booking_id, day) do update set status = case when public.visits.status = 'no_show' then 'checked_in' else public.visits.status end
  returning id into vid;
  if bk.repeat = 'once' then update public.bookings set status = 'checked_in' where id = bk.id and status = 'booked'; end if;
  return vid;
end;
$$;

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
  insert into public.visits (spa_id, day, booking_id, client_id, pay, amount_cents, source, note, paid_at, paid_how)
  values (s.id, today, bk.id, bk.client_id,
          case when mem or bk.pay_method = 'member' then 'member' else 'alacarte' end,
          (select coalesce(sum(i.price_cents) filter (where not ((mem or bk.pay_method = 'member') and sv.member_included)), 0)
             from public.booking_items i join public.services sv on sv.id = i.service_id where i.booking_id = bk.id),
          'app', bk.note,
          case when bk.paid_at is not null and bk.repeat = 'once' then bk.paid_at end,
          case when bk.paid_at is not null and bk.repeat = 'once' then 'online' end)
  on conflict (booking_id, day) do nothing
  returning id into vid;
  if bk.repeat = 'once' then update public.bookings set status = 'checked_in' where id = bk.id and status = 'booked'; end if;
  return jsonb_build_object('ok', true, 'visit_id', vid);
end;
$$;

-- The desk shows prepaid bookings as paid
create or replace function public.desk_today(spa_slug text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  s public.spas := public.desk_spa(spa_slug);
  today date := (now() at time zone s.time_zone)::date;
  out jsonb;
begin
  with b as (
    select bk.*, (bk.starts_at at time zone s.time_zone) as local_start
    from public.bookings bk
    where bk.spa_id = s.id and bk.status in ('booked', 'checked_in', 'completed')
  ), occ as (
    select b.*, ((today + b.local_start::time) at time zone s.time_zone) as occ_start,
           ((today + b.local_start::time) - b.local_start) as shift
    from b
    where b.local_start::date <= today and (b.repeat_until is null or today <= b.repeat_until)
      and ((b.repeat = 'once' and b.local_start::date = today)
        or (b.repeat = 'weekly' and (today - b.local_start::date) % 7 = 0)
        or (b.repeat = 'monthly' and extract(day from b.local_start) = extract(day from today)))
  ), booked as (
    select jsonb_build_object(
      'key', 'b:' || o.id, 'booking_id', o.id, 'visit_id', v.id,
      'starts_at', o.occ_start, 'name', coalesce(p.full_name, p.email, 'Client'),
      'phone', public.digits10(p.phone),
      'pay', case when v.pay is not null then v.pay when m.id is not null or o.pay_method = 'member' then 'member' else 'alacarte' end,
      'status', coalesce(v.status, 'booked'), 'source', v.source,
      'waiver', p.waiver_signed_at is not null,
      'first_visit', not exists (select 1 from public.visits pv where pv.client_id = o.client_id and pv.status = 'done'),
      'paid', v.paid_at is not null or (o.paid_at is not null and o.repeat = 'once'), 'note', o.note,
      'items', (select jsonb_agg(jsonb_build_object('service_id', i.service_id, 'name', sv.name, 'category', sv.category,
                  'minutes', i.minutes, 'price_cents', i.price_cents, 'member_included', sv.member_included,
                  'starts_at', ((i.starts_at at time zone s.time_zone) + o.shift) at time zone s.time_zone) order by i.position)
                from public.booking_items i join public.services sv on sv.id = i.service_id where i.booking_id = o.id)
    ) as j, o.occ_start as t
    from occ o
    join public.profiles p on p.id = o.client_id
    left join public.visits v on v.booking_id = o.id and v.day = today
    left join public.memberships m on m.client_id = o.client_id and m.status in ('active', 'past_due')
  ), walk as (
    select jsonb_build_object(
      'key', 'v:' || v.id, 'booking_id', null, 'visit_id', v.id, 'starts_at', v.checked_in_at, 'walk_in', true,
      'name', coalesce(p.full_name, v.guest_name, 'Walk-in'), 'phone', public.digits10(coalesce(p.phone, v.guest_phone)),
      'pay', v.pay, 'status', v.status, 'source', v.source, 'waiver', true, 'first_visit', false,
      'paid', v.paid_at is not null, 'note', v.note,
      'items', (select jsonb_agg(jsonb_build_object('service_id', sv.id, 'name', sv.name, 'category', sv.category,
                  'minutes', sv.minutes, 'price_cents', sv.price_cents, 'member_included', sv.member_included) order by u.ord)
                from unnest(v.service_ids) with ordinality u(sid, ord) join public.services sv on sv.id = u.sid)
    ) as j, v.checked_in_at as t
    from public.visits v left join public.profiles p on p.id = v.client_id
    where v.spa_id = s.id and v.day = today and v.booking_id is null
  )
  select jsonb_build_object('spa', jsonb_build_object('id', s.id, 'slug', s.slug, 'name', s.name, 'time_zone', s.time_zone),
    'day', today, 'visits', coalesce((select jsonb_agg(j order by t) from (select * from booked union all select * from walk) x), '[]'::jsonb))
  into out;
  return out;
end;
$$;
