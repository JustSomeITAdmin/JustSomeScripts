<#

.SYNOPSIS
OpenDriverUpdater - PSAppDeployToolkit 4.2 deployment. All settings come from driverConfig.json.

.DESCRIPTION
Install   stages this package under the stateDir\Package, records the profile (-CustomParam Production|Pilot) and
          registers the daily SYSTEM task that runs the cached package with -DeploymentType Repair -Scheduled.
          Runs no cycle itself.
Repair    the gate (Patch Tuesday window, once a month) decides; then one driver update cycle
          (SupportFiles\Invoke-DriverUpdate.ps1: Dell SDP catalog, Lenovo.Client.Update, HP Image Assistant,
          or Windows Update drivers) and the profile's restart handling (a prompting profile shows a daily
          cancellable ask, then a 24 h countdown at the deadline; a non-prompting profile stays silent).
Uninstall removes the task, the cache and the registry key. Drivers already installed stay.

.PARAMETER DeploymentType
The type of deployment to perform, Install, Uninstall, or Repair. Default is Install.

.PARAMETER DeployMode
Specifies whether the installation should be run in Interactive (shows dialogs), Silent (no dialogs), NonInteractive (dialogs without prompts) mode, or Auto (shows dialogs if a user is logged on, device is not in the OOBE, and there's no running apps to close).

.PARAMETER SuppressRebootPassThru
Prevents the toolkit from exiting with a defined reboot exit code (e.g. 3010), returning 0 instead.

.NOTES
See CHANGELOG.md in the repository for version history.

.EXAMPLE
& .\Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent

Installs the Production profile (the default).

.EXAMPLE
& .\Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent -CustomParam Pilot

Installs the Pilot (ring 0) profile.

.EXAMPLE
& .\Invoke-AppDeployToolkit.exe -DeploymentType Repair -DeployMode Auto

Runs one update cycle now, ignoring the window (what the scheduled task does with -Scheduled added).

#>

[CmdletBinding()]
param
(
    # Default is 'Install'.
    [Parameter(Mandatory = $false)]
    [ValidateSet('Install', 'Uninstall', 'Repair')]
    [System.String]$DeploymentType,

    # Default is 'Auto'. Don't hard-code this unless required.
    [Parameter(Mandatory = $false)]
    [ValidateSet('Auto', 'Interactive', 'NonInteractive', 'Silent')]
    [System.String]$DeployMode,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.SwitchParameter]$SuppressRebootPassThru,

    # Set by the scheduled task only. Applies the Patch Tuesday window / once-a-month gate to Repair.
    # A Repair run by hand (no switch) always runs the cycle.
    [Parameter(Mandatory = $false)]
    [System.Management.Automation.SwitchParameter]$Scheduled,

    # Which profile from driverConfig.json to install as: 'Production' (default) or 'Pilot' (ring 0 - same monthly
    # window but opened on Patch Tuesday itself, a few days ahead of the broader ring). Deploy one app per profile
    # with its own -CustomParam; Install records the choice in the registry and the scheduled task carries it.
    # Add more profiles by adding them to driverConfig.json and to this ValidateSet.
    [Parameter(Mandatory = $false)]
    [ValidateSet('Production', 'Pilot')]
    [System.String]$CustomParam
)

## MARK: Variables
# Organization-facing strings come from driverConfig.json so the dialog title, vendor and version all follow config.
$duConfig = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'driverConfig.json') -Raw | ConvertFrom-Json
$adtSession = @{
    AppVendor                   = "$($duConfig.publisher)"
    AppName                     = 'Driver Update Service'
    AppVersion                  = '1.0'
    AppArch                     = 'x64'
    AppLang                     = 'EN'
    AppRevision                 = '01'
    AppSuccessExitCodes         = @(0)
    AppRebootExitCodes          = @(1641, 3010)
    AppProcessesToClose         = @()

    AppScriptVersion            = "$($duConfig.packageVersion)"
    AppScriptDate               = '2026-09-22'
    AppScriptAuthor             = 'OpenDriverUpdater'

    # 4.2: DeployMode Auto would go Silent because no processes are defined. We want the restart prompt
    # whenever someone is logged on, so keep Auto = Interactive-with-user / Silent-without.
    NoProcessDetection          = $true
    # Header on every dialog (default would be "<vendor> <name> <version>").
    InstallTitle                = "$($duConfig.installTitle)"

    DeployAppScriptFriendlyName = $MyInvocation.MyCommand.Name
    DeployAppScriptParameters   = $PSBoundParameters
    DeployAppScriptVersion      = '4.2.0'
}

## MARK: Pre-Install
New-Variable -Name Pre-Install -Force -Value {
}

## MARK: Install
New-Variable -Name Install -Force -Value {
    ## Stage the whole package where the task can find it and register the task. Nothing runs now: the first
    ## cycle waits for the next Patch Tuesday window like every other one, so a new machine never restarts
    ## for drivers outside the month's patch week. This deployment finishes in seconds.
    $cfg = Get-ODUDriverUpdateConfig
    $duProfile = Resolve-ODUProfile -CustomParam $CustomParam
    ## Lock the state folder to SYSTEM/Administrators BEFORE anything is cached there: it all runs as SYSTEM later.
    Set-ODUStateAcl -Path $cfg.StateDir
    Remove-ADTFolder -Path $cfg.PackageDir -ErrorAction SilentlyContinue
    Copy-ADTFile -Path "$($adtSession.ScriptDirectory)\*" -Destination $cfg.PackageDir -Recurse
    ## PackageVersion is the version-aware detection marker; write it straight from driverConfig.json (a plain string)
    ## rather than $adtSession.AppScriptVersion, which the session exposes as a nullable [Version] that empties out
    ## when packageVersion isn't strict Major.Minor - so any packageVersion string (e.g. '2026.09', '1.0-rc') works.
    Set-ODUState @{ Profile = $duProfile; InstalledUtc = (Get-Date).ToUniversalTime().ToString('o'); PackageVersion = $cfg.PackageVersion }
    Register-ODUDriverUpdateTask -Profile $duProfile
    $duOffset = if ($null -ne $cfg.Profiles[$duProfile].DaysAfterPatchTuesday) { $cfg.Profiles[$duProfile].DaysAfterPatchTuesday } else { $cfg.Schedule.DaysAfterPatchTuesday }
    Write-ADTLogEntry -Message "Profile [$duProfile]. First driver update cycle will run $((Get-ODUNextCycleDate -Profile $duProfile).ToString('dddd yyyy-MM-dd HH:mm')) (Patch Tuesday + $duOffset, $($cfg.Schedule.WindowDays)-day window)."
}

## MARK: Post-Install
New-Variable -Name Post-Install -Force -Value {
}

## MARK: Pre-Uninstall
New-Variable -Name Pre-Uninstall -Force -Value {
}

## MARK: Uninstall
New-Variable -Name Uninstall -Force -Value {
    ## Remove the task and everything this package staged. Installed drivers are left alone.
    $cfg = Get-ODUDriverUpdateConfig
    Unregister-ODUDriverUpdateTask
    Remove-ADTFolder -Path $cfg.StateDir -ErrorAction SilentlyContinue
    ## Clear all state (profile, version marker, any pending-restart flag) so a later reinstall starts clean and a
    ## stale marker can never trigger a spurious restart prompt.
    Remove-ADTRegistryKey -LiteralPath $cfg.RegRoot -Recurse -ErrorAction SilentlyContinue
}

## MARK: Post-Uninstall
New-Variable -Name Post-Uninstall -Force -Value {
}

## MARK: Pre-Repair
New-Variable -Name Pre-Repair -Force -Value {
}

## MARK: Repair
New-Variable -Name Repair -Force -Value {
    ## Repair = one update cycle. The task calls this daily with -Scheduled; the gate makes it once a month,
    ## and the other days only retry a deferred restart prompt (a prompting profile) or a "someone was logged on" skip.
    $duProfile = Resolve-ODUProfile -CustomParam $CustomParam
    Write-ADTLogEntry -Message "Profile [$duProfile]; scheduled: $([bool]$Scheduled)."
    $mode = 'cycle'
    if ($Scheduled) {
        if (Test-ODUCycleDue -Profile $duProfile) { $mode = 'cycle' }
        elseif (Test-ODUPromptRetryDue -Profile $duProfile) { $mode = 'prompt' }
        else { return }
    }

    if ($mode -eq 'cycle') {
        $skip = Get-ODUSkipReason -Profile $duProfile
        if ($skip) {
            Write-ADTLogEntry -Message "Cycle skipped today: $skip. The daily task retries while the window is open."
            Set-ODUState @{ LastSkipUtc = (Get-Date).ToUniversalTime().ToString('o'); LastSkipReason = $skip }
            return
        }
        $result = Invoke-ODUDriverUpdateCycle -SupportFilesDirectory $adtSession.DirSupportFiles
        if (-not $result.RebootRequired) { return }
        $adtSession.SetExitCode(3010)
    }

    $pending = Get-ODUPendingRestart
    if (-not $pending) { Write-ADTLogEntry -Message 'No restart pending after all (the machine rebooted since the ask).'; return }
    Invoke-ODURestart -Pending $pending -Profile $duProfile
}

## MARK: Post-Repair
New-Variable -Name Post-Repair -Force -Value {
}


##================================================
## MARK: Initialization
##================================================

$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
$ProgressPreference = [System.Management.Automation.ActionPreference]::SilentlyContinue
Set-StrictMode -Version 1

try {
    if (Test-Path -LiteralPath "$PSScriptRoot\PSAppDeployToolkit\PSAppDeployToolkit.psd1" -PathType Leaf) {
        Get-ChildItem -LiteralPath "$PSScriptRoot\PSAppDeployToolkit" -Recurse -File | Unblock-File -ErrorAction Ignore
        Import-Module -FullyQualifiedName @{ ModuleName = [System.Management.Automation.WildcardPattern]::Escape("$PSScriptRoot\PSAppDeployToolkit\PSAppDeployToolkit.psd1"); Guid = '8c3c366b-8606-4576-9f2d-4051144f7ca2'; ModuleVersion = '4.2.0' } -Force
    }
    else {
        Import-Module -FullyQualifiedName @{ ModuleName = 'PSAppDeployToolkit'; Guid = '8c3c366b-8606-4576-9f2d-4051144f7ca2'; ModuleVersion = '4.2.0' } -Force
    }
    $iadtParams = Get-ADTBoundParametersAndDefaultValues -Invocation $MyInvocation -Exclude Scheduled, CustomParam
    # Strip null/empty values (e.g. the empty AppProcessesToClose) before splatting: Open-ADTSession validates its
    # parameters with ValidateNotNullOrEmpty, so an empty array would fail binding. This mirrors the stock template.
    $adtSession = Remove-ADTHashtableNullOrEmptyValues -Hashtable $adtSession
    $adtSession = Open-ADTSession @adtSession @iadtParams -PassThru
    Remove-Variable -Name iadtParams -Force -Confirm:$false
}
catch {
    $Host.UI.WriteErrorLine((Out-String -InputObject $_ -Width ([System.Int16]::MaxValue)))
    exit 60008
}


##================================================
## MARK: Invocation
##================================================

try {
    # Import any PSAppDeployToolkit.* extensions
    Get-ChildItem -LiteralPath $PSScriptRoot -Directory | & {
        process {
            if ($_.Name -match 'PSAppDeployToolkit\..+$') {
                Get-ChildItem -LiteralPath $_.FullName -Recurse -File | Unblock-File -ErrorAction Ignore
                Import-Module -Name ([System.Management.Automation.WildcardPattern]::Escape("$($_.FullName)\$($_.BaseName).psd1")) -Force
            }
        }
    }
    Get-Variable -Name "Pre-$($adtSession.DeploymentType)", $adtSession.DeploymentType, "Post-$($adtSession.DeploymentType)" -ErrorAction Ignore | . {
        process {
            if (![System.String]::IsNullOrWhiteSpace($_.Value)) {
                $adtSession.InstallPhase = $_.Name
                . $_.Value
            }
        }
    }
    Close-ADTSession
}
catch {
    Write-ADTLogEntry -Message "An unhandled error within [$($MyInvocation.MyCommand.Name)] has occurred.`n$(Resolve-ADTErrorRecord -ErrorRecord $_)" -Severity Error
    Close-ADTSession -ExitCode 60001
}
