-- Check-ins: a follower taps "Check in" on their Lock Screen card when the person they follow is
-- low, and that person answers "I'm okay" or "I need help". One row per check-in; the relay keeps
-- each follower's latest on their card, and reminds both sides when there's no answer. See
-- supabase/functions/relay/checkins.ts and docs/Sharing.md.
--
-- Like the other sharing tables: row-level security on, no policies, only the edge functions read it.
create table if not exists glucos.check_ins (
  id uuid primary key default gen_random_uuid(),
  follower_id uuid not null references glucos.followers (id) on delete cascade,
  share_id uuid not null references glucos.shares (id) on delete cascade,
  -- The follower's name, as they gave it ('' when they didn't).
  name text not null default '',
  -- Seconds since 1970, like the relay's other times.
  asked_at double precision not null,
  last_asked_at double precision not null,
  reminded_at double precision,
  answer text check (answer in ('okay', 'help')),
  answered_at double precision,
  created_at timestamptz not null default now()
);

create index if not exists check_ins_follower on glucos.check_ins (follower_id, asked_at desc);
create index if not exists check_ins_open on glucos.check_ins (asked_at) where answer is null;

alter table glucos.check_ins enable row level security;
revoke all on glucos.check_ins from public, anon, authenticated;
