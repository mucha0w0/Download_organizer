#Requires -Version 5.1
<#
.SYNOPSIS
  Install the Downloads sorter for the current Windows user.

.DESCRIPTION
  Copies this package to %USERPROFILE%\Scripts\DownloadsSorter, writes
  config.json from config.example.json using $env:USERPROFILE\Downloads,
  creates the category folders, registers a logon task, and starts the watcher.

  An existing config.json is left in place so custom rules survive a reinstall.
#>
[CmdletBinding()]
param(
    [string]$Destination
)

$ErrorActionPreference = 'Stop'

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}

if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
    throw 'USERPROFILE is not set.'
}
if ($env:USERPROFILE.IndexOf('"') -ge 0) {
    throw 'USERPROFILE contains a double quote and cannot be written into config.json.'
}

$SourceDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($Destination)) {
    $Destination = Join-Path $env:USERPROFILE 'Scripts\DownloadsSorter'
}

function Resolve-InstallPath {
    param([string]$Path)
    return ([System.IO.Path]::GetFullPath($Path)).TrimEnd('\', '/')
}

$srcFull = Resolve-InstallPath $SourceDir
$destFull = Resolve-InstallPath $Destination
$downloads = Join-Path $env:USERPROFILE 'Downloads'

New-Item -ItemType Directory -Path $destFull -Force | Out-Null
if (-not (Test-Path -LiteralPath $downloads)) {
    New-Item -ItemType Directory -Path $downloads -Force | Out-Null
}

$copyNames = @(
    'Watch-Downloads.ps1',
    'Start-DownloadsWatcher.ps1',
    'Start-DownloadsWatcher.cmd',
    'Stop-Watcher.ps1',
    'Restart-Watcher.ps1',
    'Check-Status.ps1',
    'Undo-Last.ps1',
    'Register-AutoStart.ps1',
    'Install.ps1',
    'config.example.json',
    'README.md',
    'LICENSE',
    '.gitignore'
)

if ([string]::Compare($srcFull, $destFull, $true) -ne 0) {
    foreach ($name in $copyNames) {
        $src = Join-Path $SourceDir $name
        if (-not (Test-Path -LiteralPath $src)) {
            throw "Missing install file: $src"
        }
        Copy-Item -LiteralPath $src -Destination (Join-Path $destFull $name) -Force
    }
    Write-Host "Copied scripts to $destFull"
} else {
    Write-Host "Already in $destFull. Skipping copy."
}

$examplePath = Join-Path $destFull 'config.example.json'
$configPath = Join-Path $destFull 'config.json'

if (Test-Path -LiteralPath $configPath) {
    Write-Host "Keeping existing config.json: $configPath"
} else {
    $raw = Get-Content -LiteralPath $examplePath -Raw -Encoding UTF8
    if ($raw -notmatch '%USERPROFILE%') {
        throw "config.example.json has no %USERPROFILE% placeholder: $examplePath"
    }
    $userJson = $env:USERPROFILE.Replace('\', '\\')
    $expanded = $raw.Replace('%USERPROFILE%', $userJson)
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($configPath, $expanded, $utf8)
    Write-Host "Wrote config.json for $downloads"
}

$cfg = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
$watch = [string]$cfg.watchPath
if ([string]::IsNullOrWhiteSpace($watch)) {
    throw 'config.json watchPath is empty.'
}
if ($watch -like '*%USERPROFILE%*') {
    throw "config.json still contains %USERPROFILE%. Edit watchPath, logPath, and journalPath."
}
if (-not (Test-Path -LiteralPath $watch)) {
    New-Item -ItemType Directory -Path $watch -Force | Out-Null
}

foreach ($c in @($cfg.categories)) {
    $folder = Join-Path $watch ([string]$c)
    if (-not (Test-Path -LiteralPath $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        Write-Host "Created category: $folder"
    }
}

Write-Host 'Registering logon autostart...'
& (Join-Path $destFull 'Register-AutoStart.ps1')
if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
    throw "Register-AutoStart.ps1 failed with exit code $LASTEXITCODE"
}

Write-Host 'Starting watcher...'
& (Join-Path $destFull 'Start-DownloadsWatcher.ps1')

Write-Host "Install complete: $destFull"
Write-Host "Downloads: $watch"
