# Execute from repository root: powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify_mart.ps1
# Copies SQL into the running PostgreSQL container; never changes the source data.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Test-Path -Path '.\compose.yaml')) {
    throw 'Run this script from the smart-logistics-de project root.'
}

function Invoke-Docker {
    param([string[]] $CommandArgs)
    & docker @CommandArgs
    if ($LASTEXITCODE -ne 0) {
        throw ('Docker command failed: docker ' + ($CommandArgs -join ' '))
    }
}

function Read-Snapshot {
    $output = & docker compose exec -T db psql -X -U logistics -d deals_bigdata -v ON_ERROR_STOP=1 -A -t -f /tmp/10_mart_snapshot.sql
    if ($LASTEXITCODE -ne 0) { throw 'Failed to compute DWH snapshot' }
    $value = ($output | Where-Object { $_ -match '^\d+\|[a-f0-9]{32}\|\d+\|[a-f0-9]{32}$' } | Select-Object -Last 1)
    if (-not $value) { throw ('Invalid DWH snapshot: ' + ($output -join "`n")) }
    return [string] $value
}

Write-Host '[1/5] Copying DWH SQL files into the existing PostgreSQL container...'
Invoke-Docker -CommandArgs @('compose','cp','./sql/09_mart_ddl.sql','db:/tmp/09_mart_ddl.sql')
Invoke-Docker -CommandArgs @('compose','cp','./sql/10_mart_refresh.sql','db:/tmp/10_mart_refresh.sql')
Invoke-Docker -CommandArgs @('compose','cp','./tests/09_mart_assertions.sql','db:/tmp/09_mart_assertions.sql')
Invoke-Docker -CommandArgs @('compose','cp','./tests/10_mart_snapshot.sql','db:/tmp/10_mart_snapshot.sql')

Write-Host '[2/5] Creating DWH materialized views and indexes...'
Invoke-Docker -CommandArgs @('compose','exec','-T','db','psql','-X','-U','logistics','-d','deals_bigdata','-v','ON_ERROR_STOP=1','-f','/tmp/09_mart_ddl.sql')

Write-Host '[3/5] Refreshing monthly market observations and corridor...'
Invoke-Docker -CommandArgs @('compose','exec','-T','db','psql','-X','-U','logistics','-d','deals_bigdata','-v','ON_ERROR_STOP=1','-f','/tmp/10_mart_refresh.sql')

Write-Host '[4/5] Checking business rules and a sample of route cards...'
Invoke-Docker -CommandArgs @('compose','exec','-T','db','psql','-X','-U','logistics','-d','deals_bigdata','-v','ON_ERROR_STOP=1','-f','/tmp/09_mart_assertions.sql')

Write-Host '[5/5] Refreshing once more and verifying idempotence of business data...'
$before = Read-Snapshot
Invoke-Docker -CommandArgs @('compose','exec','-T','db','psql','-X','-U','logistics','-d','deals_bigdata','-v','ON_ERROR_STOP=1','-f','/tmp/10_mart_refresh.sql')
$after = Read-Snapshot
if ($before -ne $after) {
    throw "DWH refresh changed the business snapshot.`nBefore: $before`nAfter:  $after"
}
Write-Host '[PASS] DWH market corridor rules, calendar comparisons and refresh idempotence.'
Write-Host "Snapshot: $after"
