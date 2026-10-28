# Supabase

Project: `https://inoyndkciffwqquhvsid.supabase.co`

## Applying the database setup

Easiest: run `setup-all-in-one.sql` (both migrations in one file, safe to re-run while there is no real data) in the Supabase dashboard. Or run the files in `migrations/` once, in order:
**SQL Editor → New query → paste the file → Run**.

1. `20261028000001_schema.sql` – tables, access rules (row level security) and helper functions
2. `20261028000002_seed.sql` – Mission Valley, the coming-soon spas, the menu, the membership plan, products and HQ defaults

## Roles

Every sign-up becomes a `client`. To make someone RKVR HQ staff or a spa operator, run in the SQL Editor:

```sql
update public.profiles set role = 'hq_admin' where email = 'you@example.com';
update public.profiles set role = 'operator' where email = 'operator@example.com';
update public.spas set operator_id = (select id from public.profiles where email = 'operator@example.com')
 where slug = 'mission-valley';
```

## Who can see what

| Data | Clients | Operators | HQ |
|---|---|---|---|
| Spas, menu, plans, products, switches | read (also signed out) | edit own spa's team and menu | everything |
| Own profile | read and edit (not role) | own + their clients | everything |
| Bookings | own; create; cancel via `cancel_booking()` | their spa's | everything |
| Memberships, orders | own (written by Stripe webhooks) | their clients' memberships | everything |
| Rent invoices | – | their spa's | everything |
| Service requests | – | their spa's; create and reply | everything |
| Campaigns | – | their spa's drafts and schedules | everything |

Secrets (Stripe secret key, webhook signing secret, Twilio, Resend) go in **Project Settings → Edge Functions → Secrets**, never in this repo.
