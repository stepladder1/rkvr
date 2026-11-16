-- Unlimited membership, the combined menu, and the front-desk Check-In.
--
-- 1. RKVR Membership becomes unlimited: $99/mo founding (join by Dec 31, 2026), $129 after.
--    Each service says whether membership covers it (services.member_included).
-- 2. Adds Compression Therapy and Massage Chair to the menu.
-- 3. Visits: one row per person who arrives at the desk, from a booking or as a walk-in.
--    The Check-In iPad (signed in as the spa's operator or HQ) reads and moves these.

-- 1. Unlimited membership ------------------------------------------------------
alter table public.membership_plans alter column services_per_month drop not null;  -- null = unlimited
update public.membership_plans set name = 'RKVR Unlimited', services_per_month = null where id = 'rkvr';

alter table public.services add column if not exists member_included boolean not null default true;

-- 2. Combined menu --------------------------------------------------------------
alter table public.services drop constraint if exists services_category_check;
alter table public.services add constraint services_category_check
  check (category in ('cryo', 'red', 'comp', 'chair', 'iv', 'tw', 'wl'));

-- Recovery services are covered by membership; drips, weight loss and video visits are paid per visit
update public.services set member_included = (category in ('cryo', 'red', 'comp', 'chair'));

insert into public.services (spa_id, name, category, minutes, price_cents, needs_review, sort, member_included)
select s.id, m.name, m.category, m.minutes, m.price_cents, false, m.sort, true
from public.spas s,
(values ('Compression Therapy', 'comp', 30, 3900, 25), ('Massage Chair', 'chair', 20, 2500, 26))
  as m(name, category, minutes, price_cents, sort)
where s.slug = 'mission-valley'
  and not exists (select 1 from public.services x where x.spa_id = s.id and x.category = m.category);

create or replace function public.my_membership_summary() returns table (
  plan_name text, rate_cents int, is_founding boolean, status text,
  services_per_month int, used int, remaining int, period_end date)
language sql stable security definer set search_path = public as $$
  select p.name, m.rate_cents, m.is_founding, m.status, p.services_per_month,
         public.member_services_used(m.client_id),
         case when p.services_per_month is null then null
              else greatest(0, p.services_per_month - public.member_services_used(m.client_id)) end,
         m.current_period_end
  from public.memberships m
  join public.membership_plans p on p.id = m.plan_id
  where m.client_id = auth.uid() and m.status in ('active', 'past_due', 'paused')
  limit 1;
$$;

-- 3. Visits and the waiver ----------------------------------------------------------
alter table public.profiles add column if not exists waiver_signed_at timestamptz;

create table if not exists public.visits (
  id            uuid primary key default gen_random_uuid(),
  spa_id        uuid not null references public.spas (id) on delete cascade,
  day           date not null,                         -- the spa's local date
  booking_id    uuid references public.bookings (id) on delete set null,
  client_id     uuid references public.profiles (id) on delete set null,
  guest_name    text,                                  -- walk-ins without an account
  guest_phone   text,
  service_ids   uuid[] not null default '{}',          -- walk-ins; booked visits use booking_items
  pay           text not null default 'alacarte' check (pay in ('member', 'alacarte', 'join')),
  amount_cents  int not null default 0,                -- à la carte total
  status        text not null default 'checked_in' check (status in ('checked_in', 'in_room', 'done', 'no_show')),
  source        text not null default 'desk' check (source in ('desk', 'kiosk')),
  waiver_at     timestamptz,                           -- guests sign per visit
  paid_at       timestamptz,
  paid_how      text check (paid_how in ('reader', 'desk', 'online')),
  note          text,
  checked_in_at timestamptz not null default now(),
  in_room_at    timestamptz,
  done_at       timestamptz,
  unique (booking_id, day)
);
create index if not exists visits_spa_day on public.visits (spa_id, day);

alter table public.visits enable row level security;
drop policy if exists "desk visits" on public.visits;
create policy "desk visits" on public.visits for all
  using (public.is_my_spa(spa_id) or public.is_hq()) with check (public.is_my_spa(spa_id) or public.is_hq());
drop policy if exists "own visits read" on public.visits;
create policy "own visits read" on public.visits for select using (client_id = auth.uid());
grant select, insert, update, delete on public.visits to authenticated;
grant all on public.visits to service_role;

create or replace function public.digits10(p text) returns text
language sql immutable as $$ select right(regexp_replace(coalesce(p, ''), '\D', '', 'g'), 10) $$;

create or replace function public.desk_spa(spa_slug text) returns public.spas
language plpgsql stable security definer set search_path = public as $$
declare s public.spas;
begin
  select * into s from public.spas where slug = spa_slug;
  if not found then raise exception 'Unknown spa'; end if;
  if not (public.is_hq() or public.is_my_spa(s.id)) then raise exception 'Not allowed at this spa'; end if;
  return s;
end;
$$;

-- Everything the desk needs for today: booked visits (including repeats) and walk-ins
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
      'paid', v.paid_at is not null, 'note', o.note,
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

-- Check in a booked visit (from the desk or the client side of the iPad)
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
  insert into public.visits (spa_id, day, booking_id, client_id, pay, amount_cents, source, note)
  values (s.id, today, bk.id, bk.client_id,
          case when mem or bk.pay_method = 'member' then 'member' else 'alacarte' end,
          (select coalesce(sum(i.price_cents) filter (where not ((mem or bk.pay_method = 'member') and sv.member_included)), 0)
             from public.booking_items i join public.services sv on sv.id = i.service_id where i.booking_id = bk.id),
          coalesce(p_source, 'desk'), bk.note)
  on conflict (booking_id, day) do update set status = case when public.visits.status = 'no_show' then 'checked_in' else public.visits.status end
  returning id into vid;
  if bk.repeat = 'once' then update public.bookings set status = 'checked_in' where id = bk.id and status = 'booked'; end if;
  return vid;
end;
$$;

-- Walk-ins. For members, finds them by mobile number.
create or replace function public.desk_walk_in(spa_slug text, p_services uuid[], p_pay text, p_phone text default null,
  p_name text default null, p_source text default 'desk', p_waiver boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  s public.spas := public.desk_spa(spa_slug);
  cid uuid; cname text; amt int; vid uuid; ph text := public.digits10(p_phone);
begin
  if coalesce(array_length(p_services, 1), 0) = 0 or array_length(p_services, 1) > 3 then raise exception 'Pick 1 to 3 services'; end if;
  if exists (select 1 from unnest(p_services) x where not exists (select 1 from public.services v where v.id = x and v.spa_id = s.id and v.active)) then
    raise exception 'A service isn’t available here';
  end if;
  if length(ph) = 10 then
    select p.id, p.full_name into cid, cname from public.profiles p where public.digits10(p.phone) = ph
      order by exists (select 1 from public.memberships m where m.client_id = p.id and m.status in ('active', 'past_due')) desc limit 1;
  end if;
  if p_pay = 'member' and (cid is null or not exists (select 1 from public.memberships m where m.client_id = cid and m.status in ('active', 'past_due'))) then
    return jsonb_build_object('error', 'no_member');
  end if;
  select coalesce(sum(price_cents) filter (where not (p_pay in ('member', 'join') and member_included)), 0) into amt
    from public.services where id = any (p_services);
  insert into public.visits (spa_id, day, client_id, guest_name, guest_phone, service_ids, pay, amount_cents, source, waiver_at, note)
  values (s.id, (now() at time zone s.time_zone)::date, cid, case when cid is null then nullif(trim(p_name), '') end,
          case when cid is null then nullif(ph, '') end, p_services, p_pay, amt, coalesce(p_source, 'desk'),
          case when p_waiver then now() end,
          case when p_pay = 'join' then 'Joined today. Set up their membership.' end)
  returning id into vid;
  if p_waiver and cid is not null then update public.profiles set waiver_signed_at = coalesce(waiver_signed_at, now()) where id = cid; end if;
  return jsonb_build_object('visit_id', vid, 'name', coalesce(cname, nullif(trim(p_name), ''), 'Walk-in'), 'amount_cents', amt);
end;
$$;

-- Move a visit along: in_room, done (optionally marking it paid), no_show
create or replace function public.desk_move(p_visit uuid, p_status text, p_paid_how text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v public.visits; s public.spas;
begin
  select * into v from public.visits where id = p_visit;
  if not found then raise exception 'Visit not found'; end if;
  select * into s from public.spas where id = v.spa_id;
  perform public.desk_spa(s.slug);
  update public.visits set
    status = p_status,
    in_room_at = case when p_status = 'in_room' then coalesce(in_room_at, now()) else in_room_at end,
    done_at = case when p_status = 'done' then now() else done_at end,
    paid_at = case when p_paid_how is not null then coalesce(paid_at, now()) else paid_at end,
    paid_how = coalesce(p_paid_how, paid_how)
  where id = p_visit;
  if p_status = 'done' and v.booking_id is not null then
    update public.bookings set status = 'completed' where id = v.booking_id and repeat = 'once';
  end if;
end;
$$;

-- Mark a client's waiver signed (staff confirmed it on paper or on the iPad)
create or replace function public.desk_waiver(p_booking uuid) returns void
language plpgsql security definer set search_path = public as $$
declare bk public.bookings; s public.spas;
begin
  select * into bk from public.bookings where id = p_booking;
  select * into s from public.spas where id = bk.spa_id;
  perform public.desk_spa(s.slug);
  update public.profiles set waiver_signed_at = coalesce(waiver_signed_at, now()) where id = bk.client_id;
end;
$$;

revoke execute on function public.desk_spa(text), public.desk_today(text), public.desk_check_in(uuid, text, boolean),
  public.desk_walk_in(text, uuid[], text, text, text, text, boolean), public.desk_move(uuid, text, text), public.desk_waiver(uuid) from public, anon;
grant execute on function public.desk_spa(text), public.desk_today(text), public.desk_check_in(uuid, text, boolean),
  public.desk_walk_in(text, uuid[], text, text, text, text, boolean), public.desk_move(uuid, text, text), public.desk_waiver(uuid),
  public.digits10(text) to authenticated;
