# Run from repository root in Windows PowerShell 5.1 / PowerShell 7.
# Does not touch source prices or delete postgres_data volume.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Test-Path '.\compose.yaml') -or -not (Test-Path '.\ml\train_and_score.py')) {
    throw 'Run from smart-logistics-de root after extracting step 6.1.'
}

function Invoke-Docker {
    param([string[]] $CommandArgs)
    & docker @CommandArgs
    if ($LASTEXITCODE -ne 0) {
        throw ('Docker command failed: docker ' + ($CommandArgs -join ' '))
    }
}

Write-Host '[1/7] Validating Compose config and building the ML image...'
Invoke-Docker -CommandArgs @('compose', 'config', '--quiet')
Invoke-Docker -CommandArgs @('compose', 'build', 'ml')

Write-Host '[2/7] Offline feature safety and date split unit tests...'
Invoke-Docker -CommandArgs @('compose', 'run', '--rm', 'ml', 'python', '-m', 'unittest', 'discover', '-s', 'tests', '-p', 'test_ml_features.py', '-v')

Write-Host '[3/7] Training CatBoost and scoring test/future cohorts...'
Invoke-Docker -CommandArgs @('compose', 'run', '--rm', 'ml')

Write-Host '[4/7] Running SQL checks against actual PostgreSQL data...'
Invoke-Docker -CommandArgs @('compose', 'cp', '.\tests\11_ml_assertions.sql', 'db:/tmp/11_ml_assertions.sql')
Invoke-Docker -CommandArgs @('compose', 'exec', '-T', 'db', 'psql', '-X', '-U', 'logistics', '-d', 'deals_bigdata', '-v', 'ON_ERROR_STOP=1', '-f', '/tmp/11_ml_assertions.sql')

Write-Host '[5/7] Taking business data fingerprint (excluding scored_at)...'
$signatureQuery = @'
SELECT count(*)::text || '|' || md5(COALESCE(string_agg(
    md5((to_jsonb(p) - 'scored_at')::text), '' ORDER BY price_id
), ''))
FROM mart.ml_price_predictions AS p;
'@
function Get-Fingerprint {
    $result = & docker compose exec -T db psql -X -U logistics -d deals_bigdata -v ON_ERROR_STOP=1 -A -t -c $signatureQuery
    if ($LASTEXITCODE -ne 0) { throw 'SQL fingerprint query failed' }
    $value = ($result | Where-Object { $_ -match '^\d+\|[a-f0-9]{32}$' } | Select-Object -Last 1)
    if (-not $value) { throw ('Unexpected fingerprint: ' + ($result -join "`n")) }
    return $value.Trim()
}
$before = Get-Fingerprint

Write-Host '[6/7] Re-training with same seed to test deterministic idempotence...'
Invoke-Docker -CommandArgs @('compose', 'run', '--rm', 'ml')
$after = Get-Fingerprint
if ($before -ne $after) {
    throw "ML business data changed on repeated run: before=$before after=$after"
}
Write-Host '[PASS] Re-run leaves all prediction business fields unchanged.'

Write-Host '[7/7] Rechecking the database and local artifacts...'
Invoke-Docker -CommandArgs @('compose', 'exec', '-T', 'db', 'psql', '-X', '-U', 'logistics', '-d', 'deals_bigdata', '-v', 'ON_ERROR_STOP=1', '-f', '/tmp/11_ml_assertions.sql')
if (-not (Test-Path '.\artifacts\catboost_v1.cbm') -or -not (Test-Path '.\artifacts\ml_metrics.json')) {
    throw 'Model or metrics file missing in artifacts/.'
}
Write-Host ('Snapshot: ' + $after)
Write-Host '[PASS] ML batch training, leakage checks, predictions, and rerun consistency.'
