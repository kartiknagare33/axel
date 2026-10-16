param([Parameter(Mandatory)][ValidateSet('live', 'test')][string]$Mode)
$p = Join-Path $PSScriptRoot '.env'
$lines = [System.IO.File]::ReadAllLines($p)
function Get-Val($k) { ($lines | Where-Object { $_ -match "^$k=" } | Select-Object -First 1) -replace "^$k=", '' }
$test = Get-Val 'MINIMOTH_TEST_KEY'
$live = Get-Val 'MINIMOTH_LIVE_KEY'
if (-not $test -or -not $live) { Write-Host 'Add MINIMOTH_TEST_KEY and MINIMOTH_LIVE_KEY to .env first.'; exit 1 }
$lines = @($lines | Where-Object { $_ -notmatch '^#?\s*MINIMOTH_API_KEY=' -and $_ -notmatch '^OTP_REQUIRED=' })
if ($Mode -eq 'live') { $lines += "MINIMOTH_API_KEY=$live"; $lines += 'OTP_REQUIRED=admins' }
else { $lines += "MINIMOTH_API_KEY=$test"; $lines += 'OTP_REQUIRED=all' }
[System.IO.File]::WriteAllLines($p, $lines, (New-Object System.Text.UTF8Encoding $false))
Write-Host "OTP mode set to $Mode. Restarting..."
& (Join-Path $PSScriptRoot 'stop.ps1')
& (Join-Path $PSScriptRoot 'start.ps1')
