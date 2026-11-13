#!/usr/bin/env bash
# Usage: ./run_tests.sh [dbname]  -> SQL integrity/RBAC tests + concurrency test
set -euo pipefail
DB="${1:-mhportal}"
psql -d "$DB" -v ON_ERROR_STOP=1 -f tests/test_integrity_rbac.sql 2>&1 | grep -E "PASS|FAIL|ERROR|ALL TESTS"
DATABASE_URL="dbname=$DB" python3 tests/test_concurrency.py
