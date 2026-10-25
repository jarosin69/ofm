#!/bin/sh
# OFM migration runner (ADR-0012).
#
# Applies the numbered SQL files in db/migrations/ in order, each exactly once,
# and records them in public.schema_migrations - the database's revision log.
# Runs inside the "migrate" service of deploy/docker-compose.yml:
#
#   docker compose run --rm migrate              apply pending migrations (default)
#   docker compose run --rm migrate status       list applied and pending migrations
#   docker compose run --rm migrate example      load or refresh the example plant (db/examples/acme.sql)
#   docker compose run --rm migrate erd          regenerate docs/generated/erd.md
#   docker compose run --rm migrate adduser NAME create a personal model-editing login
#
# The stack also runs "up" automatically on every "docker compose up".
# After applying migrations, "up" sets the passwords of the platform roles
# (ofm_runtime, ofm_config, ofm_reader, ofm_mathesar) to the values in
# deploy/.env, so .env stays the single source of every password.
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
    recorded=$(applied_checksum "$version")   # stops here (set -e) if the database is unreachable
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
  sync_role_passwords
}

# Sets each platform role's password to its value in deploy/.env, if the role
# exists and the variable is set. Passwords travel as psql variables on
# standard input, never on a command line.
sync_role_passwords() {
  synced=""
  for pair in ofm_runtime:OFM_RUNTIME_DB_PASSWORD ofm_config:OFM_CONFIG_DB_PASSWORD \
              ofm_reader:OFM_READER_DB_PASSWORD ofm_mathesar:OFM_MATHESAR_DB_PASSWORD; do
    role=${pair%%:*}
    var=${pair#*:}
    eval "pw=\${$var:-}"
    [ -n "$pw" ] || continue
    exists=$(sql -At -c "SELECT count(*) FROM pg_roles WHERE rolname = '$role'")
    [ "$exists" = "1" ] || continue
    printf '%s\n' "ALTER ROLE $role PASSWORD :'pw';" | sql -v pw="$pw"
    synced="$synced $role"
  done
  [ -z "$synced" ] || echo "Role passwords set from .env:$synced"
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
    recorded=$(applied_checksum "${name%%-*}")
    if [ -z "$recorded" ]; then
      echo "  $name"
      pending=$((pending + 1))
    fi
  done
  [ "$pending" -eq 0 ] && echo "  (none)"
  return 0
}

cmd_example() {
  { echo "BEGIN;"; cat "$REPO/db/examples/acme.sql"; echo; echo "COMMIT;"; } | sql
  echo "Example plant 'acme' loaded or refreshed. Topics and addresses:"
  sql -At -c "SELECT '  ' || topic || COALESCE(chr(10) || '      <- ' || cache_key, '') FROM config.vw_runtime_model WHERE topic LIKE 'acme/%' ORDER BY topic"
}

# Creates a personal login for editing the model. It has exactly the rights
# of ofm_config, but the audit log and updated_by record the person's name.
cmd_adduser() {
  name=${1:-}
  if ! echo "$name" | grep -Eq '^[a-z][a-z0-9_]{1,30}$' || echo "$name" | grep -Eq '^(ofm_|pg_)'; then
    echo "Usage: migrate adduser NAME   (lowercase letters, digits, _; not starting with ofm_ or pg_)" >&2
    exit 2
  fi
  exists=$(sql -At -c "SELECT count(*) FROM pg_roles WHERE rolname = '$name'")
  if [ "$exists" != "0" ]; then
    echo "ERROR: a database login named '$name' already exists." >&2
    exit 1
  fi
  pw=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)
  printf '%s\n' "CREATE ROLE $name LOGIN PASSWORD :'pw' IN ROLE ofm_config;" | sql -v pw="$pw"
  echo "Created database login '$name' with the model-editing rights of ofm_config."
  echo "  Password: $pw"
  echo "Save it in a password manager now; it is not stored anywhere else."
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
  adduser) cmd_adduser "${2:-}" ;;
  *) echo "Usage: migrate [up|status|example|erd|adduser NAME]" >&2; exit 2 ;;
esac
