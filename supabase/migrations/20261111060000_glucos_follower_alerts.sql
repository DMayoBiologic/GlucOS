-- Follower alerts: a follower phone can also get the owner's glucose alerts (low, high,
-- predicted, no data) as ordinary push notifications, named for whose readings they are.
-- The phone sends its APNs device token when it follows; the relay sends to it on each alert.
alter table glucos.followers
  add column if not exists device_token text,
  add column if not exists alerts_enabled boolean not null default true;
