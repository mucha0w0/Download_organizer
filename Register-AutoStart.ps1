#Requires -Version 5.1
# Register Downloads sorter to run at user logon (no admin preferred)
$ErrorActionPreference = 'Stop'
$TaskName = 'DownloadsSorterWatcher'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ScriptPath = Join-Path $ScriptDir 'Watch-Downloads.ps1'
$CmdPath    = Join-Path $ScriptDir 'Start-DownloadsWatcher.cmd'
$StartupDir = [Environment]::GetFolderPath('Startup')
$ShortcutPath = Join-Path $StartupDir 'DownloadsSorterWatcher.lnk'

$result = [ordered]@{
    Method = $null
    Success = $false
    Detail = $null
}

function Register-StartupShortcut {
    $w = New-Object -ComObject WScript.Shell
    $sc = $w.CreateShortcut($ShortcutPath)
    $sc.TargetPath = $CmdPath
    $sc.WorkingDirectory = $ScriptDir
    $sc.WindowStyle = 7  # minimized
    $sc.Description = 'Downloads folder auto-sorter watcher v2'
    $sc.Save()
    return $ShortcutPath
}

try {
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    }

    $arg = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ScriptPath`""
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1)
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

    Register-ScheduledTask -TaskName $TaskName `
        -Action $action `
        -Trigger $trigger `
        -Settings $settings `
        -Principal $principal `
        -Description 'Auto-sort new Downloads files into category folders (v2 config-driven)' `
        -Force | Out-Null

    $result.Method = 'ScheduledTask'
    $result.Success = $true
    $result.Detail = "Task='$TaskName' AtLogOn user=$env:USERNAME script=$ScriptPath"
} catch {
    $result.Detail = "ScheduledTask failed: $($_.Exception.Message)"
    try {
        $path = Register-StartupShortcut
        $result.Method = 'StartupFolder'
        $result.Success = $true
        $result.Detail = "Fallback shortcut: $path (previous error: $($result.Detail))"
    } catch {
        $result.Method = 'None'
        $result.Success = $false
        $result.Detail = "Both failed. Task err then shortcut: $($result.Detail) | $($_.Exception.Message)"
    }
}

$result | ConvertTo-Json -Compress