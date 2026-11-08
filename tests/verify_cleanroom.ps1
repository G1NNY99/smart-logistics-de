# Full end-to-end test on a FRESH, separate Docker Compose project.
# Windows PowerShell 5.1+; run from any directory. Does NOT delete volumes.
# -WithoutEnv: test strict one-command bootstrap with no .env or POSTGRES_PASSWORD.
param([switch] $WithoutEnv)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-Docker {
    param([string[]] $CommandArgs)
    & docker @CommandArgs
    if ($LASTEXITCODE -ne 0) { throw ('Docker failed: docker ' + ($CommandArgs -join ' ')) }
}

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$envFile = Join-Path $repo '.env'
if (-not $WithoutEnv -and -not (Test-Path -LiteralPath $envFile)) {
    throw 'Missing .env for standard audit. Use -WithoutEnv to test default bootstrap.'
}
$sourceCompose = Join-Path $repo 'compose.yaml'
if (-not (Test-Path -LiteralPath $sourceCompose)) { throw 'compose.yaml is missing.' }

$stamp = Get-Date -Format 'yyyyMMddHHmmss'
$auditName = 'slogaudit' + $stamp
$auditRoot = Join-Path $env:TEMP ('smart-logistics-cleanroom-' + $stamp)
if (Test-Path -LiteralPath $auditRoot) { throw "Audit folder already exists: $auditRoot" }
New-Item -ItemType Directory -Path $auditRoot | Out-Null

# Copy ONLY source files; never copy the original data volume or ML artifacts.
foreach ($dirName in @('task', 'etl', 'ml', 'sql', 'docker', 'docs', 'tests')) {
    $src = Join-Path $repo $dirName
    if (-not (Test-Path -LiteralPath $src)) { throw "Missing source directory: $src" }
    Copy-Item -LiteralPath $src -Destination (Join-Path $auditRoot $dirName) -Recurse -Force
}
foreach ($fileName in @('compose.yaml', 'README.md', '.env.example', '.gitignore', '.dockerignore')) {
    $src = Join-Path $repo $fileName
    if (-not (Test-Path -LiteralPath $src)) { throw "Missing source file: $src" }
    Copy-Item -LiteralPath $src -Destination (Join-Path $auditRoot $fileName) -Force
}
# Standard audit reuses original .env (not copied); -WithoutEnv verifies bootstrap without it.

# Remove host port publication in THE TEMPORARY COPY ONLY. Network remains private.
$auditCompose = Join-Path $auditRoot 'compose.yaml'
$yaml = [System.IO.File]::ReadAllText($auditCompose)
$portPattern = '(?m)^    ports:\r?\n      - "127\.0\.0\.1:55432:5432"\r?\n'
if ([regex]::Matches($yaml, $portPattern).Count -ne 1) {
    throw 'Cannot safely identify the single PostgreSQL port binding in temporary Compose copy.'
}
$yaml = [regex]::Replace($yaml, $portPattern, '')
[System.IO.File]::WriteAllText($auditCompose, $yaml, [System.Text.UTF8Encoding]::new($false))

$composeArgs = @('compose', '-p', $auditName, '--project-directory', $auditRoot)
if (-not $WithoutEnv) { $composeArgs += @('--env-file', $envFile) }
$composeArgs += @('-f', $auditCompose)

# Environment variables can override Compose defaults. Clear only in THIS script's
# process for the no-env check, and restore in finally (original .env untouched).
$previousPassword = [Environment]::GetEnvironmentVariable('POSTGRES_PASSWORD', 'Process')
if ($WithoutEnv) { [Environment]::SetEnvironmentVariable('POSTGRES_PASSWORD', $null, 'Process') }
Write-Host "[INFO] Audit compose project: $auditName"
Write-Host "[INFO] Isolated audit source: $auditRoot"
Write-Host '[INFO] The original project, its port 55432 and its Docker volume remain unchanged.'

Push-Location $auditRoot
try {
    Write-Host '[1/6] Validating isolated Docker Compose configuration...'
    Invoke-Docker -CommandArgs ($composeArgs + @('config', '--quiet'))

    Write-Host '[2/6] Creating NEW PostgreSQL volume and running full stack from source...'
    Invoke-Docker -CommandArgs ($composeArgs + @('up', '--build', '--detach'))

    Write-Host '[3/6] Verifying ETL, DWH and ML one-shot exit codes...'
    $mlId = (& docker @composeArgs ps --all --quiet ml | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $mlId) { throw 'Audit ML container not found.' }
    $mlExit = (& docker wait $mlId | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $mlExit -ne '0') {
        & docker @composeArgs logs --tail=80 etl mart ml
        throw "Audit ML failed: exit=$mlExit"
    }
    foreach ($service in @('etl', 'mart', 'ml')) {
        $id = (& docker @composeArgs ps --all --quiet $service | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or -not $id) { throw "Audit service not found: $service" }
        $state = (& docker inspect --format '{{.State.Status}}|{{.State.ExitCode}}' $id | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or $state -ne 'exited|0') { throw "Audit $service state=$state" }
    }
    $dbId = (& docker @composeArgs ps --all --quiet db | Out-String).Trim()
    $health = (& docker inspect --format '{{.State.Health.Status}}' $dbId | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $health -ne 'healthy') { throw "Audit DB is not healthy: $health" }
    Write-Host '[PASS] Clean db -> ETL (exit 0) -> mart (exit 0) -> ML (exit 0)'

    Write-Host '[4/6] Checking new database, feature/business rules and exact cohort sizes...'
    foreach ($name in @('07_etl_assertions.sql', '09_mart_assertions.sql', '11_ml_assertions.sql', '12_cleanroom_assertions.sql')) {
        $srcPath = if ($name -eq '07_etl_assertions.sql') { '.\tests\07_etl_assertions.sql' } else { '.\tests\' + $name }
        Invoke-Docker -CommandArgs ($composeArgs + @('cp', $srcPath, ('db:/tmp/' + $name)))
        Invoke-Docker -CommandArgs ($composeArgs + @(
            'exec', '-T', 'db', 'psql', '-X', '-U', 'logistics', '-d', 'deals_bigdata',
            '-v', 'ON_ERROR_STOP=1', '-f', ('/tmp/' + $name)
        ))
    }
    Write-Host '[PASS] Data counts, DQ, DWH, ML and masking checked on fresh database'

    Write-Host '[5/6] Verifying isolated ML model and metrics files...'
    if (-not (Test-Path -LiteralPath (Join-Path $auditRoot 'artifacts\catboost_v1.cbm')) -or
        -not (Test-Path -LiteralPath (Join-Path $auditRoot 'artifacts\ml_metrics.json'))) {
        throw 'Clean-room model or metrics file is missing.'
    }
    Write-Host '[PASS] Isolated ML artifacts were produced'

    Write-Host '[6/6] Final status and summary...'
    Invoke-Docker -CommandArgs ($composeArgs + @('ps', '--all'))
    Write-Host '[PASS] CLEANROOM full stack initialized successfully from an EMPTY PostgreSQL volume.'
}
finally {
    Pop-Location
    if ($WithoutEnv) {
        [Environment]::SetEnvironmentVariable('POSTGRES_PASSWORD', $previousPassword, 'Process')
    }
    Write-Host "[INFO] Audit Compose project: $auditName"
    Write-Host "[INFO] Audit source directory: $auditRoot"
    Write-Host '[INFO] Audit resources were not removed automatically; original resources were not modified.'
}
