# Static repository readiness check; no Git push, writes, or Docker changes.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Push-Location $repo
try {
    foreach ($p in @(
        'README.md','.gitignore','.dockerignore','.env.example',
        'compose.yaml','docker-compose.yml',
        'etl\run.py','ml\features.py','ml\train_and_score.py',
        'docker\etl.Dockerfile','docker\ml.Dockerfile',
        'sql\01_core.sql','sql\09_mart_ddl.sql','sql\11_ml_predictions.sql',
        'task\README.md','task\sql\schema.sql','task\sql\synthetic.sql',
        'tests\verify_cleanroom.ps1','tests\verify_full_pipeline.ps1')) {
        if (-not (Test-Path -LiteralPath $p)) { throw "Required repository file missing: $p" }
    }
    Write-Host '[PASS] Required project files and root README are present'

    $hash1 = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $repo 'compose.yaml')).Hash
    $hash2 = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $repo 'docker-compose.yml')).Hash
    if ($hash1 -ne $hash2) { throw 'compose.yaml and docker-compose.yml differ; keep them identical.' }
    Write-Host '[PASS] Both Compose filenames have identical content'

    # Clean-room one-command requirement: no mandatory .env file.
    $composeText = [System.IO.File]::ReadAllText((Join-Path $repo 'compose.yaml'))
    $fallback = '${POSTGRES_PASSWORD:-smart_logistics_demo_only}'
    if ([regex]::Matches($composeText, [regex]::Escape($fallback)).Count -ne 4) {
        throw 'One-command default POSTGRES_PASSWORD must be used in db, etl, mart and ml.'
    }
    Write-Host '[PASS] Compose has a consistent local demo fallback for no-env first run' 

    $gitignore = [System.IO.File]::ReadAllText((Join-Path $repo '.gitignore'))
    $dockerignore = [System.IO.File]::ReadAllText((Join-Path $repo '.dockerignore'))
    if ($gitignore -notmatch '(?m)^\.env$' -or $gitignore -notmatch '(?m)^artifacts/$' -or
        $dockerignore -notmatch '(?m)^\.env$' -or $dockerignore -notmatch '(?m)^artifacts/$') {
        throw 'Missing .env or artifacts/ ignore patterns.'
    }
    Write-Host '[PASS] Local secrets and artifacts excluded from Git and Docker build context'

    if (Test-Path -LiteralPath '.git') {
        $tracked = @(& git ls-files --cached)
        if ($LASTEXITCODE -ne 0) { throw 'git ls-files failed' }
        $unsafe = @($tracked | Where-Object {
            ($_ -eq '.env') -or ($_ -like 'artifacts/*') -or
            ($_ -like 'DE_personal_registry/*') -or ($_ -match '(^|/)\.venv/')
        })
        if ($unsafe.Count -gt 0) { throw ('Unsafe tracked paths: ' + ($unsafe -join ', ')) }
        Write-Host '[PASS] No known secrets/personal registries in Git index'
    } else {
        Write-Host '[INFO] Git repository not initialized yet; index verification will be repeated before push.'
    }
    Write-Host '[PASS] Static repository preflight completed.'
}
finally { Pop-Location }
