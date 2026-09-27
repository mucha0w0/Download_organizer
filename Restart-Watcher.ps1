#Requires -Version 5.1
$ErrorActionPreference = 'Continue'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
& (Join-Path $ScriptDir 'Stop-Watcher.ps1')
Start-Sleep -Seconds 1
& (Join-Path $ScriptDir 'Start-DownloadsWatcher.ps1')
Start-Sleep -Seconds 2
& (Join-Path $ScriptDir 'Check-Status.ps1')