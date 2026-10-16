Set-Location $PSScriptRoot
docker info *> $null
if ($LASTEXITCODE -ne 0) {
  Write-Host 'Starting Docker Desktop...'
  Start-Process 'C:\Program Files\Docker\Docker\Docker Desktop.exe'
  do { Start-Sleep 3; docker info *> $null } until ($LASTEXITCODE -eq 0)
}
docker compose up -d db
Write-Host 'Waiting for the database...'
do { Start-Sleep 2; docker compose exec -T db pg_isready -U postgres *> $null } until ($LASTEXITCODE -eq 0)
Start-Process powershell -ArgumentList '-NoExit', '-Command', "cd '$PSScriptRoot'; pnpm dev:api"
Start-Process powershell -ArgumentList '-NoExit', '-Command', "cd '$PSScriptRoot'; pnpm dev:web"
Start-Sleep 8
Start-Process 'http://localhost:5173'
Write-Host 'Axel is running. Use .\stop.ps1 to stop.'
