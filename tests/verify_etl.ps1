# Regression check: source DQ, repeatability, and backfill scope.
# Run once from the repository root: .\tests\verify_etl.ps1
# Requires a working Docker Desktop and the existing project database.
# No volumes are removed, and raw/public source tables are not changed.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Push-Location $repoRoot
try {
    function Check-ExitCode([string]$operation) {
        if ($LASTEXITCODE -ne 0) {
            throw "$operation failed (exit code $LASTEXITCODE)"
        }
    }

    function Get-BusinessSnapshot {
        $lines = & docker compose exec -T db psql -X -U logistics -d deals_bigdata `
            -v ON_ERROR_STOP=1 -A -t -f /tmp/08_etl_snapshot.sql
        Check-ExitCode 'Business snapshot query'
        return ($lines | Out-String).Trim()
    }

    function Check-BusinessRules {
        & docker compose exec -T db psql -X -U logistics -d deals_bigdata `
            -v ON_ERROR_STOP=1 -f /tmp/07_etl_assertions.sql
        Check-ExitCode 'Business rule assertions'
    }

    Write-Host '[1/7] Copying read-only SQL checks into PostgreSQL container...'
    & docker compose cp './tests/07_etl_assertions.sql' 'db:/tmp/07_etl_assertions.sql'
    Check-ExitCode 'Copy assertion SQL'
    & docker compose cp './tests/08_etl_snapshot.sql' 'db:/tmp/08_etl_snapshot.sql'
    Check-ExitCode 'Copy snapshot SQL'

    Write-Host '[2/7] Checking current Core and quarantine...'
    Check-BusinessRules

    Write-Host '[3/7] Taking baseline fingerprint (business columns only)...'
    $before = Get-BusinessSnapshot
    Write-Host "BASELINE: $before"

    Write-Host '[4/7] Repeating the full ETL window...'
    & docker compose run --rm -e ETL_START_DATE=2023-01-01 -e ETL_END_DATE=2027-12-31 etl
    Check-ExitCode 'Full ETL rerun'
    $afterFull = Get-BusinessSnapshot
    if ($afterFull -cne $before) {
        Write-Host "AFTER FULL: $afterFull"
        throw 'Full ETL rerun changed the business snapshot (non-idempotent)'
    }
    Write-Host '[PASS] Full-window rerun preserves 100% of business data and counts.'

    Write-Host '[5/7] Running an overlapping 2026-10-01..2026-10-26 backfill...'
    & docker compose run --rm -e ETL_START_DATE=2026-10-01 -e ETL_END_DATE=2026-10-26 etl
    Check-ExitCode 'Partial ETL backfill'
    $afterBackfill = Get-BusinessSnapshot
    if ($afterBackfill -cne $before) {
        Write-Host "AFTER BACKFILL: $afterBackfill"
        throw 'Partial backfill changed the business snapshot'
    }
    Write-Host '[PASS] Backfill preserves whole dataset; no rows outside the window changed.'

    Write-Host '[6/7] Rechecking DQ, FX and category rules...'
    Check-BusinessRules

    Write-Host '[7/7] Latest ETL audit history...'
    & docker compose exec -T db psql -X -U logistics -d deals_bigdata -v ON_ERROR_STOP=1 `
        -c 'SELECT run_id, start_date, end_date, status, source_count, loaded_count, quarantine_count FROM core.etl_runs ORDER BY run_id DESC LIMIT 3;'
    Check-ExitCode 'ETL run audit'
    Write-Host '[PASS] ETL regression suite finished successfully.'
}
finally {
    Pop-Location
}
