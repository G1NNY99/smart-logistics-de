#!/bin/sh
# Client-only DWH job. postgres:17 provides psql; the DB runs in service "db".
# NOTE: Store this script with LF line endings (the attached archive already does).
set -eu

printf '\n[MART] Ensuring DWH objects exist...\n'
psql -X -v ON_ERROR_STOP=1 -f /opt/pipeline/sql/09_mart_ddl.sql

printf '\n[MART] Refreshing observations, then market corridor...\n'
psql -X -v ON_ERROR_STOP=1 -f /opt/pipeline/sql/10_mart_refresh.sql

printf '\n[MART] MART_SUCCESS: views refreshed after ETL completed.\n'
