-- RKVR database setup: run this whole file once in Supabase → SQL Editor → New query → Run.
-- It first removes any half-finished RKVR setup from an earlier attempt (this project has no
-- real data yet), then creates the tables, access rules and starting data.

drop trigger if exists on_auth_user_created on auth.users;
drop table if exists public.audit_log, public.settings, public.feature_flags, public.campaigns,
  public.request_messages, public.service_requests, public.invoice_lines, public.invoices,
  public.order_items, public.prepaid_services, public.orders, public.products, public.booking_items,
  public.bookings, public.memberships, public.membership_plans, public.services, public.providers,
  public.spas, public.profiles cascade;
drop function if exists public.is_hq(), public.my_spa_ids(), public.is_my_spa(uuid), public.is_my_client(uuid),
  public.member_services_used(uuid, date), public.handle_new_user(), public.guard_profile_update(),
  public.cancel_booking(uuid), public.my_membership_summary() cascade;

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
