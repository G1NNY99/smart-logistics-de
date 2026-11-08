# Run from project root on Windows PowerShell 5.1 / PowerShell 7.
# Integration test for db -> etl -> mart -> ml. NEVER removes postgres_data.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$required = @('.\compose.yaml', '.\docker\mart-run.sh', '.\ml\train_and_score.py', '.\tests\11_ml_assertions.sql')
foreach ($path in $required) {
    if (-not (Test-Path $path)) { throw "Missing $path. Run from smart-logistics-de root after extracting step 6.2." }
}

function Invoke-Docker {
    param([string[]] $CommandArgs)
    & docker @CommandArgs
    if ($LASTEXITCODE -ne 0) {
        throw ('Docker command failed: docker ' + ($CommandArgs -join ' '))
    }
}

function Get-ServiceId {
    param([string] $Name)
    $result = & docker compose ps --all --quiet $Name
    if ($LASTEXITCODE -ne 0) { throw "Cannot inspect $Name container" }
    $id = ($result | Out-String).Trim()
    if (-not $id) { throw "Container for service $Name not found" }
    return $id
}

Write-Host '[1/6] Validating Docker Compose configuration...'
Invoke-Docker -CommandArgs @('compose', 'config', '--quiet')

Write-Host '[2/6] Running complete stack with fresh job containers (no volume deletion)...'
# --force-recreate ensures ETL/DWH/ML run again even when previous job containers exited 0.
# PostgreSQL's named data volume is preserved, even if its container is recreated.
Invoke-Docker -CommandArgs @('compose', 'up', '--build', '--force-recreate', '--detach')

Write-Host '[3/6] Waiting for the ML job and verifying successful upstream jobs...'
$mlId = Get-ServiceId 'ml'
$mlExit = (& docker wait $mlId | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $mlExit -ne '0') {
    & docker compose logs --tail=70 etl mart ml
    throw "ML job did not finish successfully: exit=$mlExit"
}
foreach ($name in @('etl', 'mart', 'ml')) {
    $id = Get-ServiceId $name
    $state = (& docker inspect --format '{{.State.Status}}|{{.State.ExitCode}}' $id | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $state -ne 'exited|0') {
        & docker compose logs --tail=70 etl mart ml
        throw "Service $name failed (state=$state)"
    }
}
$dbId = Get-ServiceId 'db'
$dbHealth = (& docker inspect --format '{{.State.Health.Status}}' $dbId | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $dbHealth -ne 'healthy') {
    throw "Database is not healthy after ML: status=$dbHealth"
}
Write-Host '[PASS] db (healthy) -> ETL (exit 0) -> mart (exit 0) -> ML (exit 0).'

Write-Host '[4/6] Verifying database counts and future-target masking...'
$sql = @'
SELECT
  (SELECT count(*) FROM public.prices),
  (SELECT count(*) FROM core.prices),
  (SELECT count(*) FROM core.dq_quarantine_prices),
  (SELECT count(*) FROM mart.market_observations),
  (SELECT count(*) FROM mart.market_corridor),
  (SELECT count(*) FROM mart.ml_price_predictions WHERE dataset_split = 'test'),
  (SELECT count(*) FROM mart.ml_price_predictions WHERE dataset_split = 'future'),
  (SELECT count(*) FROM mart.ml_price_predictions WHERE dataset_split = 'future'
     AND (actual_price_rub IS NOT NULL OR abs_error_rub IS NOT NULL OR ape_pct IS NOT NULL)),
  (SELECT status FROM core.etl_runs ORDER BY run_id DESC LIMIT 1),
  (SELECT model_name FROM mart.ml_model_runs ORDER BY run_id DESC LIMIT 1);
'@
$rows = & docker compose exec -T db psql -X -U logistics -d deals_bigdata -v ON_ERROR_STOP=1 -A -t -c $sql
if ($LASTEXITCODE -ne 0) { throw 'Database verification SQL failed' }
$summary = ($rows | Where-Object { $_ -match '^\d+\|\d+\|\d+\|\d+\|\d+\|\d+\|\d+\|\d+\|success\|catboost_v1$' } | Select-Object -Last 1)
if (-not $summary) { throw ('Unexpected summary: ' + ($rows -join "`n")) }
$v = $summary.Trim().Split('|')
$source = [long]$v[0]
$core = [long]$v[1]
$quarantine = [long]$v[2]
$observations = [long]$v[3]
$corridor = [long]$v[4]
$test = [long]$v[5]
$future = [long]$v[6]
$leaked = [long]$v[7]
if ($source -ne 300000 -or ($core + $quarantine) -ne $source -or
    $observations -le 0 -or $corridor -le 0 -or $test -le 0 -or $future -le 0 -or $leaked -ne 0) {
    throw "Pipeline data validation failed: $summary"
}
Write-Host "[PASS] source=$source core=$core quarantine=$quarantine observations=$observations corridor=$corridor test=$test future=$future leaked_future=$leaked"

Write-Host '[5/6] Running ML regression assertions and checking output artifacts...'
Invoke-Docker -CommandArgs @('compose', 'cp', '.\tests\11_ml_assertions.sql', 'db:/tmp/11_ml_assertions.sql')
Invoke-Docker -CommandArgs @('compose', 'exec', '-T', 'db', 'psql', '-X', '-U', 'logistics', '-d', 'deals_bigdata', '-v', 'ON_ERROR_STOP=1', '-f', '/tmp/11_ml_assertions.sql')
if (-not (Test-Path '.\artifacts\catboost_v1.cbm') -or -not (Test-Path '.\artifacts\ml_metrics.json')) {
    throw 'Missing model/metrics artifacts after the ML service finished.'
}
Write-Host '[PASS] ML predictions, splits, metrics and local model artifacts verified.'

Write-Host '[6/6] Final statuses and last pipeline logs...'
Invoke-Docker -CommandArgs @('compose', 'ps', '--all')
Invoke-Docker -CommandArgs @('compose', 'logs', '--tail=15', 'etl', 'mart', 'ml')
Write-Host '[PASS] Full Docker Compose pipeline db -> ETL -> DWH -> ML completed successfully.'
