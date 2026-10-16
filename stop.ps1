Set-Location $PSScriptRoot
Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" |
  Where-Object { $_.CommandLine -like "*$PSScriptRoot*" } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
docker compose stop
Write-Host 'Axel stopped. Your data is kept.'
