#!/usr/bin/env bash
#
# Applies the migrations to a scratch Postgres database and runs the RLS
# assertions against them. Exercises our policies only — the Supabase-managed
# pieces (auth.uid(), storage.foldername(), the anon/authenticated/service_role
# roles) are stubbed by 00_supabase_mock.sql.
#
# Requires a local Postgres you can create databases in.
#   ./supabase/tests/run.sh
#
set -euo pipefail

DB_NAME="${DB_NAME:-jeju_rls_test}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIGRATIONS="$HERE/../migrations"

# Postgres installs usually only trust the `postgres` OS user for local
# superuser access; re-exec through it when we're root and it exists.
if [[ "$(id -u)" -eq 0 ]] && id postgres >/dev/null 2>&1; then
  RUN=(su postgres -c)
  STAGE="$(mktemp -d /tmp/jeju-rls-XXXXXX)"
  chmod 755 "$STAGE"
  cp "$HERE"/*.sql "$MIGRATIONS"/*.sql "$STAGE/"
  chmod 644 "$STAGE"/*.sql
  SQL_DIR="$STAGE"
  trap 'rm -rf "$STAGE"' EXIT
else
  RUN=(bash -c)
  SQL_DIR="$HERE"
fi

run_sql() {
  "${RUN[@]}" "psql -q -v ON_ERROR_STOP=1 -d $DB_NAME -f $1"
}

echo "==> Recreating $DB_NAME"
"${RUN[@]}" "dropdb --if-exists $DB_NAME" >/dev/null 2>&1 || true
"${RUN[@]}" "createdb $DB_NAME"

echo "==> Loading Supabase stubs"
run_sql "$SQL_DIR/00_supabase_mock.sql"

echo "==> Applying migrations"
for f in "$MIGRATIONS"/*.sql; do
  base="$(basename "$f")"
  echo "    $base"
  run_sql "$SQL_DIR/$base"
done

echo "==> Running RLS assertions"
"${RUN[@]}" "psql -v ON_ERROR_STOP=1 -d $DB_NAME -f $SQL_DIR/01_rls_test.sql" 2>&1 \
  | grep -E "(NOTICE|^==|ERROR|FAIL|PASSED)" \
  | sed -e 's/^psql:[^ ]* //' -e 's/NOTICE:  //'

echo "==> Dropping $DB_NAME"
"${RUN[@]}" "dropdb --if-exists $DB_NAME" >/dev/null 2>&1 || true
