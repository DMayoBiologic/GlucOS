#!/usr/bin/env bash
# Reads the apps' error reports (glucos.diagnostics). See docs/Diagnostics.md.
#
#   scripts/diagnostics.sh                 problems in the last 30 days, most frequent first
#   scripts/diagnostics.sh recent [N]      the last N reports (default 30)
#   scripts/diagnostics.sh feature NAME    the last 50 reports for one feature, e.g. sensor.nfc
#   scripts/diagnostics.sh sent            reports people sent with Send Report, with their notes
#
# Needs psql and SUPABASE_DB_URL: the project's Postgres connection string (Supabase dashboard ›
# Connect › Session pooler). Without a database connection, run the same SQL through the Supabase
# MCP's execute_sql or the dashboard's SQL editor.
set -euo pipefail

: "${SUPABASE_DB_URL:?Set SUPABASE_DB_URL to the project's Postgres connection string}"
q() { psql "$SUPABASE_DB_URL" -X -P pager=off -v ON_ERROR_STOP=1 -c "$1"; }

case "${1:-summary}" in
  summary)
    q "select feature, step, code, reports, occurrences, installs, sent_by_user, app_versions,
              last_seen at time zone 'Australia/Perth' as last_seen_perth, latest_message, latest_detail
       from glucos.diagnostics_summary order by occurrences desc, last_seen desc;" ;;
  recent)
    n="${2:-30}"; [[ "$n" =~ ^[0-9]+$ ]] || { echo "N must be a number" >&2; exit 2; }
    q "select occurred_perth, feature, step, code, message, detail, note, sensor, platform, app_version, os_version, model
       from glucos.diagnostics_recent limit $n;" ;;
  feature)
    f="${2:?feature name, e.g. sensor.nfc}"; [[ "$f" =~ ^[a-z0-9._-]+$ ]] || { echo "bad feature name" >&2; exit 2; }
    q "select occurred_at at time zone 'Australia/Perth' as occurred_perth, step, code, message, detail, note, context,
              platform, app_version, os_version, model, repeats
       from glucos.diagnostics where feature = '$f' order by occurred_at desc limit 50;" ;;
  sent)
    q "select occurred_perth, feature, step, code, note, message, detail, platform, app_version, model
       from glucos.diagnostics_recent where user_sent limit 50;" ;;
  *) sed -n '2,12p' "$0"; exit 2 ;;
esac
