# Fresh machine setup: Docker Desktop, Node 20+ and pnpm must be installed.
Set-Location $PSScriptRoot
if (-not (Test-Path .env)) { Copy-Item .env.example .env; Write-Host 'Created .env from .env.example' }
docker info *> $null
if ($LASTEXITCODE -ne 0) {
  Write-Host 'Starting Docker Desktop...'
  Start-Process 'C:\Program Files\Docker\Docker\Docker Desktop.exe'
  do { Start-Sleep 3; docker info *> $null } until ($LASTEXITCODE -eq 0)
}
docker compose up -d db
Write-Host 'Waiting for the database to finish its first-time setup...'
do { Start-Sleep 3; $ok = docker compose exec -T db psql -U postgres -d axel -tAc "select 1 from pg_roles where rolname='axel_app'" 2>$null } until ("$ok" -match '1')
Start-Sleep 3
pnpm install
pnpm migrate
if (Test-Path backups/axel-demo.dump) { .\restore.ps1 } else { pnpm seed }
.\start.ps1
