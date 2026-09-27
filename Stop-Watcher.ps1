#Requires -Version 5.1
# Stop all DownloadsSorter watcher processes
$ErrorActionPreference = 'Continue'
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}

$procs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*Watch-Downloads*' }

if (-not $procs) {
    Write-Host 'No Watch-Downloads.ps1 process found.'
    exit 0
}

foreach ($p in $procs) {
    Write-Host "Stopping PID=$($p.ProcessId)"
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 1
$left = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*Watch-Downloads*' }
if ($left) {
    Write-Host 'WARNING: some processes still running:'
    $left | ForEach-Object { Write-Host "  PID=$($_.ProcessId)" }
    exit 1
}
Write-Host 'All watchers stopped.'