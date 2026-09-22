<#
.SYNOPSIS
PSAppDeployToolkit.Extensions - OpenDriverUpdater helpers shared by the Install / Repair / Uninstall hooks.
All organization- and cadence-specific values come from driverConfig.json at the package root - edit that, not this.
#>

##*===============================================
##* MARK: MODULE GLOBAL SETUP
##*===============================================

$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
$ProgressPreference = [System.Management.Automation.ActionPreference]::SilentlyContinue
Set-StrictMode -Version 1

# Everything organization- and cadence-specific lives in driverConfig.json at the package root - the single source
# the launcher, the task, the worker and the detection scripts all agree on. Edit that file, not this module.
#
# Cadence follows the Windows Update rings: quality updates arrive Patch Tuesday + daysAfterPatchTuesday and the ring's
# deadline + grace forces a restart within ~6 days, so drivers install in the same window and ride the restart the ring
# already forces. The task fires DAILY; Test-ODUCycleDue lets only the first day inside the window run (once a month);
# other days are deferred restart prompts, or "someone was logged on" skips, or a no-op. A machine that misses the whole
# window waits for next month - there is no "first run now". promptDeadlineDays: the profile asks gently (Restart Now /
# Cancel) each day, and from this many days after the window opens it becomes a 24 h countdown with no Cancel, so the
# restart lands inside the window (the same deadline shape WUfB uses: deadline 5 + grace 1).
$configPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'driverConfig.json'
if (-not (Test-Path -LiteralPath $configPath)) { throw "driverConfig.json not found next to the package root: $configPath" }
$cfg = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
$stateDir = [System.Environment]::ExpandEnvironmentVariables("$($cfg.stateDir)")

# Profiles: one entry per profile the install line's -CustomParam can pick. Any profile may override
# daysAfterPatchTuesday to shift its window open (e.g. Pilot uses 0 to lead the broader rings by a few days).
$profiles = @{}
foreach ($prop in $cfg.profiles.PSObject.Properties) {
    $v = $prop.Value
    $entry = @{
        Time               = "$($v.time)"
        DeployMode         = "$($v.deployMode)"
        Prompt             = [bool]$v.prompt
        BlockOnConsoleUser = [bool]$v.blockOnConsoleUser
        RestartAfterCycle  = [bool]$v.restartAfterCycle
    }
    if ($null -ne $v.daysAfterPatchTuesday) { $entry.DaysAfterPatchTuesday = [int]$v.daysAfterPatchTuesday }
    $profiles[$prop.Name] = $entry
}

$script:ODU = @{
    Organization   = "$($cfg.organization)"
    Publisher      = "$($cfg.publisher)"
    InstallTitle   = "$($cfg.installTitle)"
    PackageVersion = "$($cfg.packageVersion)"
    TaskName       = "$($cfg.taskName)"
    StateDir       = $stateDir
    PackageDir     = (Join-Path $stateDir 'Package')
    WorkerName     = 'Invoke-DriverUpdate.ps1'
    RegRoot        = "$($cfg.registryRoot)"
    Schedule       = @{
        DaysAfterPatchTuesday = [int]$cfg.schedule.daysAfterPatchTuesday
        WindowDays            = [int]$cfg.schedule.windowDays
        PromptDeadlineDays    = [int]$cfg.schedule.promptDeadlineDays
    }
    Profiles       = $profiles
    # Before the deadline day the ask carries NO countdown (Restart Now / Cancel); from the deadline day it counts
    # down (PSADT caps a countdown at 24 h) with no Cancel. Nobody logged on: restart on session close (nothing to
    # lose; with hotpatch the ring may not restart every month, so waiting could leave it pending for months).
    RestartCountdown       = (New-TimeSpan -Hours ([int]$cfg.restart.countdownHours) -Minutes ([int]$cfg.restart.countdownMinutes))
    RestartCountdownNoHide = (New-TimeSpan -Hours ([int]$cfg.restart.countdownNoHideHours))
    RestartWhenNoUser      = [bool]$cfg.restart.restartWhenNoUser
    # Skip the cycle (retry tomorrow) when on battery below this fraction; a driver install mid-drain is a bad idea.
    MinBatteryFraction     = ([double]$cfg.restart.minBatteryPercent / 100.0)
}

##*===============================================
##* MARK: FUNCTION LISTINGS
##*===============================================

function Get-ODUDriverUpdateConfig {
    <#
    .SYNOPSIS
        Returns the shared configuration used by every hook.
    #>
    [CmdletBinding()]
    param()
    return $script:ODU
}

function Get-ODUState {
    <#
    .SYNOPSIS
        The package's registry state as an object (or $null when the key does not exist).
    #>
    [CmdletBinding()]
    param()
    return Get-ItemProperty -Path $script:ODU.RegRoot -ErrorAction SilentlyContinue
}

function Set-ODUState {
    <#
    .SYNOPSIS
        Writes one or more values under the package's registry key (created if needed).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Values)
    if (-not (Test-Path -LiteralPath $script:ODU.RegRoot)) { $null = New-Item -Path $script:ODU.RegRoot -Force }
    foreach ($k in $Values.Keys) { Set-ItemProperty -Path $script:ODU.RegRoot -Name $k -Value $Values[$k] }
}

function Resolve-ODUProfile {
    <#
    .SYNOPSIS
        Which profile this machine runs: the -CustomParam given on the command line, else the value Install wrote to
        the registry, else Production.
    #>
    [CmdletBinding()]
    param([string]$CustomParam)
    $name = if ($CustomParam) { $CustomParam } else { (Get-ODUState).Profile }
    if (-not $name -or -not $script:ODU.Profiles.ContainsKey($name)) { $name = 'Production' }
    return $name
}

function Invoke-ODUDriverUpdateCycle {
    <#
    .SYNOPSIS
        Runs the worker script in native 64-bit Windows PowerShell and returns its JSON result as an object.

    .DESCRIPTION
        The worker (SupportFiles\Invoke-DriverUpdate.ps1) does the vendor-specific work and never reboots.
        Exit 0 = the cycle ran (per-item results in the JSON); anything else = it could not run, which
        Start-ADTProcess turns into a thrown error so the deployment reports failure honestly.

    .PARAMETER SupportFilesDirectory
        Folder holding the worker script (normally $adtSession.DirSupportFiles).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SupportFilesDirectory,
        [switch]$ScanOnly
    )
    $worker = Join-Path $SupportFilesDirectory $script:ODU.WorkerName
    if (-not (Test-Path -LiteralPath $worker)) { throw "Worker script not found: $worker" }
    $sysNative = Join-Path $env:WinDir 'sysnative\WindowsPowerShell\v1.0\powershell.exe'
    $system32  = Join-Path $env:WinDir 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $ps = if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess -and (Test-Path $sysNative)) { $sysNative } else { $system32 }
    $argList = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$worker`" -StateDir `"$($script:ODU.StateDir)`""
    if ($ScanOnly) { $argList += ' -ScanOnly' }

    Write-ADTLogEntry -Message "Starting driver update worker: $worker"
    # 4 hours: HPIA or a 1 GB NVIDIA DUP on a slow link; the worker itself caps each tool.
    $proc = Start-ADTProcess -FilePath $ps -ArgumentList $argList -CreateNoWindow -Timeout (New-TimeSpan -Hours 4) -TimeoutAction Stop -PassThru
    $resultFile = Join-Path $script:ODU.StateDir 'last-run.json'
    if (-not (Test-Path -LiteralPath $resultFile)) { throw "Worker exited $($proc.ExitCode) but wrote no result file ($resultFile)." }
    $result = Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json
    Write-ADTLogEntry -Message ("Driver update cycle done. Vendor=[{0}] Method=[{1}] Installed={2} Failed={3} Pending={4} RebootRequired={5}" -f $result.Vendor, $result.Method, @($result.Installed).Count, @($result.Failed).Count, @($result.Pending).Count, $result.RebootRequired)
    foreach ($i in @($result.Installed)) { Write-ADTLogEntry -Message "  installed: $($i.Title) $($i.Version)" }
    foreach ($f in @($result.Failed))    { Write-ADTLogEntry -Message "  FAILED: $($f.Title) - $($f.Detail)" -Severity Warning }
    return $result
}

function Get-ODUPatchTuesday {
    <#
    .SYNOPSIS
        Second Tuesday of the given month (default: this month), as a date.
    #>
    [CmdletBinding()]
    param([datetime]$Month = (Get-Date))
    $first = Get-Date -Year $Month.Year -Month $Month.Month -Day 1 -Hour 0 -Minute 0 -Second 0 -Millisecond 0
    $firstTuesday = $first.AddDays((([int][DayOfWeek]::Tuesday - [int]$first.DayOfWeek) + 7) % 7)
    return $firstTuesday.AddDays(7)
}

function Get-ODUWindow {
    <#
    .SYNOPSIS
        This month's run window as @{ Open; Close } (Close exclusive), plus next month's Open. Open = Patch Tuesday +
        the profile's DaysAfterPatchTuesday (falls back to the global default; Pilot uses 0 to lead the broader
        rings by 3 days). Every profile keeps the same window length and deadline - the open day is all that shifts.
    #>
    [CmdletBinding()]
    param([datetime]$Month = (Get-Date), [string]$Profile = 'Production')
    $s = $script:ODU.Schedule
    $offset = $script:ODU.Profiles[$Profile].DaysAfterPatchTuesday
    if ($null -eq $offset) { $offset = $s.DaysAfterPatchTuesday }
    $open = (Get-ODUPatchTuesday $Month).AddDays($offset)
    return @{ Open = $open; Close = $open.AddDays($s.WindowDays); NextOpen = (Get-ODUPatchTuesday $Month.AddMonths(1)).AddDays($offset) }
}

function Get-ODUNextCycleDate {
    <#
    .SYNOPSIS
        The date the daily task will next actually run a cycle: today if inside the window and not yet run, else the
        opening day of the next window. Used for the Install log line.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Profile)
    $time = [timespan]::Parse($script:ODU.Profiles[$Profile].Time + ':00')
    $now = Get-Date
    $w = Get-ODUWindow -Profile $Profile
    # First daily trigger that is still ahead of us and inside a window.
    $candidate = if ($now.TimeOfDay -lt $time) { $now.Date } else { $now.Date.AddDays(1) }
    if ($candidate -lt $w.Open) { return $w.Open.Add($time) }
    if ($candidate -lt $w.Close) { return $candidate.Add($time) }
    return $w.NextOpen.Add($time)
}

function Test-ODUCycleDue {
    <#
    .SYNOPSIS
        True when a scheduled cycle should run today: inside this month's window and no cycle has completed since it
        opened. Never true outside the window, not even on a machine that has never run.

    .DESCRIPTION
        Reads LastCycleUtc from the registry (written by the worker only on a completed, non-scan run). A run that
        could not complete does not count, so the next day retries it.
    #>
    [CmdletBinding()]
    param([string]$Profile = 'Production')
    $today = (Get-Date).Date
    $w = Get-ODUWindow -Profile $Profile
    if ($today -lt $w.Open) { Write-ADTLogEntry -Message "Not due: this month's window opens $($w.Open.ToString('yyyy-MM-dd'))."; return $false }
    if ($today -ge $w.Close) { Write-ADTLogEntry -Message "Not due: this month's window closed $($w.Close.ToString('yyyy-MM-dd')); next window opens $($w.NextOpen.ToString('yyyy-MM-dd'))."; return $false }
    $last = (Get-ODUState).LastCycleUtc
    if ($last) {
        $lastLocal = ([datetime]::Parse($last)).ToLocalTime()
        if ($lastLocal -ge $w.Open) { Write-ADTLogEntry -Message "Already ran this month on $($lastLocal.ToString('yyyy-MM-dd')); next window opens $($w.NextOpen.ToString('yyyy-MM-dd'))."; return $false }
        Write-ADTLogEntry -Message "Due: window opened $($w.Open.ToString('yyyy-MM-dd')), last completed cycle $($lastLocal.ToString('yyyy-MM-dd'))."
    }
    else { Write-ADTLogEntry -Message "Due: window opened $($w.Open.ToString('yyyy-MM-dd')), no completed cycle on record." }
    return $true
}

function Get-ODUPendingRestart {
    <#
    .SYNOPSIS
        The restart this package asked for earlier and the machine has not yet performed, as an object with
        RebootPendingSince / PromptCount / PromptShownUtc; $null when there is none. Clears the flag (and resets the
        prompt count) if the machine has rebooted since the ask - the same rule the worker applies.
    #>
    [CmdletBinding()]
    param()
    $m = Get-ODUState
    if (-not $m -or -not $m.RebootPendingSince) { return $null }
    $rebooted = $true
    try {
        # Both sides as UTC: [datetime]::Parse of an 'o' string with a Z suffix yields a LOCAL DateTime, and comparing
        # Local with Utc kinds compares raw ticks (a 4-5 hour error that would read as "already rebooted").
        $bootNow  = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime()
        $bootFlag = [datetime]::Parse($m.BootTimeAtFlag).ToUniversalTime()
        $rebooted = ($bootFlag -lt $bootNow.AddSeconds(-30))
    } catch {}
    if ($rebooted) {
        Write-ADTLogEntry -Message "Restart requested on $($m.RebootPendingSince) has been completed; clearing the pending flag."
        foreach ($n in 'RebootPendingSince', 'BootTimeAtFlag', 'PromptCount', 'PromptShownUtc', 'PromptDeferredUtc', 'PromptDeferredReason') { Remove-ItemProperty -Path $script:ODU.RegRoot -Name $n -ErrorAction SilentlyContinue }
        return $null
    }
    return [pscustomobject]@{ RebootPendingSince = $m.RebootPendingSince; PromptCount = [int]$m.PromptCount; PromptShownUtc = $m.PromptShownUtc; LastCycleUtc = $m.LastCycleUtc; Vendor = $m.Vendor }
}

function Test-ODUPromptRetryDue {
    <#
    .SYNOPSIS
        True when a restart is pending, today is inside the window, and no prompt has been shown yet today: the
        a prompting profile asks once a day for the rest of the window (gently until the deadline day, then forced).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Profile)
    if (-not $script:ODU.Profiles[$Profile].Prompt) { return $false }
    $p = Get-ODUPendingRestart
    if (-not $p) { return $false }
    $today = (Get-Date).Date
    $w = Get-ODUWindow -Profile $Profile
    if ($today -lt $w.Open -or $today -ge $w.Close) { Write-ADTLogEntry -Message "A restart is pending since $($p.RebootPendingSince); outside the window, so no prompt today."; return $false }
    if ($p.PromptShownUtc -and ([datetime]::Parse($p.PromptShownUtc).ToLocalTime().Date -ge $today)) { return $false }
    Write-ADTLogEntry -Message "A restart is pending since $($p.RebootPendingSince) and no prompt has been shown today; prompting."
    return $true
}

function Get-ODUSkipReason {
    <#
    .SYNOPSIS
        Why the cycle must NOT run right now ($null = go ahead): battery too low, or a profile that blocks on an active console user has one logged on.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Profile)
    $bat = Test-ADTBattery -PassThru
    if ($bat.IsLaptop -and -not $bat.IsUsingACPower -and $bat.BatteryLifePercent -lt $script:ODU.MinBatteryFraction) {
        return "on battery at $([int]($bat.BatteryLifePercent * 100))% (below $([int]($script:ODU.MinBatteryFraction * 100))%)"
    }
    if ($script:ODU.Profiles[$Profile].BlockOnConsoleUser) {
        $console = @(Get-ODUActiveConsoleSession)
        if ($console.Count) { return "someone is active at the console: $(($console | ForEach-Object { "$($_.NTAccount) [$($_.ConnectState)]" }) -join ', ')" }
    }
    return $null
}

function Get-ODUActiveConsoleSession {
    <#
    .SYNOPSIS
        The console session(s) with a user actively connected (someone physically at the machine). RDP and
        disconnected sessions are deliberately not returned.
    #>
    [CmdletBinding()]
    param()
    return @(Get-ADTLoggedOnUser | Where-Object { $_.IsConsoleSession -and "$($_.ConnectState)" -match 'Active' })
}

function Invoke-ODURestart {
    <#
    .SYNOPSIS
        Decides what to do about a required restart and does it: silent restart with no sessions, the prompt for a
        user of a prompting profile who is not presenting / in focus mode, nothing (deferred) otherwise.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Pending, [Parameter(Mandatory)][string]$Profile)
    $cfg = $script:ODU
    $sessions = @(Get-ADTLoggedOnUser)

    # Profiles with restartAfterCycle = false never restart on their own; the machine's own scheduled reboot (e.g. a
    # nightly maintenance reboot) completes the drivers instead. Handy for lab/kiosk fleets that reboot on a schedule.
    if (-not $cfg.Profiles[$Profile].RestartAfterCycle) {
        Write-ADTLogEntry -Message "Restart required; profile [$Profile] leaves it to the machine's own scheduled reboot. The pending flag clears once that has happened."
        return
    }
    # A profile that restarts but never prompts: silent restart unless someone is active at the console.
    if (-not $cfg.Profiles[$Profile].Prompt) {
        if (@(Get-ODUActiveConsoleSession).Count) { Write-ADTLogEntry -Message "Restart required but someone is active at the console; profile [$Profile] never prompts, leaving it pending."; return }
        Write-ADTLogEntry -Message "Restart required; profile [$Profile]: restarting silently one minute after the session closes ($($sessions.Count) non-console session(s) will be ended)."
        Show-ADTInstallationRestartPrompt -SilentRestart -SilentCountdown (New-TimeSpan -Minutes 1) -ShutdownReasonText $script:ODU.InstallTitle
        return
    }

    if ($sessions.Count -eq 0) {
        if (-not $cfg.RestartWhenNoUser) { Write-ADTLogEntry -Message 'Restart required, nobody logged on, RestartWhenNoUser = false: leaving it pending.'; return }
        Write-ADTLogEntry -Message 'Restart required and nobody is logged on; restarting one minute after the session closes.'
        # With nobody logged on DeployMode Auto is Silent, and in Silent mode the restart prompt only acts when told
        # -SilentRestart (its own parameter set); it then restarts on session close after -SilentCountdown.
        Show-ADTInstallationRestartPrompt -SilentRestart -SilentCountdown (New-TimeSpan -Minutes 1) -ShutdownReasonText $script:ODU.InstallTitle
        return
    }

    # PSADT exports $RunAsActiveUser into the launcher's scope, not into this module: read it from the table.
    $activeUser = (Get-ADTEnvironmentTable).RunAsActiveUser
    $w = Get-ODUWindow -Profile $Profile
    $today = (Get-Date).Date
    $deadline = $w.Open.AddDays($cfg.Schedule.PromptDeadlineDays)
    $enforcing = ($today -ge $deadline -and $today -lt $w.Close)   # the deadline day through the last window day

    # No active user: only disconnected or locked-remote sessions (e.g. a job left running over RDP). Before the
    # deadline, leave it be and retry daily. ON/after the deadline, restart silently so the machine still gets its
    # one reboot this window - the update ring's own deadline reboot would end that session anyway. This is what
    # guarantees every powered-on machine reboots by the end of the window.
    if (-not $activeUser) {
        if (-not $enforcing) {
            Write-ADTLogEntry -Message 'Restart pending, but only disconnected/remote sessions are present; before the deadline, leaving any background job to run. Retried daily.'
            Set-ODUState @{ PromptDeferredUtc = (Get-Date).ToUniversalTime().ToString('o'); PromptDeferredReason = 'no active user (disconnected/remote sessions)' }
            return
        }
        Write-ADTLogEntry -Message 'Deadline reached with only disconnected/remote sessions; restarting silently to guarantee the monthly reboot.'
        Show-ADTInstallationRestartPrompt -SilentRestart -SilentCountdown (New-TimeSpan -Minutes 1) -ShutdownReasonText $script:ODU.InstallTitle
        return
    }

    # Active user, before the deadline: never interrupt while they are busy. Test-ADTUserIsBusy (4.2) covers a call
    # in progress (microphone in use - Zoom/Teams), focus mode, Do Not Disturb, a presenting/busy notification
    # state, and full-screen PowerPoint. On/after the deadline we prompt regardless - a 24 h countdown, so still a
    # full day's warning - because the monthly reboot has to land inside the window.
    if (-not $enforcing -and (Test-ADTUserIsBusy)) {
        Write-ADTLogEntry -Message 'Restart prompt deferred: the user is busy (a call, presentation, or focus / Do-Not-Disturb mode). Retried daily.'
        Set-ODUState @{ PromptDeferredUtc = (Get-Date).ToUniversalTime().ToString('o'); PromptDeferredReason = 'user busy (Test-ADTUserIsBusy)' }
        return
    }

    # Deadline model (same shape as the ring's): a gentle daily ask until the deadline day, a 24 h countdown after.
    $n = [int]$Pending.PromptCount + 1
    $forced = $enforcing
    Set-ODUState @{ PromptShownUtc = (Get-Date).ToUniversalTime().ToString('o'); PromptCount = $n }
    if (-not $forced) {
        # Gentle ask: no countdown, nothing forced. Restart Now or Cancel; asked again tomorrow.
        $daysLeft = [Math]::Max(0, ($deadline - $today).Days)
        $msg = "Driver updates from $($Pending.Vendor) were installed and finish with your next restart. Restart now if convenient, or Cancel and restart when it suits you. $(if ($daysLeft -gt 0) { "You will be reminded daily; from $($deadline.ToString('dddd, MMMM d')) the restart becomes automatic." } else { 'This is the last reminder before the restart becomes automatic.' })"
        Write-ADTLogEntry -Message "Restart prompt $n (no countdown, Cancel offered; deadline $($deadline.ToString('yyyy-MM-dd'))) for the restart pending since [$($Pending.RebootPendingSince)]."
        Show-ADTInstallationRestartPrompt -NoCountdown -AllowCancel `
            -Subtitle 'Driver updates need a restart' `
            -ShutdownReasonText $script:ODU.InstallTitle `
            -CustomMessage -CustomMessageText $msg
    }
    else {
        $msg = "Driver updates from $($Pending.Vendor) have been waiting for a restart since $(([datetime]$Pending.RebootPendingSince).ToLocalTime().ToString('MMMM d')). This restart can no longer be postponed. Save your work; the computer restarts automatically when the countdown ends."
        Write-ADTLogEntry -Message "Restart prompt $n (deadline reached: countdown $($cfg.RestartCountdown), no Cancel) for the restart pending since [$($Pending.RebootPendingSince)]."
        Show-ADTInstallationRestartPrompt -Countdown $cfg.RestartCountdown -CountdownNoHide $cfg.RestartCountdownNoHide -PersistPrompt `
            -Subtitle 'Driver updates need a restart' `
            -ShutdownReasonText $script:ODU.InstallTitle `
            -CustomMessage -CustomMessageText $msg
    }
}

function Register-ODUDriverUpdateTask {
    <#
    .SYNOPSIS
        Registers (or re-registers) the daily SYSTEM task that runs the cached package with
        -DeploymentType Repair -Scheduled -CustomParam <Profile>.

    .DESCRIPTION
        schtasks.exe creates it; the settings New-ScheduledTaskTrigger cannot express (start when available,
        battery, time limit) are patched on afterwards. The launcher's gate turns "daily" into "once inside the
        Patch Tuesday window".
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Profile)
    $launcher = Join-Path $script:ODU.PackageDir 'Invoke-AppDeployToolkit.exe'
    if (-not (Test-Path -LiteralPath $launcher)) { throw "Cached launcher not found: $launcher" }
    $p = $script:ODU.Profiles[$Profile]
    $arguments = "-DeploymentType Repair -DeployMode $($p.DeployMode) -Scheduled -CustomParam $Profile"
    $action    = New-ScheduledTaskAction -Execute $launcher -Argument $arguments
    $trigger   = New-ScheduledTaskTrigger -Daily -At $p.Time
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -RunOnlyIfNetworkAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 6)
    $null = Register-ScheduledTask -TaskName $script:ODU.TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force
    Write-ADTLogEntry -Message "Registered task [$($script:ODU.TaskName)]: daily at $($p.Time), profile [$Profile], gated to the Patch Tuesday window once a month; runs [$launcher $arguments]."
}

function Set-ODUStateAcl {
    <#
    .SYNOPSIS
        Locks the state folder down to SYSTEM + Administrators (full) and Users (read). Everything under it is
        executed as SYSTEM (the cached launcher, its extension modules, the worker, cached PowerShell modules,
        HPIA), and C:\ProgramData lets any user create files by default.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { $null = New-Item -Path $Path -ItemType Directory -Force }
    # icacls reports on stderr for failures; keep that from becoming a terminating NativeCommandError.
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $out = & "$env:WinDir\System32\icacls.exe" $Path /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' 2>&1
        $rc = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $prev }
    if ($rc -ne 0) { throw "icacls failed ($rc) on [$Path]: $out" }
    Write-ADTLogEntry -Message "ACL set on [$Path]: SYSTEM/Administrators full, Users read."
}

function Unregister-ODUDriverUpdateTask {
    <#
    .SYNOPSIS
        Removes the scheduled task if present.
    #>
    [CmdletBinding()]
    param()
    if (Get-ScheduledTask -TaskName $script:ODU.TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $script:ODU.TaskName -Confirm:$false
        Write-ADTLogEntry -Message "Removed task [$($script:ODU.TaskName)]."
    }
    else {
        Write-ADTLogEntry -Message "Task [$($script:ODU.TaskName)] was not present."
    }
}

##*===============================================
##* MARK: SCRIPT BODY
##*===============================================

Write-ADTLogEntry -Message "Module [$($MyInvocation.MyCommand.ScriptBlock.Module.Name)] imported successfully." -ScriptSection Initialization
