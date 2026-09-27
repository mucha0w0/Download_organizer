#Requires -Version 5.1
$ErrorActionPreference = 'Continue'
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $ScriptDir 'config.json'
$log = $null
$journal = $null
if (Test-Path -LiteralPath $ConfigPath) {
    $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $log = [string]$cfg.logPath
    $journal = [string]$cfg.journalPath
    Write-Host "=== CONFIG ==="
    Write-Host "watchPath=$($cfg.watchPath)"
    Write-Host "rules=$($cfg.rules.Count) categories=$($cfg.categories.Count) toast=$($cfg.settings.toastEnabled)"
} else {
    Write-Host "=== CONFIG === MISSING"
}

Write-Host '=== PROCESSES ==='
$found = $false
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.CommandLine -like '*Watch-Downloads*' } |
  ForEach-Object {
    $found = $true
    Write-Host ("PID={0}" -f $_.ProcessId)
    Write-Host $_.CommandLine
  }
if (-not $found) { Write-Host 'NONE' }

Write-Host '=== LOG (tail 30) ==='
if ($log -and (Test-Path -LiteralPath $log)) {
  Get-Content -LiteralPath $log -Encoding UTF8 -Tail 30
} else {
  Write-Host 'NO_LOG'
}

Write-Host '=== JOURNAL (tail 5) ==='
if ($journal -and (Test-Path -LiteralPath $journal)) {
  Get-Content -LiteralPath $journal -Encoding UTF8 -Tail 5
} else {
  Write-Host 'NO_JOURNAL'
}

Write-Host '=== TASK ==='
try {
  $t = Get-ScheduledTask -TaskName 'DownloadsSorterWatcher' -ErrorAction Stop
  $i = Get-ScheduledTaskInfo -TaskName 'DownloadsSorterWatcher'
  $act = ($t.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join '; '
  Write-Host ("State={0} LastResult={1} LastRun={2}" -f $t.State, $i.LastTaskResult, $i.LastRunTime)
  Write-Host "Action=$act"
} catch {
  Write-Host $_.Exception.Message
}