-- Extensions used across Pawmates.
-- PostGIS: geography points + radius queries (nearby pets, events, places).
-- pg_cron: scheduled jobs (event reminders, cleanup).
create extension if not exists postgis with schema extensions;
create extension if not exists pg_cron;

-- Internal helpers live in `private`, which PostgREST does not expose,
-- so they cannot be called directly from the browser.
create schema if not exists private;
grant usage on schema private to authenticated;

-- Shared trigger: keep updated_at current on every UPDATE.
create or replace function private.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;
