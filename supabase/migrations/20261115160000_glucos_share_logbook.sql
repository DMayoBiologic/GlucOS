-- The follower view (docs/Sharing.md "What followers see"): a follower sees the owner's chart,
-- time in range and, unless the owner turns it off for that link, their recent logbook (insulin,
-- food, site changes, moments) without notes. On by default: followers are family the owner chose,
-- and the logbook is what explains the chart. Each share link has its own switch.
alter table glucos.shares add column if not exists shows_logbook boolean not null default true;
