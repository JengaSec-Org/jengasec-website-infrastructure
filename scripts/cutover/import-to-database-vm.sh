#!/bin/bash
# Load a Neon export into jengasec_web on the DATABASE VM, and prove it is complete.
#
#     sudo bash import-to-database-vm.sh jengasec-neon-20261020-1800.sql
#     sudo bash import-to-database-vm.sh jengasec-neon-20261020-1800.sql --replace
#
# Expects the .counts and .sha256 files made by export-from-neon.ps1 next to
# the .sql file. Steps:
#
#   1. checksum — the file is exactly what left the laptop
#   2. refuses to overwrite a database that already has tables, unless
#      --replace (which drops and recreates jengasec_web — and NOTHING else)
#   3. loads it in ONE transaction: it either all goes in or none of it does
#   4. compares every table's row count with the export's; any difference is
#      reported and the script exits non-zero
#
# Run setup-database-vm.sh once before the first import.

set -euo pipefail

DB=jengasec_web
ROLE=jengasec_web

say()  { echo -e "\033[1m==>\033[0m $*"; }
die()  { echo -e "\033[31mERROR:\033[0m $*" >&2; exit 1; }
pg()   { sudo -u postgres psql -XAtq -v ON_ERROR_STOP=1 "$@"; }

[ "$(id -u)" -eq 0 ] || die "Run with sudo: sudo bash $0 <file.sql>"
SQL_FILE="${1:-}"
[ -n "$SQL_FILE" ] && [ -f "$SQL_FILE" ] || die "Usage: sudo bash $0 <jengasec-neon-....sql> [--replace]"
REPLACE=false
[ "${2:-}" = "--replace" ] && REPLACE=true

BASE="${SQL_FILE%.sql}"
COUNTS="$BASE.counts"
SUMS="$BASE.sha256"
[ -f "$COUNTS" ] || die "Missing $COUNTS — copy all three export files."
[ -f "$SUMS" ]   || die "Missing $SUMS — copy all three export files."

[ -n "$(pg -c "SELECT 1 FROM pg_roles WHERE rolname = '$ROLE'")" ] || \
    die "Role $ROLE does not exist. Run setup-database-vm.sh first."

# ── 1. Checksum ─────────────────────────────────────────────────────────────
say "Checking the file arrived intact"
( cd "$(dirname "$SQL_FILE")" && tr -d '\r' < "$(basename "$SUMS")" | sha256sum -c --quiet - ) \
    || die "Checksum mismatch — the file was damaged or changed in transit. Copy it again."

# ── 2. Target database ──────────────────────────────────────────────────────
exists=$(pg -c "SELECT 1 FROM pg_database WHERE datname = '$DB'")
if [ -n "$exists" ]; then
    tables=$(pg -d "$DB" -c "SELECT count(*) FROM pg_tables WHERE schemaname = 'public'")
    if [ "$tables" -gt 0 ]; then
        $REPLACE || die "$DB already has $tables tables. If the website is NOT yet using it, rerun with --replace.
       If the website IS using it, stop: replacing it would throw away everything written since."
        say "Dropping and recreating $DB (--replace)"
        pg -c "DROP DATABASE $DB WITH (FORCE)"
        exists=""
    fi
fi
[ -n "$exists" ] || pg -c "CREATE DATABASE $DB OWNER $ROLE"

# ── 3. Load ─────────────────────────────────────────────────────────────────
# Everything is created AS jengasec_web, so the website owns its tables.
# Lines removed on the way in:
#   Windows line endings (\r)                       — a dump's data escapes a real
#                                                     carriage return as \r, so only
#                                                     line endings are touched
#   CREATE SCHEMA public / COMMENT ON SCHEMA public  — the new database has it
#   SET transaction_timeout                         — pg_dump 17+, older servers reject it
#   \restrict / \unrestrict                         — newest pg_dump; older psql rejects them
say "Loading $(basename "$SQL_FILE") into $DB (one transaction)"
started=$(date +%s)
sed -e 's/\r$//' \
    -e '/^CREATE SCHEMA public;$/d' \
    -e '/^COMMENT ON SCHEMA public /d' \
    -e '/^SET transaction_timeout/d' \
    -e '/^\\restrict /d' -e '/^\\unrestrict /d' \
    "$SQL_FILE" \
  | { echo "SET ROLE $ROLE;"; cat; } \
  | sudo -u postgres psql -X -q -v ON_ERROR_STOP=1 --single-transaction -d "$DB" >/dev/null \
  || die "The load failed and was rolled back — $DB is empty, nothing half-loaded. The error is above."
say "Loaded in $(( $(date +%s) - started ))s"

pg -d "$DB" -c "ANALYZE" >/dev/null

# ── 4. Verify ───────────────────────────────────────────────────────────────
say "Comparing row counts with the export"
COUNT_SQL="SELECT table_name || ',' || (xpath('/row/c/text()',
             query_to_xml(format('SELECT count(*) AS c FROM public.%I', table_name), false, true, '')))[1]::text
           FROM information_schema.tables
           WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
           ORDER BY table_name"

expected=$(tr -d '\r' < "$COUNTS" | sed '/^$/d' | sort)
actual=$(pg -d "$DB" -c "$COUNT_SQL" | sort)

if [ "$expected" = "$actual" ]; then
    n_tables=$(echo "$actual" | wc -l)
    n_rows=$(echo "$actual" | awk -F, '{s += $2} END {print s}')
    echo
    say "\033[32mVERIFIED\033[0m — $n_tables tables, $n_rows rows, every count matches the export."
else
    echo
    echo "Differences (< in the export, > in $DB):"
    diff <(echo "$expected") <(echo "$actual") || true
    die "Row counts do not match. Do not point the website at $DB until this is understood."
fi

echo
echo "  Next, on the WEBSITE VM: vault_jengasec_db_url points here (setup printed it),"
echo "  then:  make platform INVENTORY=inventories/v1 ANSIBLE_ARGS=\"-K -e @inventories/v1/vault.yml\""
echo
echo "  Then delete the export files — they hold every participant's personal data:"
echo "    shred -u $BASE.sql $COUNTS $SUMS"
