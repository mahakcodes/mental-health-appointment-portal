#!/usr/bin/env bash
# Usage: ./run_all.sh [dbname]   (needs psql; connection via PG* env vars)
set -euo pipefail
DB="${1:-mhportal}"
for f in sql/01_schema.sql sql/02_logic.sql sql/03_security.sql sql/04_seed.sql; do
  echo ">> $f"; psql -d "$DB" -v ON_ERROR_STOP=1 -q -f "$f"
done
echo "Database '$DB' ready."
