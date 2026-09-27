# Launches Watch-Downloads.ps1 in a hidden separate process
$script = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'Watch-Downloads.ps1'
Start-Process -FilePath 'powershell.exe' -ArgumentList @(
    '-NoProfile',
    '-WindowStyle', 'Hidden',
    '-ExecutionPolicy', 'Bypass',
    '-File', $script
) -WindowStyle Hidden
Write-Host "Started watcher: $script"