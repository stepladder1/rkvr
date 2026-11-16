-- RKVR database setup: run this whole file once in Supabase → SQL Editor → New query → Run.
-- It first removes any half-finished RKVR setup from an earlier attempt (this project has no
-- real data yet), then creates the tables, access rules and starting data.

drop trigger if exists on_auth_user_created on auth.users;
drop table if exists public.visits, public.team_invites, public.hq_items, public.hq_docs, public.audit_log, public.settings, public.feature_flags, public.campaigns,
  public.request_messages, public.service_requests, public.invoice_lines, public.invoices,
  public.order_items, public.prepaid_services, public.orders, public.products, public.booking_items,
  public.bookings, public.memberships, public.membership_plans, public.services, public.providers,
  public.spas, public.profiles cascade;
drop function if exists public.is_hq(), public.my_spa_ids(), public.is_my_spa(uuid), public.is_my_client(uuid),
  public.member_services_used(uuid, date), public.handle_new_user(), public.guard_profile_update(),
  public.cancel_booking(uuid), public.my_membership_summary(), public.spa_busy(text, date), public.apply_team_invite(uuid, text), public.team_invite_added(),
  public.digits10(text), public.desk_spa(text), public.desk_today(text), public.desk_check_in(uuid, text, boolean),
  public.desk_walk_in(text, uuid[], text, text, text, text, boolean), public.desk_move(uuid, text, text), public.desk_waiver(uuid), public.client_check_in(uuid, boolean) cascade;

-- RKVR core schema
-- One RKVR spa per Phenix Salon Suites location. Each spa is run by one operator
-- (a Wellness Pro) who rents 1–3 empty Phenix suites. Clients either hold an
-- RKVR Membership (12 services a month) or pay à la carte.
--
-- Roles (profiles.role):
--   client    – books, buys and manages their own account
--   operator  – runs one or more spas in RKVR Pro
--   hq_admin  – RKVR corporate, full access in RKVR HQ
--
-- Money is stored in cents. Times are timestamptz; each spa has its own time zone.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- Profiles (one row per signed-in person)
-- ---------------------------------------------------------------------------
create table public.profiles (
  id            uuid primary key references auth.users (id) on delete cascade,
  role          text not null default 'client' check (role in ('client', 'operator', 'hq_admin')),
  full_name     text,
  email         text,
  phone         text,
  home_spa_id   uuid,
  sms_opt_in    boolean not null default false,
  email_opt_in  boolean not null default true,
  marketing_opt_out boolean not null default false,
  stripe_customer_id text unique,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Spas and what they offer
-- ---------------------------------------------------------------------------
create table public.spas (
  id              uuid primary key default gen_random_uuid(),
  slug            text not null unique,
  name            text not null,                 -- e.g. 'Mission Valley'
  market          text not null,                 -- e.g. 'San Diego'
  phenix_location text,                          -- the host Phenix Salon Suites location
  phenix_suites   text,                          -- e.g. '206–208'
  suite_count     int  not null default 1 check (suite_count between 1 and 3),
  address         text,
  city            text,
  state           text,
  zip             text,
  time_zone       text not null default 'America/Los_Angeles',
  lat             double precision,
  lng             double precision,
  hours           text,
  status          text not null default 'coming_soon'
                  check (status in ('interested', 'signed', 'buildout', 'coming_soon', 'open', 'paused', 'closed')),
  bookings_paused boolean not null default false,
  operator_id     uuid references public.profiles (id) on delete set null,
  rent_cycle      text not null default 'monthly' check (rent_cycle in ('monthly', 'weekly')),
  stripe_account_id text,                        -- Stripe Connect account of the operator
  created_at      timestamptz not null default now()
);

alter table public.profiles
  add constraint profiles_home_spa_fk foreign key (home_spa_id) references public.spas (id) on delete set null;

create table public.providers (
  id          uuid primary key default gen_random_uuid(),
  spa_id      uuid not null references public.spas (id) on delete cascade,
  profile_id  uuid references public.profiles (id) on delete set null,
  name        text not null,
  title       text,                              -- e.g. 'RN', 'NP'
  specialty   text,
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

create table public.services (
  id          uuid primary key default gen_random_uuid(),
  spa_id      uuid not null references public.spas (id) on delete cascade,
  provider_id uuid references public.providers (id) on delete set null,
  name        text not null,
  category    text not null check (category in ('cryo', 'red', 'iv', 'tw', 'wl')),
  minutes     int  not null check (minutes > 0),
  price_cents int  not null check (price_cents >= 0),
  needs_review boolean not null default false,   -- e.g. IV drips need a provider review first
  active      boolean not null default true,
  sort        int not null default 0,
  created_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Membership
-- ---------------------------------------------------------------------------
create table public.membership_plans (
  id                    text primary key,        -- e.g. 'rkvr'
  name                  text not null,
  price_cents           int  not null,           -- regular price
  founding_price_cents  int,                     -- locked-in price for founding members
  founding_cutoff       date,                    -- join by this date to get the founding price
  services_per_month    int  not null,
  stripe_price_id          text,
  stripe_founding_price_id text,
  active                boolean not null default true
);

create table public.memberships (
  id                 uuid primary key default gen_random_uuid(),
  client_id          uuid not null references public.profiles (id) on delete cascade,
  plan_id            text not null references public.membership_plans (id),
  home_spa_id        uuid references public.spas (id) on delete set null,
  rate_cents         int  not null,              -- what this member pays (founding or regular)
  is_founding        boolean not null default false,
  status             text not null default 'pending'
                     check (status in ('pending', 'active', 'past_due', 'paused', 'canceled')),
  current_period_start date,
  current_period_end   date,
  stripe_subscription_id text unique,
  started_at         timestamptz,
  canceled_at        timestamptz,
  created_at         timestamptz not null default now()
);
create unique index memberships_one_live_per_client
  on public.memberships (client_id) where status in ('pending', 'active', 'past_due', 'paused');

-- ---------------------------------------------------------------------------
-- Bookings: up to 3 services per visit, in the client's order
-- ---------------------------------------------------------------------------
create table public.bookings (
  id            uuid primary key default gen_random_uuid(),
  client_id     uuid not null references public.profiles (id) on delete cascade,
  spa_id        uuid not null references public.spas (id),
  starts_at     timestamptz not null,
  repeat        text not null default 'once' check (repeat in ('once', 'weekly', 'monthly')),
  repeat_until  date,
  pay_method    text not null check (pay_method in ('member', 'card', 'prepaid')),
  status        text not null default 'booked'
                check (status in ('pending_payment', 'booked', 'checked_in', 'completed', 'canceled', 'no_show')),
  deposit_cents int not null default 0,
  balance_cents int not null default 0,
  stripe_payment_intent_id text,
  note          text,
  canceled_at   timestamptz,
  created_at    timestamptz not null default now()
);
create index bookings_spa_time on public.bookings (spa_id, starts_at);
create index bookings_client on public.bookings (client_id, starts_at);

create table public.booking_items (
  id          uuid primary key default gen_random_uuid(),
  booking_id  uuid not null references public.bookings (id) on delete cascade,
  service_id  uuid not null references public.services (id),
  provider_id uuid references public.providers (id),
  position    int  not null check (position between 1 and 3),
  starts_at   timestamptz not null,
  minutes     int  not null,
  price_cents int  not null,
  uses_member_service boolean not null default false,
  unique (booking_id, position)
);

-- À la carte services bought ahead (from the website cart), booked later
create table public.prepaid_services (
  id          uuid primary key default gen_random_uuid(),
  client_id   uuid not null references public.profiles (id) on delete cascade,
  service_id  uuid not null references public.services (id),
  order_id    uuid,
  status      text not null default 'available' check (status in ('available', 'booked', 'used', 'refunded')),
  booking_id  uuid references public.bookings (id) on delete set null,
  created_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Shop
-- ---------------------------------------------------------------------------
create table public.products (
  id          text primary key,                  -- e.g. 'b12'
  name        text not null,
  subtitle    text,
  category    text not null check (category in ('weightLoss', 'skin', 'supplements', 'beauty')),
  price_cents int  not null,
  wholesale_cents int,
  rx          boolean not null default false,
  image       text,
  active      boolean not null default true,
  sort        int not null default 0
);

create table public.orders (
  id           uuid primary key default gen_random_uuid(),
  number       text unique,
  client_id    uuid references public.profiles (id) on delete set null,
  spa_id       uuid references public.spas (id),   -- set for wholesale supply orders
  kind         text not null default 'retail' check (kind in ('retail', 'supply')),
  status       text not null default 'pending_payment'
               check (status in ('pending_payment', 'paid', 'provider_review', 'processing', 'shipped', 'delivered', 'canceled', 'refunded')),
  total_cents  int not null default 0,
  ship_to      jsonb,
  stripe_payment_intent_id text,
  created_at   timestamptz not null default now()
);

create table public.order_items (
  id          uuid primary key default gen_random_uuid(),
  order_id    uuid not null references public.orders (id) on delete cascade,
  product_id  text references public.products (id),
  service_id  uuid references public.services (id),
  plan_id     text references public.membership_plans (id),
  name        text not null,
  qty         int not null default 1,
  price_cents int not null
);

alter table public.prepaid_services
  add constraint prepaid_order_fk foreign key (order_id) references public.orders (id) on delete set null;

-- ---------------------------------------------------------------------------
-- Rent: Phenix suites used by each spa
-- ---------------------------------------------------------------------------
create table public.invoices (
  id           uuid primary key default gen_random_uuid(),
  spa_id       uuid not null references public.spas (id) on delete cascade,
  number       text not null unique,
  cycle        text not null check (cycle in ('monthly', 'weekly')),
  period_start date not null,
  period_end   date not null,
  due_date     date not null,
  total_cents  int  not null default 0,
  status       text not null default 'open' check (status in ('draft', 'open', 'paid', 'overdue', 'void')),
  paid_at      timestamptz,
  paid_method  text check (paid_method in ('ach', 'card')),
  stripe_invoice_id text,
  created_at   timestamptz not null default now()
);

create table public.invoice_lines (
  id          uuid primary key default gen_random_uuid(),
  invoice_id  uuid not null references public.invoices (id) on delete cascade,
  description text not null,
  detail      text,
  amount_cents int not null
);

-- ---------------------------------------------------------------------------
-- Service requests (repairs) between operators and RKVR
-- ---------------------------------------------------------------------------
create table public.service_requests (
  id          uuid primary key default gen_random_uuid(),
  number      text unique,
  spa_id      uuid not null references public.spas (id) on delete cascade,
  created_by  uuid references public.profiles (id) on delete set null,
  kind        text not null check (kind in ('plumbing', 'electrical', 'hvac', 'access', 'other')),
  title       text not null,
  note        text,
  urgency     text not null default 'routine' check (urgency in ('routine', 'soon', 'blocking')),
  status      text not null default 'open' check (status in ('open', 'scheduled', 'in_progress', 'done')),
  eta         text,
  photo_path  text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create table public.request_messages (
  id          uuid primary key default gen_random_uuid(),
  request_id  uuid not null references public.service_requests (id) on delete cascade,
  author_id   uuid references public.profiles (id) on delete set null,
  from_rkvr   boolean not null default false,
  body        text not null,
  status      text check (status in ('open', 'scheduled', 'in_progress', 'done')),
  eta         text,
  created_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Marketing
-- ---------------------------------------------------------------------------
create table public.campaigns (
  id           uuid primary key default gen_random_uuid(),
  spa_id       uuid references public.spas (id) on delete cascade,   -- null = network campaign from HQ
  created_by   uuid references public.profiles (id) on delete set null,
  name         text not null,
  channel      text not null check (channel in ('text', 'email', 'push')),
  audience     jsonb not null default '{}'::jsonb,
  body         text not null,
  email        jsonb,
  offer        jsonb,
  status       text not null default 'draft' check (status in ('draft', 'scheduled', 'sending', 'sent', 'blocked', 'canceled')),
  blocked_reason text,
  scheduled_at timestamptz,
  sent_at      timestamptz,
  stats        jsonb not null default '{}'::jsonb,
  created_at   timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- HQ controls
-- ---------------------------------------------------------------------------
create table public.feature_flags (
  key        text primary key,
  enabled    boolean not null,
  updated_by uuid references public.profiles (id) on delete set null,
  updated_at timestamptz not null default now()
);

create table public.settings (
  key        text primary key,
  value      jsonb not null,
  updated_by uuid references public.profiles (id) on delete set null,
  updated_at timestamptz not null default now()
);

create table public.audit_log (
  id         bigint generated always as identity primary key,
  actor_id   uuid references public.profiles (id) on delete set null,
  action     text not null,
  detail     jsonb,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Helper functions (security definer so policies can call them without recursion)
-- ---------------------------------------------------------------------------
create or replace function public.is_hq() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'hq_admin');
$$;

create or replace function public.my_spa_ids() returns setof uuid
language sql stable security definer set search_path = public as $$
  select id from public.spas where operator_id = auth.uid();
$$;

create or replace function public.is_my_spa(spa uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.spas where id = spa and operator_id = auth.uid());
$$;

-- Clients who have booked at, or call home, a spa the current operator runs
create or replace function public.is_my_client(client uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.bookings b where b.client_id = client and b.spa_id in (select public.my_spa_ids()))
      or exists (select 1 from public.profiles p where p.id = client and p.home_spa_id in (select public.my_spa_ids()));
$$;

-- Member services used in the calendar month containing `day`
create or replace function public.member_services_used(client uuid, day date default current_date) returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int
  from public.booking_items i
  join public.bookings b on b.id = i.booking_id
  where b.client_id = client
    and (client = auth.uid() or public.is_hq() or public.is_my_client(client)
         or coalesce(current_setting('request.jwt.claims', true)::json ->> 'role', '') = 'service_role')
    and i.uses_member_service
    and b.status not in ('canceled')
    and date_trunc('month', i.starts_at) = date_trunc('month', day::timestamptz);
$$;

-- New sign-ups get a client profile automatically
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, phone, full_name)
  values (new.id, new.email, new.phone, coalesce(new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name'))
  on conflict (id) do nothing;
  return new;
end;
$$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- People can edit their own profile, but only HQ can change roles or Stripe IDs
create or replace function public.guard_profile_update() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  -- auth.uid() is null when run from the SQL editor or a server job: allowed
  if auth.uid() is not null and not public.is_hq()
     and coalesce(current_setting('request.jwt.claims', true)::json ->> 'role', '') <> 'service_role' then
    new.role := old.role;
    new.stripe_customer_id := old.stripe_customer_id;
  end if;
  new.updated_at := now();
  return new;
end;
$$;
create trigger profiles_guard before update on public.profiles
  for each row execute function public.guard_profile_update();

-- ---------------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------------
alter table public.profiles          enable row level security;
alter table public.spas              enable row level security;
alter table public.providers         enable row level security;
alter table public.services          enable row level security;
alter table public.membership_plans  enable row level security;
alter table public.memberships       enable row level security;
alter table public.bookings          enable row level security;
alter table public.booking_items     enable row level security;
alter table public.prepaid_services  enable row level security;
alter table public.products          enable row level security;
alter table public.orders            enable row level security;
alter table public.order_items       enable row level security;
alter table public.invoices          enable row level security;
alter table public.invoice_lines     enable row level security;
alter table public.service_requests  enable row level security;
alter table public.request_messages  enable row level security;
alter table public.campaigns         enable row level security;
alter table public.feature_flags     enable row level security;
alter table public.settings          enable row level security;
alter table public.audit_log         enable row level security;

-- Public catalog: anyone (including the website, signed out) can read
create policy "catalog read spas"     on public.spas             for select using (true);
create policy "catalog read providers" on public.providers       for select using (active or public.is_hq() or public.is_my_spa(spa_id));
create policy "catalog read services" on public.services         for select using (active or public.is_hq() or public.is_my_spa(spa_id));
create policy "catalog read plans"    on public.membership_plans for select using (true);
create policy "catalog read products" on public.products         for select using (active or public.is_hq());
create policy "flags read"            on public.feature_flags    for select using (true);
create policy "settings read"         on public.settings         for select using (true);

-- HQ manages the catalog and controls
create policy "hq writes spas"      on public.spas             for all using (public.is_hq()) with check (public.is_hq());
create policy "hq writes providers" on public.providers        for all using (public.is_hq()) with check (public.is_hq());
create policy "hq writes services"  on public.services         for all using (public.is_hq()) with check (public.is_hq());
create policy "hq writes plans"     on public.membership_plans for all using (public.is_hq()) with check (public.is_hq());
create policy "hq writes products"  on public.products         for all using (public.is_hq()) with check (public.is_hq());
create policy "hq writes flags"     on public.feature_flags    for all using (public.is_hq()) with check (public.is_hq());
create policy "hq writes settings"  on public.settings         for all using (public.is_hq()) with check (public.is_hq());
create policy "hq reads audit"      on public.audit_log        for select using (public.is_hq());
create policy "hq writes audit"     on public.audit_log        for insert with check (public.is_hq() and actor_id = auth.uid());

-- Operators keep their own spa's team and menu up to date
create policy "operator updates own spa" on public.spas for update using (public.is_my_spa(id)) with check (public.is_my_spa(id));
create policy "operator manages providers" on public.providers for all using (public.is_my_spa(spa_id)) with check (public.is_my_spa(spa_id));
create policy "operator manages services"  on public.services  for all using (public.is_my_spa(spa_id)) with check (public.is_my_spa(spa_id));

-- Profiles
create policy "own profile read"   on public.profiles for select using (id = auth.uid());
create policy "own profile update" on public.profiles for update using (id = auth.uid()) with check (id = auth.uid());
create policy "hq profiles"        on public.profiles for all using (public.is_hq()) with check (public.is_hq());
create policy "operator reads clients" on public.profiles for select using (public.is_my_client(id));

-- Memberships: changed only by HQ and by the Stripe webhook (service role)
create policy "own membership read"      on public.memberships for select using (client_id = auth.uid());
create policy "operator membership read" on public.memberships for select using (public.is_my_client(client_id));
create policy "hq memberships"           on public.memberships for all using (public.is_hq()) with check (public.is_hq());

-- Bookings: clients create and see their own; operators run their spa's; HQ sees all.
-- Clients cancel through cancel_booking() so they can't change payment fields.
create policy "client reads own bookings"   on public.bookings for select using (client_id = auth.uid());
create policy "client creates own bookings" on public.bookings for insert
  with check (client_id = auth.uid() and status in ('pending_payment', 'booked'));
create policy "operator spa bookings" on public.bookings for all using (public.is_my_spa(spa_id)) with check (public.is_my_spa(spa_id));
create policy "hq bookings"           on public.bookings for all using (public.is_hq()) with check (public.is_hq());

create policy "booking items read" on public.booking_items for select using (
  exists (select 1 from public.bookings b where b.id = booking_id
          and (b.client_id = auth.uid() or public.is_my_spa(b.spa_id) or public.is_hq())));
create policy "client adds items to own booking" on public.booking_items for insert with check (
  exists (select 1 from public.bookings b where b.id = booking_id and b.client_id = auth.uid() and b.status in ('pending_payment', 'booked')));
create policy "operator or hq items" on public.booking_items for all using (
  exists (select 1 from public.bookings b where b.id = booking_id and (public.is_my_spa(b.spa_id) or public.is_hq())))
  with check (exists (select 1 from public.bookings b where b.id = booking_id and (public.is_my_spa(b.spa_id) or public.is_hq())));

create policy "own prepaid read" on public.prepaid_services for select using (client_id = auth.uid());
create policy "hq prepaid"       on public.prepaid_services for all using (public.is_hq()) with check (public.is_hq());

-- Orders: created by checkout (service role); clients read their own
create policy "own orders read"      on public.orders for select using (client_id = auth.uid());
create policy "operator supply orders" on public.orders for select using (kind = 'supply' and public.is_my_spa(spa_id));
create policy "hq orders"            on public.orders for all using (public.is_hq()) with check (public.is_hq());
create policy "order items read" on public.order_items for select using (
  exists (select 1 from public.orders o where o.id = order_id
          and (o.client_id = auth.uid() or (o.kind = 'supply' and public.is_my_spa(o.spa_id)) or public.is_hq())));
create policy "hq order items" on public.order_items for all using (public.is_hq()) with check (public.is_hq());

-- Rent invoices: operators see their own; HQ manages
create policy "operator invoices read" on public.invoices for select using (public.is_my_spa(spa_id));
create policy "hq invoices"            on public.invoices for all using (public.is_hq()) with check (public.is_hq());
create policy "invoice lines read" on public.invoice_lines for select using (
  exists (select 1 from public.invoices v where v.id = invoice_id and (public.is_my_spa(v.spa_id) or public.is_hq())));
create policy "hq invoice lines" on public.invoice_lines for all using (public.is_hq()) with check (public.is_hq());

-- Service requests
create policy "operator requests read"   on public.service_requests for select using (public.is_my_spa(spa_id));
create policy "operator requests create" on public.service_requests for insert with check (public.is_my_spa(spa_id) and created_by = auth.uid());
create policy "hq requests"              on public.service_requests for all using (public.is_hq()) with check (public.is_hq());
create policy "request messages read" on public.request_messages for select using (
  exists (select 1 from public.service_requests r where r.id = request_id and (public.is_my_spa(r.spa_id) or public.is_hq())));
create policy "operator replies" on public.request_messages for insert with check (
  author_id = auth.uid() and not from_rkvr
  and exists (select 1 from public.service_requests r where r.id = request_id and public.is_my_spa(r.spa_id)));
create policy "hq replies" on public.request_messages for insert with check (public.is_hq() and author_id = auth.uid());

-- Campaigns
create policy "operator campaigns" on public.campaigns for all
  using (spa_id is not null and public.is_my_spa(spa_id))
  with check (spa_id is not null and public.is_my_spa(spa_id) and status in ('draft', 'scheduled', 'canceled'));
create policy "hq campaigns" on public.campaigns for all using (public.is_hq()) with check (public.is_hq());

-- ---------------------------------------------------------------------------
-- Actions clients can take safely
-- ---------------------------------------------------------------------------
create or replace function public.cancel_booking(booking uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
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

-- What a signed-in member has left this month
create or replace function public.my_membership_summary() returns table (
  plan_name text, rate_cents int, is_founding boolean, status text,
  services_per_month int, used int, remaining int, period_end date)
language sql stable security definer set search_path = public as $$
  select p.name, m.rate_cents, m.is_founding, m.status, p.services_per_month,
         public.member_services_used(m.client_id),
         greatest(0, p.services_per_month - public.member_services_used(m.client_id)),
         m.current_period_end
  from public.memberships m
  join public.membership_plans p on p.id = m.plan_id
  where m.client_id = auth.uid() and m.status in ('active', 'past_due', 'paused')
  limit 1;
$$;

-- ---------------------------------------------------------------------------
-- Grants (Supabase applies RLS on top of these)
-- ---------------------------------------------------------------------------
grant select on public.spas, public.providers, public.services, public.membership_plans,
  public.products, public.feature_flags, public.settings to anon;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant all on all tables in schema public to service_role;
grant usage, select on all sequences in schema public to authenticated, service_role;
grant execute on function public.cancel_booking(uuid), public.my_membership_summary(),
  public.member_services_used(uuid, date), public.is_hq(), public.my_spa_ids(),
  public.is_my_spa(uuid), public.is_my_client(uuid) to authenticated;
revoke execute on function public.member_services_used(uuid, date) from anon;

-- RKVR starting data: the first spa, the coming-soon spas, the service menu,
-- the membership plan, shop products and HQ defaults.
-- Prices are the current menu from the website and apps; change them in RKVR HQ
-- or here before launch. No sample clients or providers are created.

-- Spas -----------------------------------------------------------------------
insert into public.spas (slug, name, market, phenix_location, phenix_suites, suite_count, address, city, state, zip,
                         time_zone, lat, lng, hours, status)
values
  ('mission-valley', 'Mission Valley', 'San Diego', 'Phenix Salon Suites Mission Valley', '206', 1,
   '1640 Camino Del Rio N, Ste 206', 'San Diego', 'CA', '92108', 'America/Los_Angeles', 32.7695, -117.1530,
   'Mon–Sat 8 AM–8 PM · Sun 10 AM–6 PM', 'open'),
  ('austin-domain', 'The Domain', 'Austin', null, null, 1, null, 'Austin', 'TX', null, 'America/Chicago', 30.402, -97.725, null, 'coming_soon'),
  ('austin-soco', 'South Congress', 'Austin', null, null, 1, null, 'Austin', 'TX', null, 'America/Chicago', 30.247, -97.750, null, 'coming_soon'),
  ('dallas-uptown', 'Uptown', 'Dallas', null, null, 1, null, 'Dallas', 'TX', null, 'America/Chicago', 32.800, -96.801, null, 'coming_soon');

-- Mission Valley menu ------------------------------------------------------------
insert into public.services (spa_id, name, category, minutes, price_cents, needs_review, sort)
select s.id, m.name, m.category, m.minutes, m.price_cents, m.needs_review, m.sort
from public.spas s,
(values
  ('Whole-Body Cryotherapy',       'cryo', 15,  4500, false, 10),
  ('Localized Cryotherapy',        'cryo', 20,  4000, false, 11),
  ('Cryo + Compression',           'cryo', 45,  7900, false, 12),
  ('Full-Body Red Light',          'red',  20,  4900, false, 20),
  ('Red Light + Infrared Sauna',   'red',  40,  6900, false, 21),
  ('Red Light + Compression',      'red',  40,  7500, false, 22),
  ('Myers’ Cocktail',              'iv',   45, 19900, true,  30),
  ('Immunity Defense Drip',        'iv',   45, 18900, true,  31),
  ('Hydration and Hangover Drip',  'iv',   40, 15900, true,  32),
  ('Energy and Recovery Drip',     'iv',   45, 18900, true,  33),
  ('NAD+ Therapy',                 'iv',  120, 39900, true,  34),
  ('Beauty and Glow Drip',         'iv',   45, 21900, true,  35),
  ('B12 Shot',                     'iv',   15,  3500, false, 36),
  ('Weight Loss Consult',          'wl',   30,  9500, true,  40),
  ('Weight Loss Check-in',         'wl',   20,  4500, false, 41),
  ('TeleWellness Video Visit',     'tw',   20,  4500, false, 50)
) as m(name, category, minutes, price_cents, needs_review, sort)
where s.slug = 'mission-valley';

-- Membership -----------------------------------------------------------------
insert into public.membership_plans (id, name, price_cents, founding_price_cents, founding_cutoff, services_per_month)
values ('rkvr', 'RKVR Membership', 12900, 9900, '2026-12-31', 12);

-- Shop -----------------------------------------------------------------------
insert into public.products (id, name, subtitle, category, price_cents, wholesale_cents, rx, image, sort) values
  ('glp1', 'GLP-1 Program',          'Semaglutide · 4 weeks',  'weightLoss',  24900, 12900, true,  'glp1.webp', 10),
  ('tirz', 'Tirzepatide Program',    'Compounded · 4 weeks',   'weightLoss',  32900, 15900, true,  'tirz.webp', 11),
  ('ret',  'Retinol 0.5 Serum',      '30 ml',                  'skin',         6800,  3100, false, 'ret.webp',  20),
  ('eye',  'Brightening Eye Cream',  '15 ml',                  'skin',         6400,  2900, false, 'eye.webp',  21),
  ('nad',  'NAD+ Injectable',        '100 mg · 10 doses',      'supplements', 18900,  9600, true,  'nad.webp',  30),
  ('b12',  'B12 + MIC Shots',        '4 shots',                'supplements',  7500,  2400, false, 'b12.webp',  31),
  ('lash', 'Lash + Brow Serum',      'Growth serum · 4 ml',    'beauty',       5800,  2400, false, 'lash.webp', 40),
  ('lip',  'Lip Treatment',          'Overnight · 15 ml',      'beauty',       3200,  1200, false, 'lip.webp',  41);

-- HQ feature switches (all on except where noted) ----------------------------------
insert into public.feature_flags (key, enabled) values
  ('booking', true), ('textToBook', true), ('care', true),
  ('memberCredits', true), ('wallet', true), ('payWithCredits', true), ('creditCheckin', true),
  ('shop', true), ('catWeightLoss', true), ('catSkin', true), ('catSupplements', true), ('catBeauty', true),
  ('rent', true), ('rentAch', true), ('rentCard', true), ('rentAutopay', true), ('rentWeekly', true),
  ('supply', true), ('tap', true), ('marketing', true), ('requests', true),
  ('slots', true), ('promo', true), ('winback', true), ('news', true);

-- HQ settings ----------------------------------------------------------------------
insert into public.settings (key, value) values
  ('membership', '{"planPrice": 99, "regularPrice": 129, "servicesPerMonth": 12, "foundingCutoff": "2026-12-31"}'),
  ('payments',   '{"depositCents": 4000, "cardFeePct": 3, "operatorPayoutPerMemberServiceCents": 1200}'),
  ('marketing',  '{"perWeek": 2, "maxDiscount": 20, "quietStart": "21:00", "quietEnd": "09:00", "chText": true, "chPush": true, "chEmail": true, "approvePromos": false, "tplSlots": true, "tplPromo": true, "tplWinback": true, "tplNews": true}');

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
