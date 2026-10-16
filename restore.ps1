Set-Location $PSScriptRoot
if (-not (Test-Path backups/axel-demo.dump)) { Write-Host 'No backup found. Run .\backup.ps1 first.'; exit 1 }
Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" |
  Where-Object { $_.CommandLine -like "*$PSScriptRoot*" } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
docker compose up -d db
do { Start-Sleep 2; docker compose exec -T db pg_isready -U postgres *> $null } until ($LASTEXITCODE -eq 0)
docker compose cp backups/axel-demo.dump db:/tmp/axel.dump
docker compose exec -T db pg_restore -U postgres -d axel --clean --if-exists /tmp/axel.dump
Write-Host 'Restored the demo database. Now run .\start.ps1 and log in again.'
