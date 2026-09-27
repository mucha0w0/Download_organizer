#Requires -Version 5.1
<#
.SYNOPSIS
  Undo the last N successful Downloads sorter moves using the journal JSONL.
  Never overwrites existing files (timestamp suffix). Never deletes.
#>
[CmdletBinding()]
param(
    [int]$Count = 1
)

$ErrorActionPreference = 'Continue'
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $ScriptDir 'config.json'

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Write-Error "config.json not found: $ConfigPath"
    exit 1
}

$cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$WatchPath = [string]$cfg.watchPath
$LogPath = [string]$cfg.logPath
$JournalPath = [string]$cfg.journalPath

function Write-UndoLog {
    param([string]$Message)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] UNDO $Message"
    try {
        $logDir = Split-Path -Parent $LogPath
        if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    } catch {}
    Write-Host $line
}

function Get-UniqueDest {
    param([string]$DestDir, [string]$FileName)
    $dest = Join-Path $DestDir $FileName
    if (-not (Test-Path -LiteralPath $dest)) { return $dest }
    $base = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    $ext  = [System.IO.Path]::GetExtension($FileName)
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $candidate = Join-Path $DestDir ("{0}_{1}{2}" -f $base, $stamp, $ext)
    $n = 1
    while (Test-Path -LiteralPath $candidate) {
        $candidate = Join-Path $DestDir ("{0}_{1}_{2}{3}" -f $base, $stamp, $n, $ext)
        $n++
    }
    return $candidate
}

if ($Count -lt 1) { Write-Error 'Count must be >= 1'; exit 1 }

if (-not (Test-Path -LiteralPath $JournalPath)) {
    Write-Host "No journal found: $JournalPath"
    exit 0
}

$allLines = @(Get-Content -LiteralPath $JournalPath -Encoding UTF8)
$lines = @($allLines | Where-Object {
    $t = $_.Trim()
    ($t.StartsWith('{')) -and ($t.EndsWith('}'))
})
if ($lines.Count -eq 0) {
    Write-Host 'Journal has no valid entries — nothing to undo.'
    exit 0
}

$take = [Math]::Min($Count, $lines.Count)
$toUndo = @($lines[($lines.Count - $take)..($lines.Count - 1)])
[array]::Reverse($toUndo)

$undone = 0
$undoneLines = New-Object System.Collections.Generic.List[string]
foreach ($line in $toUndo) {
    try {
        $e = $line | ConvertFrom-Json
    } catch {
        Write-UndoLog "SKIP bad journal line"
        continue
    }
    $from = [string]$e.from
    $to   = [string]$e.to
    $name = [string]$e.name
    $cat  = [string]$e.category

    if (-not (Test-Path -LiteralPath $to)) {
        Write-UndoLog "SKIP missing current file: $to"
        $undoneLines.Add($line)
        continue
    }

    $restoreDir = $WatchPath
    if ($from) {
        $origDir = [System.IO.Path]::GetDirectoryName($from)
        if ($origDir -and (Test-Path -LiteralPath $origDir)) {
            $restoreDir = $origDir
        }
    }
    $leaf = if ($name) { $name } else { Split-Path -Leaf $to }
    $dest = Get-UniqueDest -DestDir $restoreDir -FileName $leaf
    try {
        Move-Item -LiteralPath $to -Destination $dest -ErrorAction Stop
        Write-UndoLog "restored: $cat\$leaf -> $(Split-Path -Leaf $dest)"
        $undone++
        $undoneLines.Add($line)
    } catch {
        $errMsg = $_.Exception.Message
        Write-UndoLog "ERROR restoring $to : $errMsg"
    }
}

# Rewrite journal without successfully-undone lines (keep remaining valid + any non-JSON noise cleared)
$keep = New-Object System.Collections.Generic.List[string]
foreach ($l in $lines) {
    $remove = $false
    foreach ($u in $undoneLines) {
        if ($l -eq $u) { $remove = $true; break }
    }
    if (-not $remove) { $keep.Add($l) }
}
$utf8 = New-Object System.Text.UTF8Encoding $false
if ($keep.Count -gt 0) {
    [System.IO.File]::WriteAllLines($JournalPath, $keep.ToArray(), $utf8)
} else {
    [System.IO.File]::WriteAllText($JournalPath, '', $utf8)
}

Write-Host "Undone: $undone / $take"