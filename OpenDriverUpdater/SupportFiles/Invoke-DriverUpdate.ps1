<#
.SYNOPSIS
    OpenDriverUpdater worker. Detects the OEM and installs applicable driver updates from the vendor's
    own online catalog, without rebooting. Emits a JSON result the PSADT launcher turns into a restart prompt.

.DESCRIPTION
    Per vendor:
      Dell   - Dell's SDP catalog (DellSDPCatalogPC.cab) evaluated locally: each package's IsInstallable rule
               tree (SystemTypeID, OS build, hardware ID + installed driver version) is checked against
               Win32_PnPEntity, applicable DUPs are downloaded from downloads.dell.com, SHA1-verified and run
               with /s (no /r). No Dell Command | Update, no Dell agent, no .NET dependency.
      Lenovo - Lenovo.Client.Update (LCU, Lenovo's packaging of LSUClient) reads download.lenovo.com/catalog
               directly. Drivers only (BIOS/firmware excluded), unattended installers only.
      HP     - HP Image Assistant CLI (analyze + install, /Category:Drivers). HPIA is fetched fresh from
               hpia.hpcloud.hp.com; it pulls Softpaqs from HP's live catalog, not a driver pack.
      Other  - PSWindowsUpdate, driver class only (Surface, Razer, Acer, custom builds).

    Exit 0 = the cycle ran (see JSON for per-item results). Exit 1 = could not run (see log).
    Runs as SYSTEM in 64-bit Windows PowerShell 5.1. Never reboots. RebootRequired is raised only by a vendor
    result (DUP exit 2, LCU PendingAction, HPIA 3010, WU RebootRequired) - never from the OS-wide pending state.
    State: last-run.json under the stateDir and the registryRoot from driverConfig.json (64-bit view).

.PARAMETER ScanOnly
    Report what would be installed without installing (Dell /scan, Lenovo Get-LnvUpdate, HPIA /Action:List,
    PSWindowsUpdate without -Install). Safe on an admin workstation.

.NOTES
    Version 1.0.0: Dell via SDP catalog rules; reboot flag from vendor results only (the OS-wide pending-reboot
    state is logged, not acted on); state mirrored to the registryRoot from driverConfig.json.
#>
[CmdletBinding()]
param(
    [switch]$ScanOnly,
    # Defaults to stateDir from driverConfig.json when not passed (the launcher always passes it explicitly).
    [string]$StateDir = '',
    [string]$LogDir   = 'C:\Windows\Logs\Software',
    # Testing aid: force a vendor path ('Dell', 'LENOVO', 'HP', 'Other') regardless of the hardware.
    [string]$VendorOverride,
    # Non-destructive check of every network dependency: Dell SDP catalog download/expand, HPIA version
    # lookup, LCU + PSWindowsUpdate gallery fetch. Installs nothing; run elevated (the state dir is ACL-hardened to
    # SYSTEM/Administrators on every run, so a non-elevated user can't write the work files). Exit 0 = all reachable.
    [switch]$SelfTest,
    # TEST AID (Dell only): regex on the package title. A matching family counts as applicable when its device is
    # present, regardless of installed version, and the DUP runs with /f (Dell's reinstall switch). Exercises the
    # whole install path on a box that is already current. Also honoured one-shot from the registry value
    # <registryRoot>\ForceTitle (deleted after the run) so a PSADT Repair can be forced without params.
    [string]$ForceTitle
)

# ---------------------------------------------------------------------------------------------------
# 64-bit relaunch guard (module cmdlets, pnputil and the OEM tools all need the native host)
# ---------------------------------------------------------------------------------------------------
if ($env:PROCESSOR_ARCHITEW6432 -and -not [Environment]::Is64BitProcess) {
    $ps64 = Join-Path $env:WINDIR 'sysnative\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path $ps64)) { Write-Error '64-bit PowerShell not found'; exit 1 }
    $fwd = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-LogDir', $LogDir)
    if ($StateDir) { $fwd += '-StateDir', $StateDir }   # only forward it when set; the child resolves it from config otherwise
    if ($ScanOnly) { $fwd += '-ScanOnly' }
    if ($SelfTest) { $fwd += '-SelfTest' }
    if ($VendorOverride) { $fwd += '-VendorOverride', $VendorOverride }
    if ($ForceTitle) { $fwd += '-ForceTitle', $ForceTitle }
    & $ps64 @fwd
    exit $LASTEXITCODE
}

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# Organization- and cadence-specific values come from driverConfig.json at the package root (this script is in SupportFiles).
$script:Cfg = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'driverConfig.json') -Raw | ConvertFrom-Json
if ([string]::IsNullOrEmpty($StateDir)) { $StateDir = [System.Environment]::ExpandEnvironmentVariables("$($script:Cfg.stateDir)") }
$script:LogFile    = Join-Path $LogDir "$($script:Cfg.taskName).log"
# Vendor installer logs (one per Dell DUP, HPIA's own folder) go in a subfolder named after the task so a cycle that
# installs eight drivers doesn't drop eight files beside the main log. Created only when an installer actually runs.
$script:VendorLogDir = Join-Path $LogDir "$($script:Cfg.taskName)"
$script:ResultFile = Join-Path $StateDir 'last-run.json'
$script:TempDir    = Join-Path $StateDir 'work'
$GalleryFindUri    = 'https://www.powershellgallery.com/api/v2/FindPackagesById()'

foreach ($d in @($StateDir, $LogDir, $script:TempDir)) { if (-not (Test-Path $d)) { $null = New-Item -Path $d -ItemType Directory -Force } }
# Everything under $StateDir is executed as SYSTEM (cached modules, HPIA, child scripts) and C:\ProgramData lets any
# user create files by default: lock it to SYSTEM/Administrators (full) + Users (read) on every run.
try {
    $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $null = & "$env:WinDir\System32\icacls.exe" $StateDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' 2>&1
    $ErrorActionPreference = $prevEap
} catch { $ErrorActionPreference = 'Stop' }

# ---------------------------------------------------------------------------------------------------
# Logging (CMTrace format, same file the launcher points at)
# ---------------------------------------------------------------------------------------------------
function Write-Log {
    param([Parameter(Mandatory)][string]$Message, [ValidateSet('1', '2', '3')][string]$Severity = '1', [string]$Component = 'DriverUpdate')
    $bias = [System.TimeZoneInfo]::Local.GetUtcOffset((Get-Date)).TotalMinutes
    $bias = if ($bias -lt 0) { "+$([math]::Abs($bias))" } else { "-$bias" }
    $line = "<![LOG[$Message]LOG]!><time=""$(Get-Date -Format 'HH:mm:ss.fff')$bias"" date=""$(Get-Date -Format 'MM-dd-yyyy')"" component=""$Component"" context=""$([Security.Principal.WindowsIdentity]::GetCurrent().Name)"" type=""$Severity"" thread=""$PID"" file="""">"
    try { Add-Content -Path $script:LogFile -Value $line -Encoding Default } catch {}
    Write-Verbose $Message
}

# Result object every vendor path fills in.
$script:Result = [ordered]@{
    Vendor         = $null
    Method         = $null
    ScanOnly       = [bool]$ScanOnly
    Started        = (Get-Date).ToString('o')
    Finished       = $null
    Installed      = @()   # @{ Title; Version }
    Failed         = @()   # @{ Title; Detail }
    Pending        = @()   # ScanOnly: what would be installed
    RebootRequired = $false
    RebootPendingSince = $null   # first cycle that asked for this restart (persisted until the box reboots)
    PromptCount    = 0           # how many cycles have asked for it, including this one (the launcher drops Cancel after N)
    Notes          = @()
}
function Add-Note([string]$Text) { $script:Result.Notes += $Text; Write-Log $Text }

function Get-GalleryModule {
    # Latest version of a PSGallery module without NuGet/PackageManagement prompts (SYSTEM-safe).
    # Returns the folder containing the .psd1. Cached under $Root\<Name>.
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Root)
    $existing = Get-ChildItem -Path (Join-Path $Root $Name) -Filter "$Name.psd1" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($existing) { return $existing.DirectoryName }
    Write-Log "Resolving $Name from the PowerShell Gallery..."
    $find = Invoke-RestMethod -Uri $GalleryFindUri -Body @{ '$filter' = 'IsLatestVersion eq true'; id = "'$Name'" }
    $entry = $find | Sort-Object { [version]$_.properties.version } -Descending | Select-Object -First 1
    if (-not $entry.content.src) { throw "Could not resolve $Name from the gallery." }
    $dest = Join-Path $Root "$Name\$($entry.properties.version)"
    $zip  = Join-Path $script:TempDir "$Name.zip"
    Invoke-RestMethod -Uri $entry.content.src -OutFile $zip
    Expand-Archive -Path $zip -DestinationPath $dest -Force
    Get-ChildItem $dest -Recurse -File | Unblock-File   # strip Mark-of-the-Web so SYSTEM can load the DLLs (SmartScreen/WDAC)
    Get-ChildItem $dest | Where-Object Name -in '_rels', 'package', '[Content_Types].xml', "$Name.nuspec" | Remove-Item -Recurse -Force
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    Write-Log "Cached $Name $($entry.properties.version) at $dest"
    return $dest
}

function Get-RemoteFile {
    # Large downloads (DUPs up to 1 GB, HPIA): BITS first - resumable, throttled by the OS, no memory buffering in
    # Windows PowerShell 5.1 - then Invoke-WebRequest as the fallback when BITS is unavailable or refuses.
    param([Parameter(Mandatory)][string]$Uri, [Parameter(Mandatory)][string]$OutFile)
    if (Test-Path $OutFile) { Remove-Item $OutFile -Force -ErrorAction SilentlyContinue }
    try {
        Import-Module BitsTransfer -ErrorAction Stop
        Start-BitsTransfer -Source $Uri -Destination $OutFile -Priority Foreground -RetryInterval 60 -RetryTimeout 600 -ErrorAction Stop
        return
    }
    catch { Write-Log "BITS download failed ($($_.Exception.Message)); falling back to Invoke-WebRequest." '2' }
    Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing
}

function Invoke-Exe {
    # Run a native exe, wait, return exit code. Output goes to the CMTrace log.
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$ArgumentList = @(), [int]$TimeoutMinutes = 180, [string]$WorkingDirectory = $script:TempDir)
    Write-Log "Running: $FilePath $($ArgumentList -join ' ')"
    $p = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -WorkingDirectory $WorkingDirectory -PassThru -WindowStyle Hidden
    if (-not $p.WaitForExit($TimeoutMinutes * 60000)) {
        try { $p.Kill() } catch {}
        throw "$([IO.Path]::GetFileName($FilePath)) exceeded $TimeoutMinutes min and was killed."
    }
    Write-Log "Exit code $($p.ExitCode) from $([IO.Path]::GetFileName($FilePath))"
    return $p.ExitCode
}

function Test-PendingReboot {
    # Informational only. The OS-wide pending-reboot state is often set by unrelated installers
    # (PendingFileRenameOperations especially), so it never drives this package's restart prompt.
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    foreach ($k in $keys) { if (Test-Path $k) { return $true } }
    $pfro = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction SilentlyContinue).PendingFileRenameOperations
    return [bool]$pfro
}

# All registry state lives here (64-bit view; the worker always runs in native 64-bit PowerShell).
$RegRoot = "$($script:Cfg.registryRoot)"
function Write-RegistryState {
    param([Parameter(Mandatory)][string]$Status)
    try {
        $r = $script:Result
        $null = New-Item -Path $RegRoot -Force
        $vals = [ordered]@{
            LastRunUtc        = [datetime]::Parse($r.Started).ToUniversalTime().ToString('o')
            LastStatus        = $Status                      # Completed | ScanOnly | CouldNotRun
            Vendor            = "$($r.Vendor)"
            Method            = "$($r.Method)"
            InstalledCount    = @($r.Installed).Count
            FailedCount       = @($r.Failed).Count
            PendingCount      = @($r.Pending).Count
            RebootRequired    = [int][bool]$r.RebootRequired
            LastResultFile    = $script:ResultFile
            WorkerVersion     = '0.1'
        }
        foreach ($k in $vals.Keys) { Set-ItemProperty -Path $RegRoot -Name $k -Value $vals[$k] }
        if ($Status -eq 'Completed') {
            # The launcher's once-a-month gate keys off this; scan-only and failed runs must not advance it.
            Set-ItemProperty -Path $RegRoot -Name LastCycleUtc -Value $vals.LastRunUtc
            # Restart bookkeeping: remember the ask until the box actually reboots (see Update-RebootMarker).
            if ($r.RebootRequired) {
                if (-not $r.RebootPendingSince) { $r.RebootPendingSince = $vals.LastRunUtc }
                Set-ItemProperty -Path $RegRoot -Name RebootPendingSince -Value $r.RebootPendingSince
                Set-ItemProperty -Path $RegRoot -Name BootTimeAtFlag -Value (Get-LastBootUtc)
                Set-ItemProperty -Path $RegRoot -Name PromptCount -Value ([int]$r.PromptCount)
            }
            else {
                foreach ($n in 'RebootPendingSince', 'BootTimeAtFlag', 'PromptCount') { Remove-ItemProperty -Path $RegRoot -Name $n -ErrorAction SilentlyContinue }
            }
            $inst = Join-Path $RegRoot 'Installed'   # one value per package: Title = "Version (yyyy-MM-dd)"; grows over time
            $null = New-Item -Path $inst -Force
            foreach ($i in @($r.Installed)) { Set-ItemProperty -Path $inst -Name $i.Title -Value "$($i.Version) ($(Get-Date -Format 'yyyy-MM-dd'))" }
        }
    }
    catch { Write-Log "Could not write registry state: $($_.Exception.Message)" '2' }
}

function Get-LastBootUtc { (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o') }

function Update-RebootMarker {
    # A restart we asked for in an earlier cycle stays "required" until the machine has actually rebooted since
    # then. Each cycle that has to ask again bumps PromptCount; the launcher removes the Cancel button once that
    # passes its limit. That is the whole deferral/deadline model - no separate schedule, no extra prompts.
    $m = Get-ItemProperty -Path $RegRoot -ErrorAction SilentlyContinue
    if (-not $m -or -not $m.RebootPendingSince) { return }
    $rebooted = $false
    try { $rebooted = ([datetime]::Parse($m.BootTimeAtFlag) -lt [datetime]::Parse((Get-LastBootUtc)).AddSeconds(-30)) } catch { $rebooted = $true }
    if ($rebooted) {
        Add-Note "Restart requested on $($m.RebootPendingSince) has been completed; clearing the pending flag."
        if (-not $ScanOnly) { foreach ($n in 'RebootPendingSince', 'BootTimeAtFlag', 'PromptCount') { Remove-ItemProperty -Path $RegRoot -Name $n -ErrorAction SilentlyContinue } }
        return
    }
    $script:Result.RebootRequired = $true
    $script:Result.RebootPendingSince = $m.RebootPendingSince
    $script:Result.PromptCount = [int]$m.PromptCount
    Add-Note "Restart requested on $($m.RebootPendingSince) is still pending (asked $($m.PromptCount) time(s) so far)."
}

# ---------------------------------------------------------------------------------------------------
# MARK: Dell - straight from Dell's SDP catalog (DellSDPCatalogPC.cab), no DCU, no Dell agent
# ---------------------------------------------------------------------------------------------------
# DellSDPCatalogPC.cab is the WSUS/ConfigMgr feed Dell keeps current (CatalogPC.cab was retired Dec 2025;
# CatalogIndexPC.cab lists packages per model but carries hardware IDs on only ~5 % of driver packages).
# Every SDP package embeds an <sdp:IsInstallable> rule tree that DCU/ConfigMgr evaluate through Dell's
# inventory WMI class. The predicates are simple enough to evaluate against Win32_PnPEntity directly:
#   Dell_OEMComputerSystem WHERE SystemTypeID = 'n' OR ...                       -> our SystemID in list
#   Dell_SoftwareIdentity WHERE OSBuildNumber >= 'n'                              -> OS build compare
#   Dell_SoftwareIdentity WHERE (Description LIKE 'Dell:DRVR_<DEV>_<VEN>[_<SUBDEV>_<SUBVEN>]_%') AND VersionString < 'v'
#   Dell_SoftwareIdentity WHERE (HardwareID LIKE 'ACPI\INT33D5%') AND VersionString < 'v'
#                                                                                 -> a present device + older driver
#   bar:WindowsVersion / bar:Processor                                            -> OS major.minor / x64
# Anything else evaluates FALSE (conservative: never install on a rule we do not understand).
$DellCatalogUri = 'https://downloads.dell.com/catalog/DellSDPCatalogPC.cab'

function Get-DellSystemTypeId {
    $sku = (Get-ItemProperty 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' -ErrorAction SilentlyContinue).SystemSKU
    if (-not $sku) { $sku = (Get-CimInstance Win32_ComputerSystem).SystemSKUNumber }
    if ($sku -notmatch '^[0-9A-Fa-f]{3,4}$') { throw "Unexpected Dell SystemID [$sku]." }
    return [Convert]::ToInt32($sku, 16)
}

function Get-DellCatalogXml {
    # Downloads + expands the SDP catalog; returns the XML path. ~11 MB cab -> ~175 MB XML.
    $cab = Join-Path $script:TempDir 'DellSDPCatalogPC.cab'
    $dir = Join-Path $script:TempDir 'sdp'
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    $null = New-Item -Path $dir -ItemType Directory -Force
    Write-Log 'Downloading Dell SDP catalog...'
    Invoke-WebRequest -Uri $DellCatalogUri -OutFile $cab -UseBasicParsing
    $null = & (Join-Path $env:WINDIR 'System32\expand.exe') '-F:DellSDPCatalogPC.xml' $cab $dir
    Remove-Item $cab -Force -ErrorAction SilentlyContinue
    $xml = Join-Path $dir 'DellSDPCatalogPC.xml'
    if (-not (Test-Path $xml)) { throw 'DellSDPCatalogPC.xml not found after expanding the cab.' }
    return $xml
}

function Get-LocalDeviceInventory {
    # One row per (device, hardware/compatible id) with the installed driver version. Mirrors Dell_SoftwareIdentity.
    $drv = @{}
    foreach ($d in Get-CimInstance Win32_PnPSignedDriver | Where-Object { $_.DeviceID -and $_.DriverVersion }) { $drv[$d.DeviceID] = $d.DriverVersion }
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($e in Get-CimInstance Win32_PnPEntity | Where-Object { $_.HardwareID -and $drv.ContainsKey($_.DeviceID) }) {
        $ver = $drv[$e.DeviceID]
        foreach ($id in @($e.HardwareID) + @($e.CompatibleID)) {
            if (-not $id) { continue }
            $u = $id.ToUpper()
            $ven = $dev = $subdev = $subven = $null
            if ($u -match '(?:VEN|VID)_([0-9A-F]{4})') { $ven = $Matches[1] }
            if ($u -match '(?:DEV|PID)_([0-9A-F]{4})') { $dev = $Matches[1] }
            if ($u -match 'SUBSYS_([0-9A-F]{4})([0-9A-F]{4})') { $subdev = $Matches[1]; $subven = $Matches[2] }
            $rows.Add([pscustomobject]@{ Id = $u; Ven = $ven; Dev = $dev; SubDev = $subdev; SubVen = $subven; Ver = $ver; Name = $e.Name })
        }
    }
    return $rows
}

function ConvertTo-DellVersionString([string]$v) {
    # Sort key only (newest-per-family ordering): each part zero-padded to 6 digits so 26100 sorts above 9999.
    $parts = @(($v -split '[.,]') | ForEach-Object { $n = 0; [void][int]::TryParse($_, [ref]$n); '{0:D6}' -f $n })
    while ($parts.Count -lt 4) { $parts += '000000' }
    return ($parts -join '.')
}

function Compare-DellVersion([string]$Have, [string]$Want) {
    # Numeric, part by part (missing parts = 0). Dell's VersionString thresholds are zero-padded but inbox drivers
    # carry 5-digit parts (10.0.26100.x), so an ordinal string compare misorders them. Returns -1 / 0 / 1.
    $a = @(($Have -split '[.,]') | ForEach-Object { $n = 0; [void][int]::TryParse($_, [ref]$n); $n })
    $b = @(($Want -split '[.,]') | ForEach-Object { $n = 0; [void][int]::TryParse($_, [ref]$n); $n })
    $len = [Math]::Max($a.Count, $b.Count)
    for ($i = 0; $i -lt $len; $i++) {
        $x = if ($i -lt $a.Count) { $a[$i] } else { 0 }
        $y = if ($i -lt $b.Count) { $b[$i] } else { 0 }
        if ($x -lt $y) { return -1 }
        if ($x -gt $y) { return 1 }
    }
    return 0
}

function Test-DellRule {
    # Recursive evaluator over one IsInstallable rule node. $Ctx = @{ SystemTypeId; Build; Inventory; Unsupported (List) }
    param([Parameter(Mandatory)][System.Xml.XmlNode]$Node, [Parameter(Mandatory)][hashtable]$Ctx)
    $kids = @($Node.ChildNodes | Where-Object { $_.NodeType -eq 'Element' })
    switch ($Node.LocalName) {
        'And' { foreach ($k in $kids) { if (-not (Test-DellRule $k $Ctx)) { return $false } }; return $true }
        'Or'  { foreach ($k in $kids) { if (Test-DellRule $k $Ctx) { return $true } }; return $false }
        'Not' { return -not (Test-DellRule $kids[0] $Ctx) }
        'WindowsVersion' {
            $want = [version]"$($Node.MajorVersion).$($Node.MinorVersion)"; $have = [version]"$([Environment]::OSVersion.Version.Major).$([Environment]::OSVersion.Version.Minor)"
            switch ($Node.Comparison) { 'EqualTo' { return $have -eq $want } 'GreaterThanOrEqualTo' { return $have -ge $want } 'GreaterThan' { return $have -gt $want } 'LessThan' { return $have -lt $want } 'LessThanOrEqualTo' { return $have -le $want } default { return $false } }
        }
        'Processor' { return ($Node.Architecture -eq $(if ([Environment]::Is64BitOperatingSystem) { if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { '12' } else { '9' } } else { '0' })) }
        'WmiQuery' {
            $q = $Node.WqlQuery
            if ($q -match "FROM Dell_OEMComputerSystem WHERE (.+)$") {
                $ids = [regex]::Matches($Matches[1], "SystemTypeID = '(\d+)'") | ForEach-Object { [int]$_.Groups[1].Value }
                return ($ids -contains $Ctx.SystemTypeId)
            }
            if ($q -match "FROM Dell_SoftwareIdentity WHERE OSBuildNumber\s*(>=|<=|>|<|=)\s*'(\d+)'") {
                $n = [int]$Matches[2]; $b = $Ctx.Build
                switch ($Matches[1]) { '>=' { return $b -ge $n } '<=' { return $b -le $n } '>' { return $b -gt $n } '<' { return $b -lt $n } '=' { return $b -eq $n } }
            }
            # Range form "(Description >= 'X' AND Description < 'X~')" is Dell's other spelling of "Description LIKE 'X%'".
            $q = $q -replace "\(Description >= '([^']+)' AND Description < '\1~'\)", "(Description LIKE '`$1%')"
            # Device predicate: (Description LIKE 'Dell:DRVR_...') or (HardwareID LIKE '...'), optionally AND VersionString <op> 'v'.
            # Without a version clause it is a presence check (the AMD packages use that shape).
            if ($q -match "FROM Dell_SoftwareIdentity WHERE \((Description|HardwareID) LIKE '([^']+)'\)(?: AND VersionString\s*(<|<=|>|>=|=)\s*'([0-9.]+)')?\s*$") {
                $kind = $Matches[1]; $like = $Matches[2]; $op = $Matches[3]; $thr = $Matches[4]
                $devices = @()
                if ($kind -eq 'Description' -and $like -match '^Dell:DRVR_([0-9A-F]{4})_([0-9A-F]{4})(?:_([0-9A-F]{4})_([0-9A-F]{4}))?(?:_[^_%]+)*_%$') {
                    $dev = $Matches[1]; $ven = $Matches[2]; $subdev = $Matches[3]; $subven = $Matches[4]
                    $devices = @($Ctx.Inventory | Where-Object { $_.Ven -eq $ven -and $_.Dev -eq $dev -and (-not $subdev -or -not $_.SubDev -or ($_.SubDev -eq $subdev -and $_.SubVen -eq $subven)) })
                }
                elseif ($kind -eq 'HardwareID' -or $like -match '^Dell:DRVR_.*\\') {
                    # A hardware-ID pattern (ACPI\INT33D5%, SWC\VID1002&PID0001%, ROOT\AMDLOG_%): SQL LIKE -> regex on the id.
                    $pat = $like -replace '^Dell:DRVR_', ''
                    $pat = '^' + ([regex]::Escape($pat.Replace('\\', '\').ToUpper()) -replace '%', '.*' -replace '_', '.')
                    $devices = @($Ctx.Inventory | Where-Object { $_.Id -match $pat })
                }
                else { $Ctx.Unsupported.Add($like); return $false }
                if (-not $op -or $Ctx.IgnoreVersion) { if ($devices.Count) { $Ctx.Hits.Add("$like <- $($devices[0].Name) present$(if ($Ctx.IgnoreVersion) { ' (FORCED, version ignored)' })"); [void]$Ctx.HitIds.Add($devices[0].Id) }; return [bool]$devices.Count }
                foreach ($d in $devices) {
                    $c = Compare-DellVersion -Have $d.Ver -Want $thr
                    $ok = switch ($op) { '<' { $c -lt 0 } '<=' { $c -le 0 } '>' { $c -gt 0 } '>=' { $c -ge 0 } '=' { $c -eq 0 } }
                    if ($ok) { $Ctx.Hits.Add("$like <- $($d.Name) [$($d.Id)] has $($d.Ver), rule wants $op $thr"); [void]$Ctx.HitIds.Add($d.Id); return $true }
                }
                return $false
            }
            $Ctx.Unsupported.Add($q); return $false
        }
        default { $Ctx.Unsupported.Add($Node.LocalName); return $false }
    }
}

function Get-DellApplicableUpdates {
    # Streams the SDP catalog, collects driver packages for this SystemTypeID, then evaluates ONLY the newest
    # version of each package family (base title). Older releases of a family are never offered: Dell's older
    # packages can carry rules written against an earlier version scheme (seen on Intel ME), which would read as
    # "applicable" forever. Newest-only mirrors what Dell Command | Update offers in practice.
    param([Parameter(Mandatory)][string]$XmlPath, [Parameter(Mandatory)][int]$SystemTypeId, [string]$ForceTitle)
    $ctx = @{ SystemTypeId = $SystemTypeId; IgnoreVersion = $false; Build = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuildNumber; Inventory = (Get-LocalDeviceInventory); Unsupported = (New-Object System.Collections.Generic.List[string]); Hits = (New-Object System.Collections.Generic.List[string]); HitIds = (New-Object 'System.Collections.Generic.HashSet[string]') }
    Write-Log "Local inventory: $($ctx.Inventory.Count) hardware/compatible ids with drivers; SystemTypeID $SystemTypeId; build $($ctx.Build)"
    $needle = "SystemTypeID = '$SystemTypeId'"
    $reader = [IO.StreamReader]::new($XmlPath)
    $nsDecl = $null; $sb = [Text.StringBuilder]::new(); $inPkg = $false
    $candidates = @(); $seen = 0; $superseded = New-Object 'System.Collections.Generic.HashSet[string]'
    try {
        while ($null -ne ($line = $reader.ReadLine())) {
            if (-not $nsDecl -and $line.Contains('<smc:SystemsManagementCatalog')) { $nsDecl = ([regex]::Matches($line, 'xmlns:\w+="[^"]+"') | ForEach-Object { $_.Value }) -join ' ' }
            if (-not $inPkg) { if ($line.Contains('<smc:SoftwareDistributionPackage')) { $inPkg = $true; [void]$sb.Clear(); [void]$sb.AppendLine($line) }; continue }
            [void]$sb.AppendLine($line)
            if (-not $line.Contains('</smc:SoftwareDistributionPackage>')) { continue }
            $inPkg = $false
            $frag = $sb.ToString()
            if (-not $frag.Contains($needle)) { continue }
            $seen++
            # Driver-class packages only: their rules test a device (Dell:DRVR_ / HardwareID). Applications (Dell:APAC_ /
            # PackageVersion), BIOS and firmware are out of scope here.
            if (-not ($frag.Contains("Dell:DRVR_") -or $frag.Contains("HardwareID LIKE"))) { continue }
            [xml]$p = "<root $nsDecl>$frag</root>"
            $pkg = $p.root.SoftwareDistributionPackage
            $title = $pkg.LocalizedProperties.Title
            # Supersedence: a newer package lists the ids it replaces; superseded packages are never offered.
            foreach ($sid in @($pkg.SupersededPackages.PackageID)) { if ($sid) { [void]$superseded.Add($sid.ToUpper()) } }
            $item = $pkg.InstallableItem
            $prog = $item.CommandLineInstallerData
            if (-not $prog -or $title -match 'BIOS|Firmware') { continue }
            $rule = $item.ApplicabilityRules.IsInstallable
            if (-not $rule) { continue }
            $top = @($rule.ChildNodes | Where-Object { $_.NodeType -eq 'Element' })
            if (-not $top.Count) { continue }
            $ver = if ($title -match ',([0-9][0-9A-Za-z.]*),') { $Matches[1] } else { '' }
            $candidates += [pscustomobject]@{
                PackageId = "$($pkg.Properties.PackageID)".ToUpper()
                Title = $title; Base = ($title -replace ',.*$'); Version = $ver; SortKey = (ConvertTo-DellVersionString $ver)
                Rule = $top[0]
                Url = $item.OriginFile.OriginUri; FileName = $item.OriginFile.FileName; Size = [long]$item.OriginFile.Size; Sha1 = $item.OriginFile.Digest
                Arguments = $prog.Arguments; Reboot = ($item.InstallProperties.RebootBehavior -ne 'NeverReboots')
                RebootCodes = @($prog.ReturnCode | Where-Object { $_.Reboot -eq 'true' } | ForEach-Object { [int]$_.Code })
                SuccessCodes = @($prog.ReturnCode | Where-Object { $_.Result -eq 'Succeeded' } | ForEach-Object { [int]$_.Code })
            }
        }
    }
    finally { $reader.Dispose() }
    $live = @($candidates | Where-Object { -not $superseded.Contains($_.PackageId) })
    Write-Log "Catalog: $seen package(s) list SystemTypeID $SystemTypeId; $($candidates.Count) driver-class candidate(s), $($live.Count) after supersedence."
    $found = @()
    foreach ($family in ($live | Group-Object Base)) {
        $newest = $family.Group | Sort-Object SortKey -Descending | Select-Object -First 1
        $ctx.Unsupported.Clear(); $ctx.Hits.Clear(); $ctx.HitIds.Clear()
        $ctx.IgnoreVersion = [bool]($ForceTitle -and $newest.Title -match $ForceTitle)
        $newest | Add-Member -NotePropertyName Force -NotePropertyValue $ctx.IgnoreVersion -Force
        $applicable = Test-DellRule -Node $newest.Rule -Ctx $ctx
        if ($ctx.Unsupported.Count) { Write-Log "  skipped rule(s) in [$($newest.Title)]: $(($ctx.Unsupported | Select-Object -Unique -First 3) -join ' | ')" '2' }
        if (-not $applicable) { continue }
        # Say exactly which device predicate made the package applicable - the audit trail for every install.
        foreach ($h in $ctx.Hits) { Write-Log "  why [$($newest.Title)]: $h" }
        $newest | Add-Member -NotePropertyName HitIds -NotePropertyValue @($ctx.HitIds) -Force
        $found += $newest
    }
    # Dell names one driver family several ways (e.g. three NVIDIA "Quadro ..." titles all covering the RTX A2000).
    # When two applicable packages were triggered by the same device, keep only the newest.
    $kept = @()
    foreach ($f in ($found | Sort-Object SortKey -Descending)) {
        $dup = $kept | Where-Object { $k = $_; @($f.HitIds | Where-Object { $k.HitIds -contains $_ }).Count } | Select-Object -First 1
        if ($dup) { Write-Log "  dropped [$($f.Title)]: same device already covered by newer [$($dup.Title)]" } else { $kept += $f }
    }
    Write-Log "$($kept.Count) package(s) applicable (newest release per family and per device)."
    return $kept
}

function Invoke-DellUpdate {
    $script:Result.Method = 'Dell SDP catalog (DellSDPCatalogPC.cab) + DUP /s'
    $sysId = Get-DellSystemTypeId
    $xml = Get-DellCatalogXml
    # @(): under Windows PowerShell 5.1 a single returned object has no .Count, so one applicable package read as none.
    $updates = @(Get-DellApplicableUpdates -XmlPath $xml -SystemTypeId $sysId -ForceTitle $ForceTitle)
    Remove-Item (Split-Path $xml) -Recurse -Force -ErrorAction SilentlyContinue
    if (-not $updates.Count) { Add-Note 'Dell: no applicable driver updates.'; return }
    foreach ($u in $updates) { Write-Log "  applicable: $($u.Title) ($([math]::Round($u.Size / 1MB)) MB)$(if ($u.Force) { ' [FORCED reinstall]' })" }
    if ($ScanOnly) { $script:Result.Pending = @($updates | ForEach-Object { @{ Title = $_.Base; Version = $_.Version; Forced = [bool]$_.Force } }); return }

    $dl = Join-Path $script:TempDir 'dups'
    if (-not (Test-Path $dl)) { $null = New-Item -Path $dl -ItemType Directory -Force }
    $sha1 = [Security.Cryptography.SHA1]::Create()
    # Download and verify everything first: a network driver install can cut connectivity mid-run.
    $ready = @()
    foreach ($u in $updates) {
        $dup = Join-Path $dl $u.FileName
        try {
            Write-Log "Downloading $($u.FileName) ($([math]::Round($u.Size / 1MB)) MB)..."
            Get-RemoteFile -Uri $u.Url -OutFile $dup
            $fs = [IO.File]::OpenRead($dup); try { $digest = [Convert]::ToBase64String($sha1.ComputeHash($fs)) } finally { $fs.Dispose() }
            if ((Get-Item $dup).Length -ne $u.Size -or $digest -ne $u.Sha1) { throw "download verification failed (size/SHA1 mismatch)" }
            $ready += $u
        }
        catch {
            $script:Result.Failed += @{ Title = $u.Base; Detail = "download: $($_.Exception.Message)" }
            Write-Log "FAILED download: $($u.Title) - $($_.Exception.Message)" '3'
            Remove-Item $dup -Force -ErrorAction SilentlyContinue
        }
    }
    $sha1.Dispose()
    foreach ($u in $ready) {
        $dup = Join-Path $dl $u.FileName
        try {
            $null = New-Item -Path $script:VendorLogDir -ItemType Directory -Force
            $log = Join-Path $script:VendorLogDir "Dell-$($u.FileName -replace '\.exe$').log"
            # /s = silent; no /r so the DUP never reboots; exit 2 = success + reboot required (from the catalog's ReturnCode list)
            # /f only on a forced test run: lets the DUP reinstall the same version instead of exiting 3.
            $dupArgs = @($u.Arguments) + $(if ($u.Force) { '/f' }) + "/l=`"$log`"" | Where-Object { $_ }
            $code = Invoke-Exe -FilePath $dup -ArgumentList $dupArgs -TimeoutMinutes 60
            # DUP framework codes are fixed (0 ok, 2 ok + reboot, 6 = it is rebooting, which /s without /r should never
            # do); honour them even when a catalog entry lists only some of them.
            if ($code -in $u.SuccessCodes -or $code -in 0, 2, 6) {
                $script:Result.Installed += @{ Title = $u.Base; Version = $u.Version }
                if ($code -in $u.RebootCodes -or $code -in 2, 6) { $script:Result.RebootRequired = $true }
                Write-Log "Installed: $($u.Title) (exit $code)"
            }
            elseif ($code -in 3, 5, 8) {
                # DUP's own applicability: 3 = same/older already installed, 5 = not applicable, 8 = downgrade blocked
                Add-Note "Dell: DUP declined $($u.Base) (exit $code); catalog rule matched but the package's own check did not."
            }
            else { throw "DUP exit $code (see $log)" }
        }
        catch {
            $script:Result.Failed += @{ Title = $u.Base; Detail = $_.Exception.Message }
            Write-Log "FAILED: $($u.Title) - $($_.Exception.Message)" '3'
        }
        finally { Remove-Item $dup -Force -ErrorAction SilentlyContinue }
    }
}

# ---------------------------------------------------------------------------------------------------
# MARK: Lenovo - LCU (LSUClient) straight from download.lenovo.com/catalog
# ---------------------------------------------------------------------------------------------------
$LenovoChild = @'
param([Parameter(Mandatory)][string]$ModulePath, [Parameter(Mandatory)][string]$DownloadDir, [Parameter(Mandatory)][string]$ResultFile, [switch]$ScanOnly)
$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'
$out = @()
try {
    Import-Module $ModulePath 3>$null 6>$null
    # Session-0 installers that pop a GUI look like hangs; cap them (cmdlet exists on LSUClient 1.5+/LCU).
    if (Get-Command Set-LnvClientConfiguration -ErrorAction SilentlyContinue) { Set-LnvClientConfiguration -MaxInstallerRuntime (New-TimeSpan -Minutes 30) -MaxExtractRuntime (New-TimeSpan -Minutes 10) 3>$null 6>$null }
    $updates = @(Get-LnvUpdate -WarningAction SilentlyContinue 3>$null 6>$null | Where-Object {
        $_.Installer.Unattended -and $_.Type -ne 'BIOS' -and $_.Type -ne 'Firmware' -and $_.RebootType -ne 5 -and
        $_.Category -notmatch 'BIOS|UEFI|Firmware' -and $_.Title -notmatch 'BIOS|UEFI|Firmware' })
    if ($ScanOnly) {
        foreach ($u in $updates) { $out += [pscustomobject]@{ ID = $u.ID; Title = $u.Title; Version = "$($u.Version)"; Pending = $true } }
    } else {
        # Download everything first: a network driver install can cut connectivity mid-run.
        foreach ($u in $updates) { $null = $u | Save-LnvUpdate -Path $DownloadDir 3>$null 6>$null }
        foreach ($u in $updates) {
            try {
                $r = Install-LnvUpdate -Package $u -Path $DownloadDir 3>$null 6>$null
                $out += [pscustomobject]@{ ID = $u.ID; Title = $u.Title; Version = "$($u.Version)"; Success = [bool]$r.Success; PendingAction = "$($r.PendingAction)"; ExitCode = $r.ExitCode; FailureReason = "$($r.FailureReason)" }
            } catch {
                $out += [pscustomobject]@{ ID = $u.ID; Title = $u.Title; Version = "$($u.Version)"; Success = $false; FailureReason = "$($_.Exception.Message)" }
            }
        }
    }
    # The result goes to a file, never stdout: any stray Write-Host/Warning from the module would corrupt it.
    Set-Content -Path $ResultFile -Value (ConvertTo-Json -InputObject $out -Compress -Depth 4) -Encoding UTF8
    exit 0
}
catch {
    # Partial results are still worth having (drivers may already be installed); the exit code tells the parent.
    try { Set-Content -Path $ResultFile -Value (ConvertTo-Json -InputObject $out -Compress -Depth 4) -Encoding UTF8 } catch {}
    [Console]::Error.WriteLine("LCU child: $($_.Exception.Message)")
    exit 1
}
'@

function Invoke-LenovoUpdate {
    $script:Result.Method = 'Lenovo.Client.Update (catalog)'
    $modDir = Get-GalleryModule -Name 'Lenovo.Client.Update' -Root (Join-Path $StateDir 'Modules')
    $psd1 = Join-Path $modDir 'Lenovo.Client.Update.psd1'
    $dl = Join-Path $StateDir 'lnv'
    if ($dl -match ' ') { throw "LCU refuses a download path with spaces: $dl" }
    if (-not (Test-Path $dl)) { $null = New-Item -Path $dl -ItemType Directory -Force }
    # LCU's ScriptsToProcess classes only resolve in a fresh session that imports the module first,
    # so every LCU call runs in its own powershell.exe (same pattern as the Lenovo BIOS remediation).
    $child = Join-Path $script:TempDir 'lnv-child.ps1'
    $resFile = Join-Path $script:TempDir 'lnv-result.json'; $outFile = Join-Path $script:TempDir 'lnv-child.out'; $errFile = Join-Path $script:TempDir 'lnv-child.err'
    Remove-Item $resFile, $outFile, $errFile -Force -ErrorAction SilentlyContinue
    Set-Content -Path $child -Value $LenovoChild -Encoding UTF8
    $argList = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', "`"$child`"", '-ModulePath', "`"$psd1`"", '-DownloadDir', "`"$dl`"", '-ResultFile', "`"$resFile`"")
    if ($ScanOnly) { $argList += '-ScanOnly' }
    Write-Log 'Running LCU child process...'
    # Start-Process with redirected streams: the module's console chatter can never reach the result, and stderr
    # cannot become a terminating NativeCommandError in this (ErrorActionPreference = Stop) process.
    $p = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $argList -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $null = $p.Handle   # cache the SafeHandle NOW: without this, Start-Process -PassThru + redirected streams reaps
                        # the process and $p.ExitCode reads back $null, which then falsely looks like a failure.
    if (-not $p.WaitForExit(150 * 60000)) { try { $p.Kill() } catch {}; throw 'LCU child process exceeded 150 min and was killed.' }
    $code = $p.ExitCode
    $childErr = ''
    foreach ($f in $outFile, $errFile) { if ((Test-Path $f) -and (Get-Item $f).Length -gt 0) { $c = (Get-Content $f -Raw).Trim(); if ($f -eq $errFile) { $childErr = $c }; Write-Log "LCU child $([IO.Path]::GetExtension($f).TrimStart('.')): $c" '2' } }
    $items = @()
    if (Test-Path $resFile) {
        $text = (Get-Content $resFile -Raw).Trim()
        # ForEach-Object unrolls: under Windows PowerShell 5.1 ConvertFrom-Json returns a JSON array as ONE array
        # object, which would otherwise be treated as a single update with array-valued Title/Version.
        if ($text) { $items = @(ConvertFrom-Json $text | ForEach-Object { $_ }) }
    }
    Remove-Item $child, $outFile, $errFile, $resFile -Force -ErrorAction SilentlyContinue
    # The child exits non-zero AND writes "LCU child: <error>" to stderr only from its catch block. ExitCode through
    # Start-Process can still be $null even with the handle cached, so a genuine non-zero code OR that stderr marker
    # is the failure signal - never a bare $null (which is what produced the phantom "Failed" on a good scan).
    $failed = (($null -ne $code) -and ($code -ne 0)) -or ($childErr -match 'LCU child:')
    if ($failed -and -not $items.Count) { throw "LCU child process failed (exit $code); see the log lines above." }
    if ($failed) { $script:Result.Failed += @{ Title = 'LCU'; Detail = "child process failed (exit $code) after $($items.Count) item(s); see log" } }
    if (-not $items.Count) { Add-Note 'Lenovo: no applicable driver updates.'; return }
    $suggested = 0
    foreach ($i in $items) {
        if ($ScanOnly) { $script:Result.Pending += @{ Title = $i.Title; Version = $i.Version }; Write-Log "  found: $($i.Title) $($i.Version)"; continue }
        if ($i.Success) {
            $script:Result.Installed += @{ Title = $i.Title; Version = $i.Version }
            # Only a MANDATORY reboot (or a SHUTDOWN, which needs a full power cycle) actually requires a restart:
            # LSUClient's REBOOT_SUGGESTED means the driver is installed and working, only *recommending* a reboot, so
            # let that piggyback on the next scheduled/monthly reboot instead of forcing one.
            if ($i.PendingAction -match 'MANDATORY|SHUTDOWN') { $script:Result.RebootRequired = $true }
            elseif ($i.PendingAction -match 'REBOOT') { $suggested++ }
            Write-Log "Installed: $($i.Title) $($i.Version) (PendingAction=$($i.PendingAction))"
        } else {
            $script:Result.Failed += @{ Title = $i.Title; Detail = "$($i.FailureReason) exit=$($i.ExitCode)" }
            Write-Log "FAILED: $($i.Title) - $($i.FailureReason) (exit $($i.ExitCode))" '3'
        }
    }
    if ($suggested -and -not $script:Result.RebootRequired) { Add-Note "Lenovo: $suggested driver(s) suggest (but do not require) a restart; it will complete at the next scheduled reboot." }
    Remove-Item $dl -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------------------------------
# MARK: HP - HP Image Assistant CLI (Softpaqs from HP's live catalog)
# ---------------------------------------------------------------------------------------------------
function Resolve-HPIALatest {
    # HP publishes the current HPIA Softpaq URL + version in a tiny cab. Returns @{ Url; Version }.
    $cab = Join-Path $script:TempDir 'HPIAMsg.cab'; $xml = Join-Path $script:TempDir 'HPIAMsg.xml'
    Invoke-WebRequest -Uri 'https://hpia.hpcloud.hp.com/HPIAMsg.cab' -OutFile $cab -UseBasicParsing
    $null = & (Join-Path $env:WINDIR 'System32\expand.exe') $cab $xml
    [xml]$msg = Get-Content $xml -Raw
    Remove-Item $cab, $xml -Force -ErrorAction SilentlyContinue
    return @{ Url = $msg.ImagePal.HPIALatest.SoftpaqURL; Version = $msg.ImagePal.HPIALatest.Version }
}

function Get-HPIA {
    # Returns the path to a current HPImageAssistant.exe, downloading/extracting when needed.
    $root = Join-Path $StateDir 'HPIA'
    $exe  = Join-Path $root 'HPImageAssistant.exe'
    $latest = Resolve-HPIALatest
    $url = $latest.Url; $ver = $latest.Version
    if ((Test-Path $exe) -and ((Get-Item $exe).VersionInfo.FileVersion -match [regex]::Escape($ver))) { Write-Log "HPIA $ver already present."; return $exe }
    Write-Log "Downloading HPIA $ver..."
    $sp = Join-Path $script:TempDir ([IO.Path]::GetFileName($url))
    Get-RemoteFile -Uri $url -OutFile $sp
    if (-not (Test-Path $root)) { $null = New-Item -Path $root -ItemType Directory -Force }
    # The Softpaq wrapper returns 1168 after an extract-only run even when it succeeded; the exe's presence is the test.
    $code = Invoke-Exe -FilePath $sp -ArgumentList @('/s', '/f', '.\', '/e') -WorkingDirectory $root -TimeoutMinutes 10
    Remove-Item $sp -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path $exe)) { throw "HPIA extraction failed (exit $code)." }
    return $exe
}

function Invoke-HPUpdate {
    $script:Result.Method = 'HP Image Assistant CLI'
    $exe = Get-HPIA
    $report = Join-Path $StateDir 'HPIA-Report'
    if (Test-Path $report) { Remove-Item $report -Recurse -Force }
    $action = if ($ScanOnly) { 'List' } else { 'Install' }
    # /IgnoreGenericOsError: when HP has no reference file yet for this platform + Windows build (a new feature update
    # ahead of HP's data), HPIA uses its generic reference file and would otherwise return 4104 instead of 0/3010/3020.
    $hpiaArgs = @('/Operation:Analyze', '/Category:Drivers', '/Selection:All', "/Action:$action", '/Silent', '/Noninteractive', '/IgnoreGenericOsError',
                  "/ReportFolder:`"$report`"", "/LogFolder:`"$($script:VendorLogDir)\HPIA`"", "/SoftpaqDownloadFolder:`"$($script:TempDir)\HPIA-Softpaqs`"")
    $null = New-Item -Path $script:VendorLogDir -ItemType Directory -Force
    $code = Invoke-Exe -FilePath $exe -ArgumentList $hpiaArgs -TimeoutMinutes 180
    # Recommendations XML lists what was found; harvest titles for the summary.
    $rec = Get-ChildItem $report -Filter '*.xml' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    $found = @()
    if ($rec) {
        try {
            [xml]$r = Get-Content $rec.FullName -Raw
            $found = @($r.SelectNodes('//Recommendation') | ForEach-Object { @{ Title = $_.Solution.Softpaq.Name; Version = $_.Solution.Softpaq.Version } } | Where-Object { $_.Title })
        } catch { Write-Log "Could not parse HPIA report: $($_.Exception.Message)" '2' }
    }
    foreach ($f in $found) { Write-Log "  found: $($f.Title) $($f.Version)" }
    switch ($code) {
        0    { if ($ScanOnly) { $script:Result.Pending = $found } else { $script:Result.Installed = $found; Add-Note 'HP: driver updates installed, no reboot needed.' } }
        256  { Add-Note 'HP: no driver recommendations.' }
        257  { Add-Note 'HP: no drivers selected/applicable.' }
        3010 { $script:Result.Installed = $found; $script:Result.RebootRequired = $true; Add-Note 'HP: driver updates installed, reboot required.' }
        3020 { $script:Result.RebootRequired = $true; $script:Result.Failed += @{ Title = 'HPIA'; Detail = "One or more of $($found.Count) Softpaq(s) failed to install (3020); see HPIA log." }; Add-Note 'HP: partial install (3020); HPIA does not say which, so none are recorded as installed.' }
        default { throw "HPIA returned $code (see $($script:VendorLogDir)\HPIA)." }
    }
    Remove-Item (Join-Path $script:TempDir 'HPIA-Softpaqs') -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------------------------------
# MARK: Everyone else - Windows Update, driver class only
# ---------------------------------------------------------------------------------------------------
function Invoke-WindowsUpdateDrivers {
    $script:Result.Method = 'PSWindowsUpdate (driver class)'
    $modDir = Get-GalleryModule -Name 'PSWindowsUpdate' -Root (Join-Path $StateDir 'Modules')
    Import-Module (Join-Path $modDir 'PSWindowsUpdate.psd1') -ErrorAction Stop
    # The update rings set "Windows drivers: Block" (ExcludeWUDriversInQualityUpdate = 1), which hides drivers from
    # every Windows Update scan. Lift it for the duration of this run only and put it back in the finally block.
    $polKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    $polVal = (Get-ItemProperty -Path $polKey -Name ExcludeWUDriversInQualityUpdate -ErrorAction SilentlyContinue).ExcludeWUDriversInQualityUpdate
    $lifted = $false
    if ($polVal -eq 1) {
        Set-ItemProperty -Path $polKey -Name ExcludeWUDriversInQualityUpdate -Value 0
        Restart-Service wuauserv -ErrorAction SilentlyContinue
        $lifted = $true
        Add-Note 'Windows Update: driver block policy (ExcludeWUDriversInQualityUpdate) lifted for this run only.'
    }
    try { Invoke-WindowsUpdateDriversCore }
    finally {
        if ($lifted) {
            Set-ItemProperty -Path $polKey -Name ExcludeWUDriversInQualityUpdate -Value 1
            Restart-Service wuauserv -ErrorAction SilentlyContinue
            Write-Log 'Windows Update: driver block policy restored.'
        }
    }
}

function Invoke-WindowsUpdateDriversCore {
    # "| ForEach-Object { $_ }" unrolls: under Windows PowerShell 5.1 the cmdlet can emit its results as ONE collection
    # object, which @() would keep as a single item with array-valued Title (seen on a Surface with 14 drivers).
    $found = @(Get-WindowsUpdate -UpdateType Driver -AcceptAll -IgnoreReboot -ErrorAction Stop | ForEach-Object { $_ })
    if (-not $found.Count) { Add-Note 'Windows Update: no driver updates available.'; return }
    foreach ($f in $found) { Write-Log "  found: $($f.Title) $($f.KB)" }
    if ($ScanOnly) { $script:Result.Pending = @($found | ForEach-Object { @{ Title = "$($_.Title)"; Version = "$($_.KB)" } }); return }
    # Per-update failures are non-terminating errors from the cmdlet; collect them instead of aborting the
    # whole run (which would have thrown away the results of the updates that did install).
    $wuErr = @()
    $res = @(Get-WindowsUpdate -UpdateType Driver -AcceptAll -Install -IgnoreReboot -ErrorAction SilentlyContinue -ErrorVariable wuErr | ForEach-Object { $_ })
    foreach ($e in $wuErr) { Write-Log "Windows Update error: $($e.Exception.Message)" '2' }
    # One row per stage per update (Accepted, Downloaded, Installed / Failed): count only the final states.
    foreach ($r in $res) {
        if ("$($r.Result)" -eq 'Installed') {
            $script:Result.Installed += @{ Title = "$($r.Title)"; Version = "$($r.KB)" }
            if ($r.RebootRequired) { $script:Result.RebootRequired = $true }
        }
        elseif ("$($r.Result)" -eq 'Failed') { $script:Result.Failed += @{ Title = "$($r.Title)"; Detail = "$($r.Result)" } }
    }
    # Deliberately NOT Get-WURebootStatus: that is the machine-wide Windows Update flag (a quality update installed
    # this morning would raise it), not something this run did.
    Add-Note "Windows Update: $($script:Result.Installed.Count) driver update(s) installed."
}

# ---------------------------------------------------------------------------------------------------
# MARK: Main
# ---------------------------------------------------------------------------------------------------
if ($SelfTest) {
    # The one runnable check: every external dependency resolvable, nothing installed.
    $fails = 0
    foreach ($step in @(
        @{ Name = 'Dell SDP catalog';            Do = { $x = Get-DellCatalogXml; $n = ([IO.File]::ReadAllText($x) | Select-String -Pattern "SystemTypeID = '" -AllMatches).Matches.Count; Remove-Item (Split-Path $x) -Recurse -Force; "expanded, $n SystemTypeID rule references across the catalog" } },
        @{ Name = 'HPIA latest';                 Do = { $r = Resolve-HPIALatest; "$($r.Version) -> $($r.Url)" } },
        @{ Name = 'Lenovo.Client.Update module'; Do = { Get-GalleryModule -Name 'Lenovo.Client.Update' -Root (Join-Path $script:TempDir 'selftest-modules') } },
        @{ Name = 'PSWindowsUpdate module';      Do = { Get-GalleryModule -Name 'PSWindowsUpdate' -Root (Join-Path $script:TempDir 'selftest-modules') } }
    )) {
        try { $v = & $step.Do; Write-Output "[ok]   $($step.Name): $v" }
        catch { $fails++; Write-Output "[FAIL] $($step.Name): $($_.Exception.Message)" }
    }
    Remove-Item (Join-Path $script:TempDir 'selftest-modules') -Recurse -Force -ErrorAction SilentlyContinue
    exit $fails
}

try {
    $bios = Get-ItemProperty 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS'
    $mfr = "$($bios.SystemManufacturer)".Trim()
    if ($VendorOverride) { $mfr = $VendorOverride; Write-Log "VendorOverride=$VendorOverride" '2' }
    $script:Result.Vendor = $mfr
    # One-shot force from the registry (set it, run a PSADT Repair, it is consumed). Param wins if both are given.
    if (-not $ForceTitle) {
        $rv = (Get-ItemProperty -Path $RegRoot -Name ForceTitle -ErrorAction SilentlyContinue).ForceTitle
        if ($rv) { $ForceTitle = $rv; Remove-ItemProperty -Path $RegRoot -Name ForceTitle -ErrorAction SilentlyContinue }
    }
    if ($ForceTitle) { Add-Note "TEST RUN: ForceTitle=[$ForceTitle] - matching Dell package(s) reinstalled regardless of version." }
    # Lenovo's SystemProductName is the bare machine-type (e.g. 21XX000000); SystemFamily carries the readable model
    # ("ThinkPad P16v Gen 2"), so show that with the MTM in brackets. Other vendors already have a readable ProductName.
    $model = "$($bios.SystemProductName)".Trim()
    if ($mfr -match '^LENOVO' -and "$($bios.SystemFamily)".Trim()) { $model = "$("$($bios.SystemFamily)".Trim()) [$model]" }
    Write-Log "=== $($script:Cfg.organization) driver update on $env:COMPUTERNAME ($mfr / $model) as $([Security.Principal.WindowsIdentity]::GetCurrent().Name); ScanOnly=$ScanOnly ==="

    switch -Regex ($mfr) {
        '^Dell'         { Invoke-DellUpdate; break }
        '^LENOVO'       { Invoke-LenovoUpdate; break }
        '^(HP|Hewlett)' { Invoke-HPUpdate; break }
        default         { Invoke-WindowsUpdateDrivers }
    }
    # RebootRequired is set ONLY by the vendor step above or by our own earlier, still-unrebooted ask.
    # The OS-wide pending state is noted for the log, never acted on.
    # Bookkeeping must never turn a completed install into "CouldNotRun" (which would make the gate re-run it).
    try { Update-RebootMarker } catch { Write-Log "Reboot marker check failed: $($_.Exception.Message)" '2' }
    # PromptCount is only reported here; the launcher increments it when a prompt is actually shown.
    if (Test-PendingReboot) { Add-Note 'OS already reports a pending reboot from something else (not raised by this run).' }
    $script:Result.Finished = (Get-Date).ToString('o')
    Write-Log "Done. Installed=$($script:Result.Installed.Count) Failed=$($script:Result.Failed.Count) Pending=$($script:Result.Pending.Count) RebootRequired=$($script:Result.RebootRequired)"
    $json = ConvertTo-Json -InputObject $script:Result -Depth 5
    Set-Content -Path $script:ResultFile -Value $json -Encoding UTF8
    Write-RegistryState -Status $(if ($ScanOnly) { 'ScanOnly' } else { 'Completed' })
    Write-Output $json
    exit 0
}
catch {
    Write-Log "Driver update could not run: $($_.Exception.Message)" '3'
    $script:Result.Finished = (Get-Date).ToString('o')
    $script:Result.Failed += @{ Title = 'worker'; Detail = $_.Exception.Message }
    try { ConvertTo-Json -InputObject $script:Result -Depth 5 | Set-Content -Path $script:ResultFile -Encoding UTF8 } catch {}
    Write-RegistryState -Status 'CouldNotRun'
    exit 1
}
