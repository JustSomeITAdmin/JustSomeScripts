<#
.SYNOPSIS
    Seeds power defaults once per device, keyed on chassis AND power model,
    leaving every setting user-changeable.

.DESCRIPTION
    Intended for Intune > Devices > Scripts (platform script), run as SYSTEM,
    64-bit. Platform scripts execute once per device, so this seeds values rather
    than enforcing them.

    WHY A SCRIPT RATHER THAN A CONFIGURATION PROFILE

    Power settings in the Settings Catalog are ADMX-backed and have two states:
    Enabled, which enforces the value and greys out the control in Settings >
    System > Power; and Not configured, which returns control to the user and
    applies no value at all. No state supplies a default the user may then
    change. Writing to the active scheme with powercfg is the only way to seed a
    value that stays adjustable.

    WHY SCHEME_CURRENT RATHER THAN AN IMPORTED .POW

    powercfg /import mints a new scheme GUID per device unless one is passed
    explicitly. Four sampled devices produced four different GUIDs for the same
    named plan, which makes GUID-based targeting useless at fleet scale.
    Imported schemes are also dropped by Windows reset and by "Restore default
    settings for this plan". SCHEME_CURRENT follows whatever plan is active.

    v2.0 CHANGES, all driven by fleet sampling

      * Power model detection added. powercfg /a prints an available and a
        not-available section; a naive match reports Modern Standby on machines
        where the state appears only in the not-available list.

      * Modern Standby laptops now get a longer DISPLAY timeout. On that
        platform display-off is the entry point into connected standby, where
        the Desktop Activity Moderator throttles Win32 apps - so the display
        timer, not the sleep timer, is what stalls unattended installs.

      * HibernateAfter is no longer seeded on Modern Standby devices. The
        hibernate idle timeout treats 0 as "hibernate at the adaptive threshold"
        rather than never, so seeding 0 would convert an OEM never into
        adaptive. Sampled laptops ship a max-int sentinel, which is a true never.

      * Devices with no reachable standby state are detected and logged. Sleep
        values are still written as insurance against a firmware or VBS change,
        but the log records that they are inert today.

    ROLLBACK

        powercfg /restoredefaultschemes

    That deletes custom schemes and restores built-ins to factory values. It also
    removes OEM-supplied schemes, so test on one device before fleet use.

.PARAMETER Force
    Apply regardless of the existing state marker. Overwrites user changes.

.PARAMETER WhatIfOnly
    Report detected hardware and planned values, then exit without writing.

.NOTES
    Run as:            SYSTEM
    Run in 64-bit PS:  Yes
    Signature check:   Not required
    Exit codes:        0 success or already seeded, 1 failure

    State + log:       C:\ProgramData\PowerSeed\  (change $StateRoot below to
                       organise per-department, e.g. C:\ProgramData\YourOrg\PowerSeed).

    Legacy .pow cleanup: OFF by default. If you previously deployed a custom
                       .pow file and want this seed to retire it, set
                       $RemoveLegacyScheme = $true and $LegacySchemeMatch to a
                       substring of that scheme's display name.
#>

[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$WhatIfOnly
)

$ErrorActionPreference = 'Stop'

# ===========================================================================
#  CONFIGURATION
# ===========================================================================

# Increment to re-seed the fleet on the next script run.
$SeedVersion = '2.1'

# Optionally retire a previously-deployed custom power scheme by NAME
# (because powercfg /import mints a new GUID per device, so GUID matching is
# useless at fleet scale). Deleting the ACTIVE scheme drops the device to
# Balanced, which discards any customisation a user made inside the old plan -
# a one-time reset worth mentioning to users before deployment.
# Set $RemoveLegacyScheme = $true and put a substring of the display name
# in $LegacySchemeMatch (e.g. 'MyOrg Power'). Off by default.
$RemoveLegacyScheme = $false
$LegacySchemeMatch  = ''

# Surface hidden settings in Advanced Power Settings so users can see and change
# what was seeded. Both are hidden by Windows default.
$UnhideHiddenSettings = $true

# Disable fast startup.
#
# Fast startup hibernates the kernel session instead of performing a real
# shutdown, so a user choosing "Shut down" does not complete pending update and
# driver installs; only "Restart" does. In a managed fleet that turns
# "I shut it down every night" into a silent no-op for patching.
#
# The ADMX policy named "Require use of fast startup" (ADMX_WinInit/Hiberboot)
# CANNOT be used for this. Enabling it requires fast startup; disabling or not
# configuring it returns to the local setting. It is one-directional. The local
# value below is the only lever that turns the feature off.
#
# powercfg /h off is deliberately NOT used - it disables hibernation entirely,
# and Modern Standby devices rely on adaptive hibernate to preserve battery.
# HiberbootEnabled=0 removes fast startup while leaving hibernation intact.
#
# Takes effect at the next shutdown. The checkbox on the "Define power buttons"
# page may still read as ticked until then; that is not a failure.
# Rollback: set HiberbootEnabled back to 1 and shut down.
$DisableFastStartup = $true

# Wake timers were inconsistent across sampled hardware: two devices Enable on
# AC / Disable on DC, one Enable on both, one Disable on both. Enabling this
# normalises them. Left OFF by default because it changes maintenance-wake
# behavior, which has patching implications beyond power.
$NormalizeWakeTimers = $false
$WakeTimerValues     = @{ AC = 2; DC = 0 }   # 0 Disable, 1 Enable, 2 Important only

# Seconds. 0 = Never for timeouts.
# Button and lid actions: 0 Do nothing, 1 Sleep, 2 Hibernate, 3 Shut down.
# A $null rail is skipped entirely, leaving the existing value untouched.

$DesktopProfile = @{
    SleepAfter            = @{ AC = 0;    DC = $null }
    HibernateAfter        = @{ AC = 0;    DC = $null }
    UnattendedSleep       = @{ AC = 0;    DC = $null }
    DisplayOff            = @{ AC = 1200; DC = $null }   # 20 min, up from a 5 min OEM default
    ConsoleLockDisplayOff = @{ AC = 60;   DC = $null }   # panel off 1 min AFTER the lock screen
    PowerButton           = @{ AC = 3;    DC = $null }   # shut down
}

$LaptopProfile = @{
    SleepAfter            = @{ AC = 0;    DC = 1800 }
    HibernateAfter        = @{ AC = 0;    DC = $null }   # removed on Modern Standby, see below
    DisplayOff            = @{ AC = 900;  DC = 600 }
    ConsoleLockDisplayOff = @{ AC = 60;   DC = 60 }
    PowerButton           = @{ AC = 3;    DC = 3 }
    SleepButton           = @{ AC = 1;    DC = 1 }

    # Unattended sleep applies only after a wake from sleep triggered by
    # something other than a person - a wake timer or Wake-on-LAN. It does not
    # govern a machine that was powered on manually and left alone; that is the
    # normal sleep timer. 0 on AC means an unattended maintenance wake is never
    # cut short. 300 on DC keeps battery drain bounded after a 2am wake.
    UnattendedSleep       = @{ AC = 0;    DC = 300 }

    # ---- JUDGMENT CALL ---------------------------------------------------
    # Lid close on AC. 0 (Do nothing) suits users who dock lid-closed. The cost
    # is an unplugged, closed laptop that keeps running in a bag. Set to 1
    # (Sleep) if lid-closed docking is uncommon in your population.
    LidClose              = @{ AC = 0;    DC = 1 }
    # ----------------------------------------------------------------------
}

# Applied on top of the base profile when the device is Modern Standby.
$ModernStandbyAdjustments = @{
    # Hibernate idle timeout treats 0 as "adaptive threshold" on this platform,
    # not never. Sampled laptops ship a max-int sentinel, a true never. Seeding
    # 0 would be a regression, so leave the OEM value alone.
    Remove = @('HibernateAfter')

    # Display-off is the entry point into connected standby here, so this timer
    # is what determines whether an unattended install survives. Longer than the
    # traditional-sleep profile deliberately.
    Set = @{
        DisplayOff = @{ AC = 1200; DC = 600 }
    }
}

# ===========================================================================
#  END CONFIGURATION
# ===========================================================================

$StateRoot = Join-Path $env:ProgramData 'PowerSeed'
$StateFile = Join-Path $StateRoot 'state.json'
$LogFile   = Join-Path $StateRoot 'seed.log'
$PowerCfg  = Join-Path $env:SystemRoot 'System32\powercfg.exe'
$PolicyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Power\PowerSettings'

#region Setting GUIDs -------------------------------------------------------
$SUB_SLEEP   = '238C9FA8-0AAD-41ED-83F4-97BE242C8F20'
$SUB_VIDEO   = '7516B95F-F776-4464-8C53-06167F40CC99'
$SUB_BUTTONS = '4F971E89-EEBD-4455-A8DE-9E59040E7347'

$GUIDS = @{
    SleepAfter            = @{ Sub = $SUB_SLEEP;   Id = '29F6C1DB-86DA-48C5-9FDB-F2B67B1F44DA' }
    UnattendedSleep       = @{ Sub = $SUB_SLEEP;   Id = '7BC4A2F9-D8FC-4469-B07B-33EB785AACA0' }
    HibernateAfter        = @{ Sub = $SUB_SLEEP;   Id = '9D7815A6-7EE4-497E-8888-515A05F02364' }
    AllowWakeTimers       = @{ Sub = $SUB_SLEEP;   Id = 'BD3B718A-0680-4D9D-8AB2-E1D2B4AC806D' }
    DisplayOff            = @{ Sub = $SUB_VIDEO;   Id = '3C0BC021-C8A8-4E07-A973-6B14CBCB2B7E' }
    ConsoleLockDisplayOff = @{ Sub = $SUB_VIDEO;   Id = '8EC4B3A5-6868-48C2-BE75-4F3044BE88A7' }
    PowerButton           = @{ Sub = $SUB_BUTTONS; Id = '7648EFA3-DD9C-4E3E-B566-50F929386280' }
    SleepButton           = @{ Sub = $SUB_BUTTONS; Id = '96996BC0-AD50-47EC-923B-6F41874DD9EB' }
    LidClose              = @{ Sub = $SUB_BUTTONS; Id = '5CA83367-6E45-459F-A27B-476B1D01C936' }
}

$BALANCED = '381b4222-f694-41f0-9685-ff5bb260df2e'
#endregion

function Write-CMLogEntry {
    param(
        [Parameter(Mandatory)][string]$Value,
        [ValidateSet('1','2','3')][string]$Severity = '1',
        [string]$Component = 'PowerSeed'
    )
    if (-not (Test-Path 'variable:global:TimezoneBias')) {
        [string]$global:TimezoneBias = [System.TimeZoneInfo]::Local.GetUtcOffset((Get-Date)).TotalMinutes
        $global:TimezoneBias = if ($TimezoneBias -match '^-') { $TimezoneBias.Replace('-','+') } else { '-' + $TimezoneBias }
    }
    $Time = -join @((Get-Date -Format 'HH:mm:ss.fff'), $TimezoneBias)
    $Date = (Get-Date -Format 'MM-dd-yyyy')
    $Context = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $LogText = "<![LOG[$Value]LOG]!><time=""$Time"" date=""$Date"" component=""$Component"" context=""$Context"" type=""$Severity"" thread=""$PID"" file="""">"
    try {
        if (-not (Test-Path -LiteralPath $StateRoot)) {
            New-Item -Path $StateRoot -ItemType Directory -Force | Out-Null
        }
        Out-File -InputObject $LogText -Append -NoClobber -Encoding Default -FilePath $LogFile -ErrorAction Stop
    } catch {}
}

function Write-Step {
    # Shim to CMTrace so existing call sites do not have to change. Colors map:
    # Yellow -> warning, Red -> error, everything else -> info. Empty messages
    # were console spacers in the original transcript; drop them for CMTrace.
    param([string]$Message, [string]$Color = 'Gray')
    if ([string]::IsNullOrEmpty($Message)) { return }
    $severity = switch ($Color) { 'Yellow' { '2' } 'Red' { '3' } default { '1' } }
    Write-CMLogEntry -Value $Message -Severity $severity
}

function Save-Transcript { }   # no-op: CMTrace log is flushed per-line by Write-CMLogEntry

function New-SecureStateRoot {
    # Inheritance off; write access limited to SYSTEM and Administrators. A
    # standard user able to write here could delete the marker to force a
    # re-seed, or plant a junction to redirect the log write.
    if (-not (Test-Path -LiteralPath $StateRoot)) {
        New-Item -Path $StateRoot -ItemType Directory -Force | Out-Null
    }
    $acl = Get-Acl -LiteralPath $StateRoot
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($r in @($acl.Access)) { $acl.RemoveAccessRule($r) | Out-Null }

    $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $prop    = [System.Security.AccessControl.PropagationFlags]::None
    $allow   = [System.Security.AccessControl.AccessControlType]::Allow

    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            (New-Object System.Security.Principal.SecurityIdentifier($sid)),
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            $inherit, $prop, $allow))) | Out-Null
    }
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
        (New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')),
        [System.Security.AccessControl.FileSystemRights]::ReadAndExecute,
        $inherit, $prop, $allow))) | Out-Null

    Set-Acl -LiteralPath $StateRoot -AclObject $acl
}

function Invoke-PowerCfg {
    param([string[]]$Arguments)
    $out = & $PowerCfg @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ("powercfg {0} exited {1}: {2}" -f ($Arguments -join ' '), $LASTEXITCODE, (($out | Out-String).Trim()))
    }
}

function Get-PowerModel {
    <#
        Returns a hashtable describing what low-power states this device can
        actually reach.

        powercfg /a prints an available section AND a not-available section.
        Matching state names against the whole output reports states as present
        when they appear only in the not-available list. Split first.
    #>
    $raw = ''
    try { $raw = (& $PowerCfg /a 2>&1 | Out-String) } catch { }

    $availableSection = ($raw -split '(?mi)^The following sleep states are not available')[0]

    return @{
        Raw            = $raw
        ModernStandby  = [bool]($availableSection -match 'S0 Low Power Idle')
        AnyStandby     = [bool]($availableSection -match 'Standby \(')
        Hibernate      = [bool]($availableSection -match 'Hibernate')
        DeviceGuardS3  = [bool]($raw -match 'Device Guard configuration has disabled')
    }
}

function Get-ChassisProfile {
    <#
        Returns Desktop or Laptop.

        Detection order, strongest signal first:
          1. A real battery. Most reliable indicator of a portable device.
          2. SMBIOS chassis type, when no battery is present. Catches a laptop
             whose battery was removed or has failed. OEM-populated and often
             unset on SFF desktops and VMs, hence secondary.
          3. Virtualisation. VMs report neither reliably and should not sleep.
          4. Fallback to Desktop. Conservative: it seeds never-sleep on AC and
             writes no DC values, so a misdetected laptop keeps its battery
             behavior unchanged.
    #>
    $portable   = @(8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32)
    $stationary = @(3, 4, 5, 6, 7, 13, 15, 16, 17, 23, 24)

    $chassisTypes = @()
    try {
        foreach ($enc in @(Get-CimInstance Win32_SystemEnclosure -ErrorAction Stop)) {
            if ($enc.ChassisTypes) { $chassisTypes += $enc.ChassisTypes }
        }
    }
    catch { }

    $hasBattery = $false
    try { $hasBattery = @(Get-CimInstance Win32_Battery -ErrorAction Stop).Count -gt 0 } catch { }

    $cs = $null
    try { $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop } catch { }
    $isVm = $false
    if ($cs) {
        $isVm = "$($cs.Manufacturer) $($cs.Model)" -match 'VMware|VirtualBox|Virtual Machine|KVM|QEMU|Xen|Parallels|Hyper-V'
    }

    Write-Step ("Model:            {0} {1}" -f $cs.Manufacturer, $cs.Model)
    Write-Step ("Chassis types:    {0}" -f $(if ($chassisTypes) { $chassisTypes -join ',' } else { 'none reported' }))
    Write-Step ("Battery present:  {0}" -f $hasBattery)
    Write-Step ("Virtual machine:  {0}" -f $isVm)

    if ($isVm)        { Write-Step 'Chassis: VM -> Desktop.' 'Cyan'; return 'Desktop' }
    if ($hasBattery)  { Write-Step 'Chassis: battery present -> Laptop.' 'Cyan'; return 'Laptop' }
    if ($chassisTypes | Where-Object { $portable   -contains $_ }) { Write-Step 'Chassis: portable SMBIOS, no battery -> Laptop.' 'Cyan'; return 'Laptop' }
    if ($chassisTypes | Where-Object { $stationary -contains $_ }) { Write-Step 'Chassis: stationary SMBIOS -> Desktop.' 'Cyan'; return 'Desktop' }

    Write-Step 'Chassis: inconclusive -> Desktop (conservative fallback).' 'Yellow'
    return 'Desktop'
}

function Remove-LegacyScheme {
    <#
        Deletes the retired custom scheme by NAME. The original was distributed
        with powercfg /import and no explicit GUID, so every device has its own
        and GUID matching is useless. The active scheme cannot be deleted, so
        switch to Balanced first.
    #>
    param([string]$Match)

    if ([string]::IsNullOrWhiteSpace($Match)) {
        Write-Step 'Legacy scheme cleanup enabled but $LegacySchemeMatch is empty. Refusing to match every scheme. Set the substring to enable.' 'Yellow'
        return @()
    }

    $list = (& $PowerCfg /list 2>&1 | Out-String)
    $hits = [regex]::Matches($list, '(?im)Power Scheme GUID:\s*([0-9a-f-]{36})\s*\((.+?)\)\s*(\*?)')

    $removed = @()
    foreach ($h in $hits) {
        $guid = $h.Groups[1].Value
        $name = $h.Groups[2].Value.Trim()
        if ($name -notlike "*$Match*") { continue }
        $active = $h.Groups[3].Value -eq '*'

        Write-Step ("Legacy scheme: '{0}' [{1}]{2}" -f $name, $guid, $(if ($active) { ' ACTIVE' } else { '' })) 'Yellow'
        try {
            if ($active) {
                Invoke-PowerCfg @('/setactive', $BALANCED)
                Write-Step '  Active scheme switched to Balanced.'
            }
            Invoke-PowerCfg @('/delete', $guid)
            Write-Step ("  Deleted {0}." -f $guid) 'Green'
            $removed += [pscustomobject]@{ Guid = $guid; Name = $name; WasActive = $active }
        }
        catch { Write-Step ("  Delete failed: {0}" -f $_.Exception.Message) 'Yellow' }
    }
    if ($removed.Count -eq 0) { Write-Step 'No legacy scheme present.' }
    return $removed
}

# ===========================================================================

$applied = [System.Collections.Generic.List[object]]::new()
$skipped = [System.Collections.Generic.List[object]]::new()

try {
    if (-not (Test-Path -LiteralPath $PowerCfg)) { throw "powercfg.exe not found at $PowerCfg" }

    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not ([Security.Principal.WindowsPrincipal]$id).IsInRole(
              [Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Elevation required. Configure this platform script to run in the SYSTEM context.'
    }

    Write-Step "Power seed $SeedVersion on $env:COMPUTERNAME (as $($id.Name))" 'Cyan'

    # --- Seed marker -------------------------------------------------------
    if ((Test-Path -LiteralPath $StateFile) -and -not $Force) {
        try {
            $prior = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
            if ($prior.SeedVersion -eq $SeedVersion) {
                Write-Step "Seed $SeedVersion already applied on $($prior.AppliedUtc). No action." 'Green'
                Save-Transcript
                Write-Output "Already seeded at $SeedVersion."
                exit 0
            }
            Write-Step ("Prior seed {0}; re-seeding to {1}." -f $prior.SeedVersion, $SeedVersion)
        }
        catch { Write-Step 'State file unreadable; treating as unseeded.' 'Yellow' }
    }

    New-SecureStateRoot

    # --- Hardware detection ------------------------------------------------
    Write-Step ''
    Write-Step '--- Hardware detection ---' 'Cyan'
    $chassis = Get-ChassisProfile
    $power   = Get-PowerModel

    Write-Step ("Modern Standby:   {0}" -f $power.ModernStandby)
    Write-Step ("Any standby:      {0}" -f $power.AnyStandby)
    Write-Step ("Hibernate:        {0}" -f $power.Hibernate)

    if (-not $power.AnyStandby) {
        Write-Step 'NO STANDBY STATE REACHABLE - sleep values below are inert today.' 'Yellow'
        Write-Step 'They are still written as insurance against a firmware or VBS change.' 'Yellow'
        if ($power.DeviceGuardS3) {
            Write-Step 'Device Guard / VBS is disabling S3 on this platform.' 'Yellow'
        }
    }

    # --- Resolve the profile ----------------------------------------------
    $profile = if ($chassis -eq 'Laptop') { $LaptopProfile.Clone() } else { $DesktopProfile.Clone() }
    $adjustments = @()

    if ($power.ModernStandby) {
        foreach ($k in $ModernStandbyAdjustments.Remove) {
            if ($profile.ContainsKey($k)) {
                $profile.Remove($k)
                $adjustments += "removed $k"
            }
        }
        foreach ($k in $ModernStandbyAdjustments.Set.Keys) {
            $profile[$k] = $ModernStandbyAdjustments.Set[$k]
            $adjustments += "overrode $k"
        }
        Write-Step ("Modern Standby adjustments: {0}" -f ($adjustments -join ', ')) 'Cyan'
    }

    if ($NormalizeWakeTimers) {
        $profile['AllowWakeTimers'] = $WakeTimerValues
        Write-Step 'Wake timer normalisation enabled.' 'Cyan'
    }

    $profileLabel = "$chassis$(if ($power.ModernStandby) { '/ModernStandby' } else { '/TraditionalSleep' })"

    # --- Warn on policy overrides -----------------------------------------
    # Any GUID under this key beats every power scheme, so a value seeded below
    # will not take effect for that setting.
    if (Test-Path -LiteralPath $PolicyKey) {
        $ov = @(Get-ChildItem -LiteralPath $PolicyKey -ErrorAction SilentlyContinue)
        if ($ov.Count -gt 0) {
            Write-Step ''
            Write-Step 'POWER CSP OVERRIDES PRESENT - these beat the seeded values:' 'Yellow'
            foreach ($o in $ov) { Write-Step ("  {0}" -f $o.PSChildName) 'Yellow' }
        }
    }

    if ($WhatIfOnly) {
        Write-Step ''
        Write-Step "WHATIF - profile $profileLabel would be applied:" 'Yellow'
        foreach ($k in ($profile.Keys | Sort-Object)) {
            Write-Step ("  {0,-24} AC={1,-8} DC={2}" -f $k,
                        $(if ($null -eq $profile[$k].AC) { 'skip' } else { $profile[$k].AC }),
                        $(if ($null -eq $profile[$k].DC) { 'skip' } else { $profile[$k].DC })) 'Yellow'
        }

        # Preview the destructive step too. Deleting a scheme is the riskiest
        # thing this script does, so it is exactly what WhatIf should surface -
        # and it proves the name regex matches real powercfg /list output before
        # the real run.
        if ($RemoveLegacyScheme) {
            Write-Step ''
            Write-Step 'WHATIF - legacy scheme cleanup:' 'Yellow'
            if ([string]::IsNullOrWhiteSpace($LegacySchemeMatch)) {
                Write-Step '  $LegacySchemeMatch is empty; would refuse to run (matches every scheme).' 'Yellow'
            }
            else {
                $preview = (& $PowerCfg /list 2>&1 | Out-String)
                $any = $false
                foreach ($h in [regex]::Matches($preview, '(?im)Power Scheme GUID:\s*([0-9a-f-]{36})\s*\((.+?)\)\s*(\*?)')) {
                    if ($h.Groups[2].Value.Trim() -notlike "*$LegacySchemeMatch*") { continue }
                    $any = $true
                    Write-Step ("  WOULD DELETE '{0}' [{1}]{2}" -f $h.Groups[2].Value.Trim(), $h.Groups[1].Value,
                                $(if ($h.Groups[3].Value -eq '*') { ' - ACTIVE, would switch to Balanced first' } else { '' })) 'Yellow'
                }
                if (-not $any) { Write-Step '  No matching scheme present.' 'Yellow' }
            }
        }

        if ($DisableFastStartup) {
            $curHb = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' `
                      -Name HiberbootEnabled -ErrorAction SilentlyContinue).HiberbootEnabled
            Write-Step ''
            Write-Step ("WHATIF - fast startup: HiberbootEnabled is {0}, would set 0." -f `
                        $(if ($null -eq $curHb) { 'not set' } else { $curHb })) 'Yellow'
        }

        Save-Transcript
        Write-Output "WhatIf: $profileLabel, $($profile.Count) settings."
        exit 0
    }

    # --- Retire the legacy scheme -----------------------------------------
    $removedSchemes = @()
    if ($RemoveLegacyScheme) {
        Write-Step ''
        Write-Step '--- Legacy scheme cleanup ---' 'Cyan'
        # @() forces an array. Without it a single result unrolls to a scalar,
        # .Count returns $null on a PSCustomObject, and the summary line prints
        # "legacy=" with no number - which is the field you would grep across a
        # thousand script results to confirm cleanup ran. It also keeps
        # RemovedSchemes an array in state.json for consistent fleet parsing.
        $removedSchemes = @(Remove-LegacyScheme -Match $LegacySchemeMatch)
    }

    # --- Unhide settings ---------------------------------------------------
    if ($UnhideHiddenSettings) {
        Write-Step ''
        Write-Step '--- Unhiding settings in Advanced Power Settings ---' 'Cyan'
        foreach ($k in @('UnattendedSleep', 'ConsoleLockDisplayOff')) {
            try {
                Invoke-PowerCfg @('-attributes', $GUIDS[$k].Sub, $GUIDS[$k].Id, '-ATTRIB_HIDE')
                Write-Step ("  {0} now visible." -f $k) 'Green'
            }
            catch { Write-Step ("  {0} unhide skipped: {1}" -f $k, $_.Exception.Message) 'Yellow' }
        }
    }

    # --- Apply -------------------------------------------------------------
    Write-Step ''
    Write-Step "--- Applying $profileLabel to SCHEME_CURRENT ---" 'Cyan'

    foreach ($key in $profile.Keys) {
        if (-not $GUIDS.ContainsKey($key)) {
            Write-Step ("  SKIP {0}: no GUID mapping." -f $key) 'Yellow'
            continue
        }
        $g = $GUIDS[$key]

        foreach ($rail in @('AC', 'DC')) {
            $val = $profile[$key][$rail]
            if ($null -eq $val) { continue }

            $verb = if ($rail -eq 'AC') { '-setacvalueindex' } else { '-setdcvalueindex' }
            try {
                Invoke-PowerCfg @($verb, 'SCHEME_CURRENT', $g.Sub, $g.Id, $val)
                Write-Step ("  OK   {0,-24} {1} = {2}" -f $key, $rail, $val) 'Green'
                $applied.Add([pscustomobject]@{ Setting = $key; Rail = $rail; Value = $val }) | Out-Null
            }
            catch {
                # Absent on this hardware (no lid, no battery rail, no hibernate
                # support) is expected and non-fatal.
                Write-Step ("  SKIP {0,-24} {1}: {2}" -f $key, $rail, $_.Exception.Message) 'Yellow'
                $skipped.Add([pscustomobject]@{ Setting = $key; Rail = $rail; Reason = "$($_.Exception.Message)" }) | Out-Null
            }
        }
    }

    Invoke-PowerCfg @('-setactive', 'SCHEME_CURRENT')
    Write-Step 'Committed via -setactive SCHEME_CURRENT.' 'Green'

    # --- Fast startup ------------------------------------------------------
    $fastStartupResult = 'not attempted'
    if ($DisableFastStartup) {
        Write-Step ''
        Write-Step '--- Fast startup ---' 'Cyan'
        $hiberKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
        try {
            $before = (Get-ItemProperty -LiteralPath $hiberKey -Name HiberbootEnabled -ErrorAction SilentlyContinue).HiberbootEnabled
            Write-Step ("  HiberbootEnabled was: {0}" -f $(if ($null -eq $before) { 'not set' } else { $before }))

            if ($before -eq 0) {
                Write-Step '  Already disabled; no change.' 'Green'
                $fastStartupResult = 'already disabled'
            }
            else {
                Set-ItemProperty -LiteralPath $hiberKey -Name 'HiberbootEnabled' -Value 0 -Type DWord
                Write-Step '  Disabled. Effective at next shutdown.' 'Green'
                $fastStartupResult = 'disabled'
            }
        }
        catch {
            Write-Step ("  Failed: {0}" -f $_.Exception.Message) 'Yellow'
            $fastStartupResult = "failed: $($_.Exception.Message)"
        }

        # A policy-level value beats the local one. Surface it rather than fight
        # it - two sources writing this would be worse than one.
        $pol = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' `
                -Name HiberbootEnabled -ErrorAction SilentlyContinue).HiberbootEnabled
        if ($null -ne $pol) {
            Write-Step ("  POLICY HiberbootEnabled={0} present - overrides the local value." -f $pol) 'Yellow'
            $fastStartupResult += " (policy override present: $pol)"
        }
    }

    # --- Persist state -----------------------------------------------------
    # Collectable later for a fleet audit of what each device actually got.
    $state = [ordered]@{
        SeedVersion    = $SeedVersion
        AppliedUtc     = (Get-Date).ToUniversalTime().ToString('o')
        ComputerName   = $env:COMPUTERNAME
        Chassis        = $chassis
        ModernStandby  = $power.ModernStandby
        AnyStandby     = $power.AnyStandby
        HibernateAvail = $power.Hibernate
        DeviceGuardS3  = $power.DeviceGuardS3
        ProfileApplied = $profileLabel
        Adjustments    = $adjustments
        FastStartup    = $fastStartupResult
        Applied        = $applied
        Skipped        = $skipped
        RemovedSchemes = $removedSchemes
    }
    $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $StateFile -Encoding UTF8
    Save-Transcript

    Write-Step ''
    Write-Step ("Done. {0}  applied={1} skipped={2}" -f $profileLabel, $applied.Count, $skipped.Count) 'Cyan'

    # Intune truncates script output at 2048 characters.
    Write-Output ("Seed {0}: {1}, applied={2}, skipped={3}, legacy={4}, MS={5}, anyStandby={6}, fastStartup={7}" -f `
        $SeedVersion, $profileLabel, $applied.Count, $skipped.Count,
        $removedSchemes.Count, $power.ModernStandby, $power.AnyStandby, $fastStartupResult)
    exit 0
}
catch {
    Write-Step "FAILED: $($_.Exception.Message)" 'Red'
    Save-Transcript
    Write-Output "Power seed failed: $($_.Exception.Message)"
    exit 1
}