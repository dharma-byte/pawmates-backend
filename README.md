# pawmates-backend

Supabase backend for **Pawmates**, a pets-only social platform: where pets make friends, and so do their humans.

## Contains

- `supabase/migrations/` SQL migrations (tables, PostGIS, RLS policies, functions, triggers)
- `supabase/functions/` Edge Functions (notifications, emails, lost-pet alerts, reminders, geocoding)
- `supabase/seed.sql` sample data for local development
- `supabase/tests/` pgTAP tests for RLS and functions
- `scripts/` helper scripts (type generation, local reset)
- `docs/` schema and API reference

## Requirements

- Node.js (LTS)
- Docker Desktop (to run Supabase locally)
- Supabase CLI (`npx supabase`)

## Getting started

```bash
cp .env.example .env
npx supabase start          # run Supabase locally
npx supabase db reset       # apply migrations + seed
```

## Branches

- `main` deploys to the production Supabase project
- `dev` is for testing; feature branches merge into `dev` first

The frontend lives in [pawmates-web](../pawmates-web).
