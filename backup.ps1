Set-Location $PSScriptRoot
New-Item -ItemType Directory -Force -Path backups | Out-Null
docker compose exec -T db pg_dump -U postgres -d axel -Fc -f /tmp/axel.dump
docker compose cp db:/tmp/axel.dump backups/axel-demo.dump
Write-Host 'Saved backups/axel-demo.dump. Use .\restore.ps1 to go back to this exact state.'
