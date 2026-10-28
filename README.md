# RKVR

RKVR is recovery and wellness spas inside Phenix Salon Suites. Powered by SalonHQ.

| Folder | What it is | Deploy as |
|---|---|---|
| `apps/website` | Public website: locations, services, membership, booking, cart | Static site |
| `apps/client` | RKVR client app (installable web app) | Static site |
| `apps/pro` | RKVR Pro, the spa operator's app (installable web app) | Static site |
| `apps/hq` | RKVR HQ corporate dashboard | Static site (sign-in required once live) |
| `supabase/` | Database migrations and edge functions (Stripe webhooks, messaging) | Supabase |

All four apps currently run on built-in sample data. They are being connected to Supabase (data and sign-in) and Stripe (payments) step by step.

## Deploying (Netlify)

Create one Netlify site per app from this repo. The public website can use the repo root as its base directory (the root `netlify.toml` publishes `apps/website`). For the other apps set:

- **Base directory:** the app folder, for example `apps/website`
- **Build command:** leave empty
- **Publish directory:** the same folder

Bump `VERSION` in `apps/client/sw.js` and `apps/pro/sw.js` whenever their `index.html` changes, so installed apps pick up the update.

## Secrets

Never commit keys. Public values (Supabase project URL and publishable key, Stripe `pk_` key) go in the apps' config. Secret values (Stripe secret key, Supabase service role key, Twilio auth token, Resend API key) live only in Supabase project secrets.
