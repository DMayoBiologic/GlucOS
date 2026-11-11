-- GlucOS push relay: state, readings and the every-minute schedule.
--
-- Everything lives in the `glucos` schema. The Data API only exposes `public`, and row-level
-- security is on with no policies, so the anon and authenticated keys can't read any of it;
-- only the relay edge function (connected as the database owner) can. The LibreLinkUp login is
-- kept in Supabase Vault, encrypted, not in these tables.

create schema if not exists glucos;
revoke all on schema glucos from public, anon, authenticated;

-- One phone, one account: GlucOS is personal, so the relay's state is a single row.
create table if not exists glucos.relay (
  id smallint primary key default 1 check (id = 1),
  prefs jsonb not null default '{}'::jsonb,
  account_generation bigint not null default 0,
  activity jsonb,
  pending_start boolean not null default false,
  start_attempts integer not null default 0,
  last_start_attempt double precision,
  work jsonb not null default '{}'::jsonb,
  -- Only one tick at a time.
  tick_lease_until timestamptz,
  updated_at timestamptz not null default now()
);
insert into glucos.relay (id) values (1) on conflict (id) do nothing;

-- The APNs provider token, reused for 50 minutes (Apple throttles refreshing it more often).
create table if not exists glucos.apns_token (
  id smallint primary key default 1 check (id = 1),
  token text not null,
  issued_at double precision not null
);

-- Readings as LibreLinkUp reports them: the history graph plus each minute's current reading.
-- Kept for 90 days; the relay prunes older ones.
create table if not exists glucos.readings (
  at timestamptz primary key,
  mgdl double precision not null,
  trend smallint not null default 0
);

alter table glucos.relay enable row level security;
alter table glucos.apns_token enable row level security;
alter table glucos.readings enable row level security;
revoke all on all tables in schema glucos from public, anon, authenticated;

-- The schedule authenticates to the function with a random token kept in Vault. Generated here,
-- once, so there's nothing to set up by hand.
do $$
begin
  if not exists (select 1 from vault.secrets where name = 'glucos_cron_token') then
    perform vault.create_secret(
      replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''),
      'glucos_cron_token',
      'GlucOS relay: authenticates the every-minute pg_cron call to the edge function');
  end if;
end $$;

create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net with schema extensions;

-- Every minute: fetch from LibreLinkUp, alert, update the Lock Screen card.
select cron.unschedule(jobid) from cron.job where jobname = 'glucos-relay-tick';
select cron.schedule(
  'glucos-relay-tick',
  '* * * * *',
  $cron$
  select net.http_post(
    url := 'https://aqlbadbyjuoruwnwyfrc.supabase.co/functions/v1/relay/v1/tick',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'X-GlucOS-Cron', (select decrypted_secret from vault.decrypted_secrets where name = 'glucos_cron_token')
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 55000
  );
  $cron$
);
