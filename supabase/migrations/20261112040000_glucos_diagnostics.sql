-- GlucOS error reports: what failed in the apps (a sensor read, a LibreLinkUp fetch, logbook sync,
-- the push relay), sent by the `diagnostics` edge function. See docs/Diagnostics.md.
--
-- Like the other GlucOS tables this is in the `glucos` schema with row-level security on and no
-- policies: only the edge function (connected as the database owner) writes it, and people read
-- it with SQL (the Supabase dashboard, the MCP, or scripts/diagnostics.sh). Reports carry no
-- glucose values or account details; see Sources/Core/Diagnostics.swift for what the apps send.

create table if not exists glucos.diagnostics (
  id uuid primary key,
  received_at timestamptz not null default now(),
  occurred_at timestamptz not null,
  -- A random id per app install, not tied to any account.
  install_id text not null,
  platform text not null,
  app text not null,
  app_version text not null,
  build text not null,
  os_version text not null,
  model text not null,
  feature text not null,
  step text not null,
  code text,
  message text not null,
  detail text,
  context jsonb not null default '{}'::jsonb,
  -- More of the same problem since the install last reported it (the apps send each problem at
  -- most hourly).
  repeats integer not null default 0,
  -- Sent with the Send Report button, with the person's note.
  user_sent boolean not null default false,
  note text
);

create index if not exists diagnostics_received_at on glucos.diagnostics (received_at desc);
create index if not exists diagnostics_feature on glucos.diagnostics (feature, step, code);
create index if not exists diagnostics_install on glucos.diagnostics (install_id, received_at desc);

alter table glucos.diagnostics enable row level security;
revoke all on glucos.diagnostics from public, anon, authenticated;

-- Each kind of problem: how often, on how many installs, which versions, and an example.
create or replace view glucos.diagnostics_summary with (security_invoker = true) as
select
  feature, step, code,
  count(*) as reports,
  sum(1 + repeats) as occurrences,
  count(distinct install_id) as installs,
  count(*) filter (where user_sent) as sent_by_user,
  array_agg(distinct platform) as platforms,
  array_agg(distinct app_version order by app_version) as app_versions,
  min(occurred_at) as first_seen,
  max(occurred_at) as last_seen,
  (array_agg(message order by occurred_at desc))[1] as latest_message,
  (array_agg(detail order by occurred_at desc) filter (where detail is not null))[1] as latest_detail
from glucos.diagnostics
where received_at > now() - interval '30 days'
group by feature, step, code;

-- The last two weeks of reports, newest first, with the context spelled out.
create or replace view glucos.diagnostics_recent with (security_invoker = true) as
select
  occurred_at at time zone 'Australia/Perth' as occurred_perth,
  feature, step, code, message, detail, note, user_sent, repeats,
  context ->> 'sensor' as sensor, context,
  platform, app_version, build, os_version, model, install_id, id
from glucos.diagnostics
where received_at > now() - interval '14 days'
order by occurred_at desc;

revoke all on glucos.diagnostics_summary, glucos.diagnostics_recent from public, anon, authenticated;

-- Reports older than 180 days are deleted daily.
create extension if not exists pg_cron with schema pg_catalog;
select cron.unschedule(jobid) from cron.job where jobname = 'glucos-diagnostics-retention';
select cron.schedule(
  'glucos-diagnostics-retention',
  '17 19 * * *',
  $cron$ delete from glucos.diagnostics where received_at < now() - interval '180 days' $cron$
);
