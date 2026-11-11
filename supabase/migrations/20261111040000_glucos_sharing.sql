-- GlucOS sharing: share links the owner makes from the iPhone, and the follower phones that
-- opened one (for their Lock Screen card). See docs/Sharing.md.
--
-- Like the relay's tables these live in the `glucos` schema with row-level security on and no
-- policies: only the relay and share edge functions (connected as the database owner) read them.
-- A share's token is never stored, only its SHA-256.

create table if not exists glucos.shares (
  id uuid primary key default gen_random_uuid(),
  token_hash text not null unique,
  -- Shown to followers: whose readings these are.
  label text not null default 'GlucOS',
  created_at timestamptz not null default now(),
  -- null: until revoked.
  expires_at timestamptz,
  revoked_at timestamptz,
  last_viewed_at timestamptz
);

create table if not exists glucos.followers (
  id uuid primary key default gen_random_uuid(),
  share_id uuid not null references glucos.shares (id) on delete cascade,
  -- A random id per follower phone.
  installation text not null,
  sandbox boolean not null default false,
  live_activity_enabled boolean not null default true,
  push_to_start_token text,
  activity_id text,
  activity_token text,
  -- Seconds since 1970, like the relay row's times.
  activity_started_at double precision,
  last_card jsonb,
  last_pushed_at double precision,
  pending_start boolean not null default false,
  start_attempts integer not null default 0,
  last_start_attempt double precision,
  updated_at timestamptz not null default now(),
  unique (share_id, installation)
);

alter table glucos.shares enable row level security;
alter table glucos.followers enable row level security;
revoke all on glucos.shares, glucos.followers from public, anon, authenticated;
