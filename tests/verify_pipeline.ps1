# From project root: powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify_pipeline.ps1
# Integrates the existing Core + DWH: no database volumes are removed.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Test-Path -Path '.\compose.yaml') -or -not (Test-Path -Path '.\docker\mart-run.sh')) {
    throw 'Run from the smart-logistics-de root after extracting step 5.2.'
}

function Invoke-Docker {
    param([string[]] $CommandArgs)
    & docker @CommandArgs
    if ($LASTEXITCODE -ne 0) {
        throw ('Docker command failed: docker ' + ($CommandArgs -join ' '))
    }
}

Write-Host '[1/5] Checking Docker Compose configuration...'
Invoke-Docker -CommandArgs @('compose', 'config', '--quiet')

Write-Host '[2/5] Running one command for db -> ETL -> mart...'
Invoke-Docker -CommandArgs @('compose', 'up', '--build', '--detach')

Write-Host '[3/5] Waiting for mart job to exit...'
$martId = (& docker compose ps -a -q mart | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or -not $martId) {
    throw 'Mart service was not created. Run: docker compose logs etl mart'
}
$martExit = (& docker wait $martId | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $martExit -ne '0') {
    & docker compose logs --tail=70 etl mart
    throw "Mart failed or was interrupted: exit_code=$martExit"
}

$etlId = (& docker compose ps -a -q etl | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or -not $etlId) { throw 'ETL container not found' }
$etlStatus = (& docker inspect -f '{{.State.Status}}|{{.State.ExitCode}}' $etlId | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $etlStatus -ne 'exited|0') {
    throw "ETL did not finish successfully: $etlStatus"
}
Write-Host '[PASS] db -> ETL (exit 0) -> mart (exit 0).'

Write-Host '[4/5] Checking database counts and ETL audit...'
$sql = @'
SELECT (SELECT count(*) FROM public.prices),
       (SELECT count(*) FROM core.prices),
       (SELECT count(*) FROM core.dq_quarantine_prices),
       (SELECT count(*) FROM mart.market_observations),
       (SELECT count(*) FROM mart.market_corridor),
       (SELECT status FROM core.etl_runs ORDER BY run_id DESC LIMIT 1);
'@
$rows = & docker compose exec -T db psql -X -U logistics -d deals_bigdata -v ON_ERROR_STOP=1 -A -t -c $sql
if ($LASTEXITCODE -ne 0) { throw 'Database verification query failed' }
$summary = ($rows | Where-Object { $_ -match '^\d+\|\d+\|\d+\|\d+\|\d+\|success$' } | Select-Object -Last 1)
if (-not $summary) { throw ('Unexpected database verification output: ' + ($rows -join "`n")) }
$values = $summary.Split('|')
$source = [long]$values[0]
$core = [long]$values[1]
$quarantine = [long]$values[2]
$observations = [long]$values[3]
$corridor = [long]$values[4]
if ($source -ne ($core + $quarantine) -or $observations -le 0 -or $corridor -le 0) {
    throw "Data completeness failed: $summary"
}
Write-Host "[PASS] source=$source core=$core quarantine=$quarantine observations=$observations corridor=$corridor latest_etl=success"

Write-Host '[5/5] Container statuses and pipeline logs...'
Invoke-Docker -CommandArgs @('compose', 'ps', '-a')
Invoke-Docker -CommandArgs @('compose', 'logs', '--tail=15', 'etl', 'mart')
Write-Host '[PASS] Compose pipeline integration completed successfully.'
