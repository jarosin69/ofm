#!/bin/sh
# OFM migration runner (ADR-0012).
#
# Applies the numbered SQL files in db/migrations/ in order, each exactly once,
# and records them in public.schema_migrations - the database's revision log.
# Runs inside the "migrate" service of deploy/docker-compose.yml:
#
#   docker compose run --rm migrate            apply pending migrations (default)
#   docker compose run --rm migrate status     list applied and pending migrations
#   docker compose run --rm migrate example    load the example plant (db/examples/acme.sql)
#   docker compose run --rm migrate erd        regenerate docs/generated/erd.md
#
# The stack also runs "up" automatically on every "docker compose up".
# Connection settings come from PGHOST, PGUSER, PGPASSWORD, PGDATABASE.
set -eu

REPO=${OFM_REPO:-/repo}
MIGRATIONS="$REPO/db/migrations"
export PGOPTIONS="-c client_min_messages=warning"

sql() { psql -X -q -v ON_ERROR_STOP=1 "$@"; }

ensure_log() {
  sql -c "CREATE TABLE IF NOT EXISTS public.schema_migrations (
            version     text PRIMARY KEY,
            filename    text NOT NULL,
            checksum    text NOT NULL,
            applied_at  timestamptz NOT NULL DEFAULT now(),
            applied_by  text NOT NULL DEFAULT current_user)"
}

# Lists migration files, refusing badly named files and duplicate numbers.
migration_files() {
  seen=""
  for f in "$MIGRATIONS"/*; do
    [ -e "$f" ] || continue
    name=$(basename "$f")
    case "$name" in
      README*|.*) continue ;;
    esac
    if ! echo "$name" | grep -Eq '^[0-9]{3}-[a-z0-9-]+\.sql$'; then
      echo "ERROR: '$name' is not named NNN-description.sql (lowercase, digits, hyphens)." >&2
      exit 1
    fi
    version=${name%%-*}
    case " $seen " in
      *" $version "*) echo "ERROR: two migrations share number $version." >&2; exit 1 ;;
    esac
    seen="$seen $version"
    echo "$f"
  done
}

applied_checksum() {
  sql -At -c "SELECT checksum FROM public.schema_migrations WHERE version = '$1'"
}

cmd_up() {
  ensure_log
  files=$(migration_files)
  count=0
  for f in $files; do
    name=$(basename "$f")
    version=${name%%-*}
    sum=$(tr -d '\r' < "$f" | sha256sum | cut -d ' ' -f 1)   # line endings normalised
    recorded=$(applied_checksum "$version")
    if [ -n "$recorded" ]; then
      if [ "$recorded" != "$sum" ]; then
        echo "ERROR: $name has been changed since it was applied." >&2
        echo "An applied migration must never be edited. Restore it from Git and put the change in a new migration." >&2
        exit 1
      fi
      continue
    fi
    echo "Applying $name"
    record="INSERT INTO public.schema_migrations (version, filename, checksum) VALUES ('$version', '$name', '$sum');"
    if head -n 1 "$f" | grep -q 'ofm:no-transaction'; then
      # For the few statements PostgreSQL cannot run inside a transaction.
      sql -f "$f"
      sql -c "$record"
    else
      # The migration and its log entry succeed or fail together.
      { echo "BEGIN;"; cat "$f"; echo; echo "$record"; echo "COMMIT;"; } | sql
    fi
    count=$((count + 1))
  done
  if [ "$count" -eq 0 ]; then
    echo "Database is up to date."
  else
    echo "Applied $count migration(s). Database is up to date."
  fi
}

cmd_status() {
  ensure_log
  echo "Applied:"
  sql -At -F '  ' -c "SELECT version, filename, to_char(applied_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC', applied_by
                      FROM public.schema_migrations ORDER BY version" | sed 's/^/  /'
  echo "Pending:"
  pending=0
  for f in $(migration_files); do
    name=$(basename "$f")
    if [ -z "$(applied_checksum "${name%%-*}")" ]; then
      echo "  $name"
      pending=$((pending + 1))
    fi
  done
  [ "$pending" -eq 0 ] && echo "  (none)"
  return 0
}

cmd_example() {
  exists=$(sql -At -c "SELECT count(*) FROM config.enterprise WHERE name = 'acme'")
  if [ "$exists" != "0" ]; then
    echo "The example enterprise 'acme' already exists - nothing changed."
    return 0
  fi
  { echo "BEGIN;"; cat "$REPO/db/examples/acme.sql"; echo; echo "COMMIT;"; } | sql
  echo "Example plant 'acme' loaded. Topics:"
  sql -At -c "SELECT '  ' || topic || COALESCE('   <- ' || cache_key, '') FROM config.vw_runtime_model ORDER BY topic"
}

cmd_erd() {
  mkdir -p "$REPO/docs/generated"
  sql -At -f "$REPO/tools/erd.sql" > "$REPO/docs/generated/erd.md"
  echo "Written docs/generated/erd.md"
}

case "${1:-up}" in
  up)      cmd_up ;;
  status)  cmd_status ;;
  example) cmd_example ;;
  erd)     cmd_erd ;;
  *) echo "Usage: migrate [up|status|example|erd]" >&2; exit 2 ;;
esac
