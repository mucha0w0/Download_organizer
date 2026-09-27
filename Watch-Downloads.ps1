#Requires -Version 5.1
<#
.SYNOPSIS
  Downloads sorter v2 — config-driven watcher.
  Watches Downloads root and sorts NEW top-level items into category folders.
  Never deletes files; optionally removes empty non-category folders at the Downloads root. Never overwrites (timestamp suffix on name conflict).
  Loads rules from config.json next to this script.
#>
[CmdletBinding()]
param(
    [switch]$Once
)

$ErrorActionPreference = 'Continue'
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $ScriptDir 'config.json'

# ---------- Config ----------
$script:Cfg = $null
$script:CfgMtime = $null
$script:WatchPath = $null
$script:LogPath = $null
$script:JournalPath = $null
$script:CategoryFolders = @()
$script:DefaultCategory = $null
$script:IgnorePrefixes = @('.', '_')
$script:IgnorePatterns = @()
$script:PartialExts = @()
$script:Rules = @()
$script:SettleMs = 700
$script:SizeStablePolls = 3
$script:SizeStableDelayMs = 1000
$script:MaxWaitSec = 180
$script:ToastEnabled = $false
$script:MutexName = 'Global\DownloadsSorterWatcher'
$script:BufferSize = 65536
$script:IdleReloadConfigMs = 5000
$script:RemoveEmptyFolders = $true
$script:EmptyFolderSweepIntervalSec = 30
$script:BurntToastAvailable = $null
$script:InFlight = @{}
$script:InFlightLock = New-Object object
$script:Mutex = $null

function Write-SortLog {
    param([string]$Message)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] $Message"
    try {
        $logDir = Split-Path -Parent $script:LogPath
        if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
    } catch {}
    try { Write-Host $line } catch {}
}

function Import-SorterConfig {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "config.json not found: $Path"
    }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $cfg = $raw | ConvertFrom-Json
    if (-not $cfg.watchPath) { throw 'config.watchPath missing' }
    if (-not $cfg.categories -or $cfg.categories.Count -eq 0) { throw 'config.categories missing' }

    $script:Cfg = $cfg
    $script:CfgMtime = (Get-Item -LiteralPath $Path).LastWriteTimeUtc
    $script:WatchPath = [string]$cfg.watchPath
    $script:LogPath = [string]$cfg.logPath
    $script:JournalPath = [string]$cfg.journalPath
    $script:CategoryFolders = @($cfg.categories | ForEach-Object { [string]$_ })
    $script:DefaultCategory = if ($cfg.defaultCategory) { [string]$cfg.defaultCategory } else { $script:CategoryFolders[-1] }

    $script:IgnorePrefixes = @()
    if ($cfg.ignore -and $cfg.ignore.namePrefixes) {
        $script:IgnorePrefixes = @($cfg.ignore.namePrefixes | ForEach-Object { [string]$_ })
    }
    $script:IgnorePatterns = @()
    if ($cfg.ignore -and $cfg.ignore.namePatterns) {
        $script:IgnorePatterns = @($cfg.ignore.namePatterns | ForEach-Object { [string]$_ })
    }
    $script:PartialExts = @()
    if ($cfg.ignore -and $cfg.ignore.partialExtensions) {
        $script:PartialExts = @($cfg.ignore.partialExtensions | ForEach-Object { ([string]$_).ToLowerInvariant() })
    }

    $script:Rules = @()
    if ($cfg.rules) {
        foreach ($r in $cfg.rules) {
            $script:Rules += [pscustomobject]@{
                Match      = [string]$r.match
                Values     = @($r.values | ForEach-Object { [string]$_ })
                Category   = [string]$r.category
                DirsOnly   = [bool]($r.dirsOnly)
                FilesOnly  = [bool]($r.filesOnly)
            }
        }
    }

    # Defaults are reset on every load so hot reloads cannot retain stale values.
    $script:RemoveEmptyFolders = $true
    $script:EmptyFolderSweepIntervalSec = 30
    $s = $cfg.settings
    if ($s) {
        if ($null -ne $s.settleMs) { $script:SettleMs = [int]$s.settleMs }
        if ($null -ne $s.sizeStablePolls) { $script:SizeStablePolls = [int]$s.sizeStablePolls }
        if ($null -ne $s.sizeStableDelayMs) { $script:SizeStableDelayMs = [int]$s.sizeStableDelayMs }
        if ($null -ne $s.maxWaitSec) { $script:MaxWaitSec = [int]$s.maxWaitSec }
        if ($null -ne $s.toastEnabled) { $script:ToastEnabled = [bool]$s.toastEnabled }
        if ($s.singleInstanceMutex) { $script:MutexName = [string]$s.singleInstanceMutex }
        if ($null -ne $s.bufferSize) { $script:BufferSize = [int]$s.bufferSize }
        if ($null -ne $s.idleReloadConfigMs) { $script:IdleReloadConfigMs = [int]$s.idleReloadConfigMs }
        if ($null -ne $s.removeEmptyFolders) { $script:RemoveEmptyFolders = [bool]$s.removeEmptyFolders }
        if ($null -ne $s.emptyFolderSweepIntervalSec) { $script:EmptyFolderSweepIntervalSec = [int]$s.emptyFolderSweepIntervalSec }
    }
}

function Test-ConfigChanged {
    try {
        if (-not (Test-Path -LiteralPath $ConfigPath)) { return $false }
        $mt = (Get-Item -LiteralPath $ConfigPath).LastWriteTimeUtc
        return ($mt -ne $script:CfgMtime)
    } catch {
        return $false
    }
}

function Ensure-CategoryFolders {
    foreach ($c in $script:CategoryFolders) {
        $p = Join-Path $script:WatchPath $c
        if (-not (Test-Path -LiteralPath $p)) {
            New-Item -ItemType Directory -Path $p -Force | Out-Null
            Write-SortLog "Created category folder: $c"
        }
    }
}

function Test-IsIgnoredName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $true }
    foreach ($pfx in $script:IgnorePrefixes) {
        if ($Name.StartsWith($pfx)) { return $true }
    }
    foreach ($pat in $script:IgnorePatterns) {
        if ($Name -like $pat) { return $true }
    }
    $ext = [System.IO.Path]::GetExtension($Name).ToLowerInvariant()
    if ($script:PartialExts -contains $ext) { return $true }
    return $false
}

function Test-IsCategoryFolder {
    param([string]$Name)
    return ($script:CategoryFolders -contains $Name)
}

function Remove-EmptyNonCategoryFolders {
    if (-not $script:RemoveEmptyFolders) { return }
    if (-not (Test-Path -LiteralPath $script:WatchPath -PathType Container)) { return }

    try {
        # Deliberately enumerate only the Downloads root; never recurse into categories.
        Get-ChildItem -LiteralPath $script:WatchPath -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
            $dir = $_
            $name = $dir.Name
            if (Test-IsCategoryFolder $name) { return }
            if (Test-IsIgnoredName $name) { return }
            if (($dir.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return }

            try {
                # No -Recurse: a directory is removable only when it has no children.
                $children = @(Get-ChildItem -LiteralPath $dir.FullName -Force -ErrorAction Stop)
                if ($children.Count -ne 0) { return }
                Remove-Item -LiteralPath $dir.FullName -Force -ErrorAction Stop
                Write-SortLog "REMOVED_EMPTY_DIR: $name"
            } catch {
                # A file or subdirectory may have appeared between the check and removal.
                # Leave it in place and continue safely.
            }
        }
    } catch {
        Write-SortLog "WARN empty-folder cleanup failed: $($_.Exception.Message)"
    }
}

function Test-SizeStable {
    param([string]$FullPath)
    $Polls = $script:SizeStablePolls
    $DelayMs = $script:SizeStableDelayMs
    $MaxWaitSec = $script:MaxWaitSec
    $deadline = (Get-Date).AddSeconds($MaxWaitSec)
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-Path -LiteralPath $FullPath)) { return $false }
        try {
            $item = Get-Item -LiteralPath $FullPath -Force -ErrorAction Stop
        } catch {
            return $false
        }
        if ($item.PSIsContainer) { return $true }

        $sizes = New-Object System.Collections.Generic.List[long]
        for ($i = 0; $i -lt $Polls; $i++) {
            Start-Sleep -Milliseconds $DelayMs
            if (-not (Test-Path -LiteralPath $FullPath)) { return $false }
            try {
                $sizes.Add( ([long](Get-Item -LiteralPath $FullPath -Force).Length) )
            } catch {
                return $false
            }
        }
        $first = $sizes[0]
        $allSame = $true
        foreach ($s in $sizes) {
            if ($s -ne $first) { $allSame = $false; break }
        }
        if ($allSame) { return $true }
    }
    return $false
}

function Get-UniqueDestination {
    param(
        [string]$DestDir,
        [string]$FileName
    )
    $dest = Join-Path $DestDir $FileName
    if (-not (Test-Path -LiteralPath $dest)) { return $dest }

    $base  = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    $ext   = [System.IO.Path]::GetExtension($FileName)
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $candidate = Join-Path $DestDir ("{0}_{1}{2}" -f $base, $stamp, $ext)
    $n = 1
    while (Test-Path -LiteralPath $candidate) {
        $candidate = Join-Path $DestDir ("{0}_{1}_{2}{3}" -f $base, $stamp, $n, $ext)
        $n++
    }
    return $candidate
}

function Get-CategoryForItem {
    param(
        [string]$Name,
        [bool]$IsDirectory
    )
    $lower = $Name.ToLowerInvariant()
    $ext = [System.IO.Path]::GetExtension($Name).ToLowerInvariant()

    foreach ($rule in $script:Rules) {
        if ($rule.DirsOnly -and -not $IsDirectory) { continue }
        if ($rule.FilesOnly -and $IsDirectory) { continue }

        $matched = $false
        switch ($rule.Match) {
            'extension' {
                if (-not $IsDirectory) {
                    foreach ($v in $rule.Values) {
                        $ve = $v.ToLowerInvariant()
                        if (-not $ve.StartsWith('.')) { $ve = ".$ve" }
                        if ($ext -eq $ve) { $matched = $true; break }
                    }
                }
            }
            'nameContains' {
                foreach ($v in $rule.Values) {
                    if ($lower.Contains($v.ToLowerInvariant())) { $matched = $true; break }
                }
            }
            'nameRegex' {
                foreach ($v in $rule.Values) {
                    try {
                        if ($Name -match $v) { $matched = $true; break }
                    } catch {}
                }
            }
        }
        if ($matched) {
            if ($script:CategoryFolders -contains $rule.Category) {
                return $rule.Category
            }
        }
    }
    return $script:DefaultCategory
}

function Escape-JsonString {
    param([string]$Value)
    if ($null -eq $Value) { return '' }
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Value.ToCharArray()) {
        switch ($ch) {
            '"'  { [void]$sb.Append('\"') }
            '\'  { [void]$sb.Append('\\') }
            "`n" { [void]$sb.Append('\n') }
            "`r" { [void]$sb.Append('\r') }
            "`t" { [void]$sb.Append('\t') }
            default {
                $code = [int]$ch
                if ($code -lt 0x20) {
                    [void]$sb.AppendFormat('\u{0:x4}', $code)
                } else {
                    [void]$sb.Append($ch)
                }
            }
        }
    }
    return $sb.ToString()
}

function Write-JournalEntry {
    param(
        [string]$From,
        [string]$To,
        [string]$Category,
        [string]$Name
    )
    try {
        $jDir = Split-Path -Parent $script:JournalPath
        if ($jDir -and -not (Test-Path -LiteralPath $jDir)) {
            New-Item -ItemType Directory -Path $jDir -Force | Out-Null
        }
        # Manual single-line JSONL (avoid ConvertTo-Json multi-line quirks)
        $ts = Escape-JsonString ((Get-Date).ToString('o'))
        $f  = Escape-JsonString $From
        $t  = Escape-JsonString $To
        $c  = Escape-JsonString $Category
        $n  = Escape-JsonString $Name
        $line = '{"timestamp":"' + $ts + '","from":"' + $f + '","to":"' + $t + '","category":"' + $c + '","name":"' + $n + '"}'
        $utf8 = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::AppendAllText($script:JournalPath, ($line + [Environment]::NewLine), $utf8)
    } catch {
        $errMsg = $_.Exception.Message
        Write-SortLog "WARN journal write failed: $errMsg"
    }
}

function Show-MoveToast {
    param(
        [string]$Name,
        [string]$Category
    )
    if (-not $script:ToastEnabled) { return }
    try {
        if ($null -eq $script:BurntToastAvailable) {
            $script:BurntToastAvailable = $false
            if (Get-Module -ListAvailable -Name BurntToast) {
                Import-Module BurntToast -ErrorAction SilentlyContinue
                if (Get-Command New-BurntToastNotification -ErrorAction SilentlyContinue) {
                    $script:BurntToastAvailable = $true
                }
            }
        }
        if ($script:BurntToastAvailable) {
            New-BurntToastNotification -Text 'Downloads sorted', "$Name → $Category" -ErrorAction SilentlyContinue | Out-Null
            return
        }
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
        $ni = New-Object System.Windows.Forms.NotifyIcon
        $ni.Icon = [System.Drawing.SystemIcons]::Information
        $ni.Visible = $true
        $ni.BalloonTipTitle = 'Downloads sorted'
        $ni.BalloonTipText = "$Name → $Category"
        $ni.ShowBalloonTip(3000)
        Start-Sleep -Milliseconds 500
        $ni.Visible = $false
        $ni.Dispose()
    } catch {
        # toast optional — never fail the move
    }
}

function Move-SortedItem {
    param([string]$FullPath)

    if ([string]::IsNullOrWhiteSpace($FullPath)) { return }

    $key = $FullPath.ToLowerInvariant()
    $shouldRun = $false
    [System.Threading.Monitor]::Enter($script:InFlightLock)
    try {
        if (-not $script:InFlight.ContainsKey($key)) {
            $script:InFlight[$key] = $true
            $shouldRun = $true
        }
    } finally {
        [System.Threading.Monitor]::Exit($script:InFlightLock)
    }
    if (-not $shouldRun) { return }

    try {
        $parent = [System.IO.Path]::GetDirectoryName($FullPath)
        if ($null -eq $parent) { return }
        $normParent = $parent.TrimEnd('\', '/')
        $normWatch  = $script:WatchPath.TrimEnd('\', '/')
        if ([string]::Compare($normParent, $normWatch, $true) -ne 0) { return }

        $name = [System.IO.Path]::GetFileName($FullPath)
        if (Test-IsCategoryFolder $name) { return }
        if (Test-IsIgnoredName $name) {
            Write-SortLog "SKIP ignored/partial: $name"
            return
        }

        if (-not (Test-SizeStable -FullPath $FullPath)) {
            Write-SortLog "SKIP unstable or vanished: $name"
            return
        }
        if (-not (Test-Path -LiteralPath $FullPath)) { return }

        $item = Get-Item -LiteralPath $FullPath -Force
        $isDir = [bool]$item.PSIsContainer
        $category = Get-CategoryForItem -Name $name -IsDirectory $isDir
        $destDir = Join-Path $script:WatchPath $category

        if (-not (Test-Path -LiteralPath $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
            Write-SortLog "Created missing category folder: $category"
        }

        $fromPath = $FullPath
        $dest = Get-UniqueDestination -DestDir $destDir -FileName $name
        try {
            Move-Item -LiteralPath $FullPath -Destination $dest -ErrorAction Stop
            $leaf = Split-Path -Leaf $dest
            Write-SortLog "MOVED: $name -> $category\$leaf"
            Write-JournalEntry -From $fromPath -To $dest -Category $category -Name $name
            Show-MoveToast -Name $name -Category $category
            Remove-EmptyNonCategoryFolders
        } catch {
            $errMsg = $_.Exception.Message
            Write-SortLog "ERROR move failed: $name -> $category : $errMsg"
        }
    } finally {
        [System.Threading.Monitor]::Enter($script:InFlightLock)
        try {
            $null = $script:InFlight.Remove($key)
        } finally {
            [System.Threading.Monitor]::Exit($script:InFlightLock)
        }
    }
}

function Invoke-StartupSweep {
    Write-SortLog "Startup sweep begin"
    Remove-EmptyNonCategoryFolders
    Get-ChildItem -LiteralPath $script:WatchPath -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $n = $_.Name
        if (Test-IsCategoryFolder $n) { return }
        if (Test-IsIgnoredName $n) { return }
        Move-SortedItem -FullPath $_.FullName
    }
    Remove-EmptyNonCategoryFolders
    Write-SortLog "Startup sweep end"
}

# ---------- Main ----------
try {
    Import-SorterConfig -Path $ConfigPath
} catch {
    Write-Error "Failed to load config: $($_.Exception.Message)"
    exit 1
}

if (-not (Test-Path -LiteralPath $script:WatchPath)) {
    Write-Error "Watch path not found: $($script:WatchPath)"
    exit 1
}

Ensure-CategoryFolders

# Single-instance mutex (skip for -Once sweep)
if (-not $Once) {
    $createdNew = $false
    try {
        $script:Mutex = New-Object System.Threading.Mutex($false, $script:MutexName, [ref]$createdNew)
        if (-not $createdNew) {
            $acquired = $false
            try { $acquired = $script:Mutex.WaitOne(0) } catch {}
            if (-not $acquired) {
                Write-SortLog "Another watcher instance already running (mutex=$($script:MutexName)). Exiting."
                exit 0
            }
        } else {
            try { [void]$script:Mutex.WaitOne(0) } catch {}
        }
    } catch {
        $errMsg = $_.Exception.Message
        Write-SortLog "WARN mutex setup failed (continuing): $errMsg"
    }
}

Write-SortLog "Watcher v2 starting PID=$PID path=$($script:WatchPath) rules=$($script:Rules.Count) toast=$($script:ToastEnabled)"

Invoke-StartupSweep

if ($Once) {
    Write-SortLog "Once mode — exiting"
    exit 0
}

$queue = New-Object System.Collections.Generic.List[string]
$queueLock = New-Object object
$queueBag = @{ List = $queue; Lock = $queueLock }

$fsw = New-Object System.IO.FileSystemWatcher
$fsw.Path = $script:WatchPath
$fsw.IncludeSubdirectories = $false
$fsw.NotifyFilter = [System.IO.NotifyFilters]::FileName -bor `
                    [System.IO.NotifyFilters]::DirectoryName
$fsw.Filter = '*'
$buf = $script:BufferSize
if ($buf -lt 4096) { $buf = 65536 }
if ($buf -gt 65536) { $buf = 65536 }
$fsw.InternalBufferSize = $buf
$fsw.EnableRaisingEvents = $true

$enqueueAction = {
    try {
        $path = $Event.SourceEventArgs.FullPath
        $bag = $Event.MessageData
        $list = $bag.List
        $lk = $bag.Lock
        [System.Threading.Monitor]::Enter($lk)
        try {
            if (-not $list.Contains($path)) {
                $list.Add($path)
            }
        } finally {
            [System.Threading.Monitor]::Exit($lk)
        }
    } catch {}
}

$subCreated = Register-ObjectEvent -InputObject $fsw -EventName Created `
    -Action $enqueueAction -MessageData $queueBag -SourceIdentifier 'DownloadsSorter.Created'
$subRenamed = Register-ObjectEvent -InputObject $fsw -EventName Renamed `
    -Action $enqueueAction -MessageData $queueBag -SourceIdentifier 'DownloadsSorter.Renamed'

Write-SortLog "FileSystemWatcher armed (Created+Renamed, buffer=$($fsw.InternalBufferSize))"

$lastIdleCheck = Get-Date
$lastEmptyFolderSweep = Get-Date

try {
    while ($true) {
        $next = $null
        [System.Threading.Monitor]::Enter($queueLock)
        try {
            if ($queue.Count -gt 0) {
                $next = $queue[0]
                $queue.RemoveAt(0)
            }
        } finally {
            [System.Threading.Monitor]::Exit($queueLock)
        }
        if ($null -ne $next) {
            Start-Sleep -Milliseconds $script:SettleMs
            Remove-EmptyNonCategoryFolders
            Move-SortedItem -FullPath $next
        } else {
            Start-Sleep -Milliseconds 400
            if ($script:RemoveEmptyFolders -and $script:EmptyFolderSweepIntervalSec -gt 0) {
                $emptyElapsed = ((Get-Date) - $lastEmptyFolderSweep).TotalSeconds
                if ($emptyElapsed -ge $script:EmptyFolderSweepIntervalSec) {
                    $lastEmptyFolderSweep = Get-Date
                    Remove-EmptyNonCategoryFolders
                }
            }
            if ($script:IdleReloadConfigMs -gt 0) {
                $elapsed = ((Get-Date) - $lastIdleCheck).TotalMilliseconds
                if ($elapsed -ge $script:IdleReloadConfigMs) {
                    $lastIdleCheck = Get-Date
                    if (Test-ConfigChanged) {
                        try {
                            Import-SorterConfig -Path $ConfigPath
                            Ensure-CategoryFolders
                            Write-SortLog "Config hot-reloaded (rules=$($script:Rules.Count))"
                        } catch {
                            $errMsg = $_.Exception.Message
                            Write-SortLog "WARN config reload failed: $errMsg"
                        }
                    }
                }
            }
        }
    }
} finally {
    Write-SortLog "Watcher stopping PID=$PID"
    Unregister-Event -SourceIdentifier 'DownloadsSorter.Created' -ErrorAction SilentlyContinue
    Unregister-Event -SourceIdentifier 'DownloadsSorter.Renamed' -ErrorAction SilentlyContinue
    Remove-Job -Id $subCreated.Id -Force -ErrorAction SilentlyContinue
    Remove-Job -Id $subRenamed.Id -Force -ErrorAction SilentlyContinue
    $fsw.EnableRaisingEvents = $false
    $fsw.Dispose()
    if ($script:Mutex) {
        try { $script:Mutex.ReleaseMutex() } catch {}
        try { $script:Mutex.Dispose() } catch {}
    }
}
