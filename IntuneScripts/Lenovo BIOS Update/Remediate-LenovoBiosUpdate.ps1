<#
.SYNOPSIS
    Intune Remediation - REMEDIATION script (Lenovo BIOS: ThinkPad, ThinkStation, ThinkCentre...).
    Downloads and stages the applicable BIOS update via Lenovo's LCU module, WITHOUT rebooting.

.DESCRIPTION
    - Uses 'Lenovo.Client.Update' (LCU). Install-LnvUpdate never reboots the machine itself;
      it stages the BIOS flash (winuptp/Flash.cmd) and reports PendingAction. So the reboot is
      left to the user / another process - exactly the "suppress reboot" behaviour we want.
    - LCU cmdlets run in a FRESH child powershell.exe (LCU's ScriptsToProcess classes only
      resolve reliably in a fresh session that imports the module as its first action).
    - Suspends BitLocker for the next reboot(s) so the firmware change doesn't force a recovery
      prompt (LCU does not do this on its own).
    - No BIOS password is needed to flash a Lenovo from within Windows.
    - Writes staged.json so detection won't re-flash while the staged BIOS awaits its reboot.

    Run as SYSTEM, 64-bit PowerShell. $StateDir must match the detection script.
#>

#=================================================
# Config
#=================================================
$StateDir   = 'C:\ProgramData\Lenovo'
$ModuleDir  = Join-Path $StateDir 'Module'
$TempDir    = Join-Path $env:TEMP 'LenovoBiosUpdate'
$LogDir     = 'C:\Windows\Logs\Software'
$LogFile    = 'LenovoBIOSUpdate.log'
$ModuleName = 'Lenovo.Client.Update'
$GalleryFindUri = 'https://www.powershellgallery.com/api/v2/FindPackagesById()'
$RequiredBiosSettings = @('WindowsUEFIFirmwareUpdate', 'BIOSUpdateByEndUsers')
$RebootCount = 2        # BitLocker stays suspended across this many reboots, then auto-resumes

$StagedFile = Join-Path $StateDir 'staged.json'
$FailedFile = Join-Path $StateDir 'failed.json'

# Child script (runs in a fresh powershell.exe): download + stage the newest applicable BIOS,
# emit a JSON result. Install-LnvUpdate stages the flash and does NOT reboot.
$ChildInstallBios = @'
param([Parameter(Mandatory)][string]$ModulePath, [Parameter(Mandatory)][string]$DownloadDir)
$ProgressPreference = 'SilentlyContinue'
Import-Module $ModulePath -ErrorAction Stop
$t = Get-LnvUpdate -WarningAction SilentlyContinue |
    Where-Object { $_.Type -eq 'BIOS' -and $_.Installer.Unattended } | Select-Object -First 1
if (-not $t) { [pscustomobject]@{ NoUpdate = $true } | ConvertTo-Json -Compress; return }
# 6>$null discards LCU's "BIOS UPDATE SUCCESS" Write-Information (it uses -InformationAction
# Continue) so ONLY the JSON below reaches stdout for the parent to parse.
$null = $t | Save-LnvUpdate -Path $DownloadDir -ErrorAction Stop 6>$null
$r = Install-LnvUpdate -Package $t -Path $DownloadDir -SaveBIOSUpdateInfoToRegistry -ErrorAction Stop 6>$null
[pscustomobject]@{
    ID = $t.ID; Title = $t.Title; Version = "$($t.Version)"   # [version] -> string
    Success = [bool]$r.Success; PendingAction = "$($r.PendingAction)"
    ExitCode = $r.ExitCode; FailureReason = "$($r.FailureReason)"
} | ConvertTo-Json -Compress
'@

#=================================================
# Logging (CMTrace format)
#=================================================
function Write-CMLogEntry {
    param(
        [Parameter(Mandatory)][string]$Value,
        [ValidateSet('1','2','3')][string]$Severity = '1',
        [string]$Component = 'LenovoBIOSUpdate-Remediate',
        [string]$FileName = $LogFile
    )
    $LogFilePath = Join-Path -Path $LogDir -ChildPath $FileName
    if (-not (Test-Path 'variable:global:TimezoneBias')) {
        [string]$global:TimezoneBias = [System.TimeZoneInfo]::Local.GetUtcOffset((Get-Date)).TotalMinutes
        $global:TimezoneBias = if ($TimezoneBias -match '^-') { $TimezoneBias.Replace('-','+') } else { '-' + $TimezoneBias }
    }
    $Time = -join @((Get-Date -Format 'HH:mm:ss.fff'), $TimezoneBias)
    $Date = (Get-Date -Format 'MM-dd-yyyy')
    $Context = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $LogText = "<![LOG[$Value]LOG]!><time=""$Time"" date=""$Date"" component=""$Component"" context=""$Context"" type=""$Severity"" thread=""$PID"" file="""">"
    try { Out-File -InputObject $LogText -Append -NoClobber -Encoding Default -FilePath $LogFilePath -ErrorAction Stop } catch {}
}

#=================================================
# Helpers (shared with the detection script)
#=================================================
function Test-IsLenovo {
    (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).Manufacturer -match 'LENOVO'
}

function Get-BiosSettingState {
    # The two settings only exist on ThinkPad; enforce them where present, otherwise proceed
    # (e.g. ThinkStation, or any model without them). Only a present-but-Disabled setting blocks.
    try {
        $raw = Get-CimInstance -Namespace 'root\wmi' -ClassName Lenovo_BiosSetting -ErrorAction Stop
    } catch {
        return @{ Ok = $true; Detail = 'Lenovo_BiosSetting not present; prerequisite not applicable' }
    }
    $map = @{}
    foreach ($s in $raw) {
        if ($s.CurrentSetting -match '^([^,]+),([^,;]+)') { $map[$matches[1]] = $matches[2] }
    }
    $checked = @()
    foreach ($name in $RequiredBiosSettings) {
        if ($map.ContainsKey($name)) {
            if ($map[$name] -notmatch '^Enabled?$') { return @{ Ok = $false; Detail = "$name = $($map[$name]) (need Enabled)" } }
            $checked += $name
        }
    }
    $detail = if ($checked.Count) { "$($checked -join ', ') Enabled" } else { 'prerequisite settings not present on this model' }
    return @{ Ok = $true; Detail = $detail }
}

function Get-LnvModulePath {
    # Ensures the LCU module files are present locally (downloads if needed) and returns an
    # identifier to import in the child process: the .psd1 path, or the module name if it is
    # already installed on PSModulePath.
    if (Get-Module -ListAvailable -Name $ModuleName) { return $ModuleName }
    # A copy placed next to the script wins (handy for local testing; not shipped to devices).
    $colocated = Join-Path $PSScriptRoot "Module\$ModuleName.psd1"
    if (Test-Path $colocated) { return $colocated }
    $psd1 = Join-Path $ModuleDir "$ModuleName.psd1"
    if (-not (Test-Path $psd1)) {
        if (-not (Test-Path $ModuleDir)) { $null = New-Item -Path $ModuleDir -ItemType Directory -Force }
        if (-not (Test-Path $TempDir))   { $null = New-Item -Path $TempDir   -ItemType Directory -Force }
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        # Resolve the versioned .nupkg URL via OData (the bare /package/<id> URL 302-redirects,
        # which BITS won't follow); then download + expand.
        Write-CMLogEntry -Value "Resolving $ModuleName from the PowerShell Gallery..." -Severity 1
        $find = Invoke-RestMethod -Uri $GalleryFindUri -Body @{ '$filter' = 'IsLatestVersion eq true'; id = "'$ModuleName'" } -ErrorAction Stop
        $entry = $find | Sort-Object { [version]$_.properties.version } -Descending | Select-Object -First 1
        if (-not $entry.content.src) { throw "Could not resolve a download URL for $ModuleName from the gallery." }
        $zip = Join-Path $TempDir "$ModuleName.zip"
        Write-CMLogEntry -Value "Downloading $ModuleName $($entry.properties.version)..." -Severity 1
        Invoke-RestMethod -Uri $entry.content.src -OutFile $zip -ErrorAction Stop
        Expand-Archive -Path $zip -DestinationPath $ModuleDir -Force
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
    }
    return $psd1
}

function Invoke-LcuChild {
    # Runs $Body in a FRESH powershell.exe (import + LCU cmdlets as its first actions) so the
    # module's ScriptsToProcess classes resolve reliably. Returns stdout; throws on non-zero exit.
    param([Parameter(Mandatory)][string]$Body, [hashtable]$Params = @{})
    if (-not (Test-Path $TempDir)) { $null = New-Item -Path $TempDir -ItemType Directory -Force }
    $childPs1 = Join-Path $TempDir 'lcu-child.ps1'
    $errFile  = Join-Path $TempDir 'lcu-child.err'
    Set-Content -Path $childPs1 -Value $Body -Encoding UTF8
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $childPs1)
    foreach ($k in $Params.Keys) { $argList += "-$k"; $argList += [string]$Params[$k] }
    $out = & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" @argList 2>$errFile
    $code = $LASTEXITCODE
    if ((Test-Path $errFile) -and (Get-Item $errFile).Length -gt 0) {
        Write-CMLogEntry -Value "LCU child stderr: $((Get-Content $errFile -Raw).Trim())" -Severity 2
    }
    Remove-Item $childPs1, $errFile -Force -ErrorAction SilentlyContinue
    if ($code -ne 0) { throw "LCU child process failed (exit $code)." }
    return ($out -join "`n")
}

function Set-FailureRecord {
    param([string]$Id)
    $count = 1
    if (Test-Path $FailedFile) {
        $f = Get-Content $FailedFile -Raw | ConvertFrom-Json
        if ($f.ID -eq $Id) { $count = [int]$f.Count + 1 }
    }
    [pscustomobject]@{ ID = $Id; Count = $count; LastUtc = (Get-Date).ToUniversalTime().ToString('o') } |
        ConvertTo-Json | Set-Content -Path $FailedFile -Encoding UTF8
    return $count
}

function Resume-OsBitLocker {
    try {
        if ((Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop).ProtectionStatus -ne 'On') {
            Resume-BitLocker -MountPoint $env:SystemDrive -ErrorAction SilentlyContinue | Out-Null
            Write-CMLogEntry -Value 'BitLocker resumed.' -Severity 2
        }
    } catch {}
}

function Remove-IfExists { param([string]$Path) if (Test-Path $Path) { Remove-Item $Path -Force -ErrorAction SilentlyContinue } }

#=================================================
# Main
#=================================================
$ProgressPreference = 'SilentlyContinue'
$suspended = $false
try {
    foreach ($d in @($StateDir, $LogDir, $TempDir)) { if (-not (Test-Path $d)) { $null = New-Item -Path $d -ItemType Directory -Force } }
    Write-CMLogEntry -Value '--- Remediation started ---' -Severity 1

    if (-not (Test-IsLenovo)) { Write-Output 'Not a Lenovo; skipping.'; exit 0 }
    Write-CMLogEntry -Value "Lenovo device: $((Get-CimInstance Win32_ComputerSystemProduct -ErrorAction SilentlyContinue).Version)" -Severity 1

    $settings = Get-BiosSettingState
    if (-not $settings.Ok) {
        Write-CMLogEntry -Value "Prerequisite not met: $($settings.Detail). Cannot flash." -Severity 3
        Write-Output "BIOS prerequisite not met: $($settings.Detail)"
        exit 1
    }

    $modId = Get-LnvModulePath
    $dl = Join-Path $TempDir 'packages'
    if (-not (Test-Path $dl)) { $null = New-Item -Path $dl -ItemType Directory -Force }

    #--- Suspend BitLocker so the firmware change doesn't force a recovery prompt ---
    try {
        $blv = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
        if ($blv.ProtectionStatus -eq 'On') {
            Suspend-BitLocker -MountPoint $env:SystemDrive -RebootCount $RebootCount -ErrorAction Stop | Out-Null
            $suspended = $true
            Write-CMLogEntry -Value "BitLocker on $env:SystemDrive suspended for $RebootCount reboot(s)." -Severity 1
        } else {
            Write-CMLogEntry -Value "BitLocker not active on $env:SystemDrive; no suspend needed." -Severity 1
        }
    } catch { Write-CMLogEntry -Value "BitLocker suspend warning: $($_.Exception.Message)" -Severity 2 }

    #--- Download + stage the flash in a fresh child process (LCU verifies signatures; no reboot) ---
    Write-CMLogEntry -Value 'Downloading + staging BIOS via LCU child process...' -Severity 1
    $json = Invoke-LcuChild -Body $ChildInstallBios -Params @{ ModulePath = $modId; DownloadDir = $dl }
    $result = if ([string]::IsNullOrWhiteSpace($json)) { $null } else { $json | ConvertFrom-Json }
    Remove-Item $dl -Recurse -Force -ErrorAction SilentlyContinue

    if ($null -eq $result) { throw 'LCU child returned no result.' }

    if ($result.NoUpdate) {
        if ($suspended) { Resume-OsBitLocker }
        Write-CMLogEntry -Value 'No applicable BIOS update found; nothing staged.' -Severity 2
        Write-Output 'Nothing to do.'
        exit 0
    }

    if ($result.Success) {
        [pscustomobject]@{
            ID = $result.ID; Title = $result.Title; Version = $result.Version
            PendingAction = "$($result.PendingAction)"; StagedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        } | ConvertTo-Json | Set-Content -Path $StagedFile -Encoding UTF8
        Remove-IfExists $FailedFile
        Write-CMLogEntry -Value "SUCCESS: BIOS $($result.Version) staged. PendingAction=$($result.PendingAction). Reboot required to apply." -Severity 1
        Write-Output "BIOS $($result.Version) staged; $($result.PendingAction) required to apply."
        exit 0
    }
    else {
        $attempts = Set-FailureRecord -Id $result.ID
        if ($suspended) { Resume-OsBitLocker }   # flash didn't take
        Write-CMLogEntry -Value "FAILED: $($result.FailureReason) (ExitCode=$($result.ExitCode), attempt $attempts)." -Severity 3
        Write-Output "BIOS flash failed: $($result.FailureReason)"
        exit 1
    }
}
catch {
    if ($suspended) { Resume-OsBitLocker }
    Write-CMLogEntry -Value "Remediation error: $($_.Exception.Message)" -Severity 3
    Write-Output "Remediation error: $($_.Exception.Message)"
    exit 1
}
