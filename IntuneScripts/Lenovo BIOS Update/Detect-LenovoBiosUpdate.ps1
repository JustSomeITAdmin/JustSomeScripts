<#
.SYNOPSIS
    Intune Remediation - DETECTION script (Lenovo BIOS: ThinkPad, ThinkStation, ThinkCentre...).
    Exit 1 if an applicable BIOS/UEFI update is available; exit 0 otherwise.

.DESCRIPTION
    Uses Lenovo's official 'Lenovo.Client.Update' (LCU) module to assess updates.
    - Any Lenovo device (gates on manufacturer).
    - Where present (ThinkPad), verifies WindowsUEFIFirmwareUpdate and BIOSUpdateByEndUsers are
      Enabled (SVP-locked, so we only READ them). Models without them (ThinkStation) proceed.
    - LCU cmdlets run in a FRESH child powershell.exe. LCU loads its classes via ScriptsToProcess,
      and those types (e.g. [MachineCharacteristics]) only resolve reliably in a fresh session
      that imports the module as its first action - not in a persistent/nested/stepped session.
    - staged.json (written by the remediation) suppresses re-triggering while a flashed BIOS
      awaits its reboot. No BIOS password is needed to flash a Lenovo from within Windows.

    Run as SYSTEM, 64-bit PowerShell.
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
$MaxFailedAttempts = 3

$StagedFile = Join-Path $StateDir 'staged.json'
$FailedFile = Join-Path $StateDir 'failed.json'

# Child script (runs in a fresh powershell.exe): list applicable BIOS updates as JSON.
$ChildGetBios = @'
param([Parameter(Mandatory)][string]$ModulePath)
Import-Module $ModulePath -ErrorAction Stop
$bios = @(Get-LnvUpdate -WarningAction SilentlyContinue |
    Where-Object { $_.Type -eq 'BIOS' -and $_.Installer.Unattended } |
    Select-Object ID, Title, @{ Name = 'Version'; Expression = { "$($_.Version)" } })  # [version] -> string
$bios | ConvertTo-Json -Compress -Depth 4
'@

#=================================================
# Logging (CMTrace format)
#=================================================
function Write-CMLogEntry {
    param(
        [Parameter(Mandatory)][string]$Value,
        [ValidateSet('1','2','3')][string]$Severity = '1',
        [string]$Component = 'LenovoBIOSUpdate-Detect',
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
# Helpers (shared with the remediation script)
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

function Remove-IfExists { param([string]$Path) if (Test-Path $Path) { Remove-Item $Path -Force -ErrorAction SilentlyContinue } }

#=================================================
# Main
#=================================================
$ProgressPreference = 'SilentlyContinue'
try {
    foreach ($d in @($StateDir, $LogDir)) { if (-not (Test-Path $d)) { $null = New-Item -Path $d -ItemType Directory -Force } }
    Write-CMLogEntry -Value '--- Detection started ---' -Severity 1

    if (-not (Test-IsLenovo)) {
        Write-CMLogEntry -Value 'Not a Lenovo device. Nothing to do.' -Severity 2
        Write-Output 'Not a Lenovo; skipping.'
        exit 0
    }
    Write-CMLogEntry -Value "Lenovo device: $((Get-CimInstance Win32_ComputerSystemProduct -ErrorAction SilentlyContinue).Version)" -Severity 1

    $settings = Get-BiosSettingState
    if (-not $settings.Ok) {
        # SVP-locked, so a script cannot fix this - surface it and stop (a flash would just fail).
        Write-CMLogEntry -Value "BIOS update prerequisite not met: $($settings.Detail). Cannot remediate." -Severity 3
        Write-Output "BIOS prerequisite not met: $($settings.Detail)"
        exit 0
    }
    Write-CMLogEntry -Value "BIOS settings OK ($($settings.Detail))." -Severity 1

    $modId = Get-LnvModulePath
    $biosJson = Invoke-LcuChild -Body $ChildGetBios -Params @{ ModulePath = $modId }
    $bios = if ([string]::IsNullOrWhiteSpace($biosJson)) { @() } else { @($biosJson | ConvertFrom-Json) }

    if ($bios.Count -eq 0) {
        Remove-IfExists $StagedFile   # any previously-staged BIOS is now applied
        Write-CMLogEntry -Value 'No applicable BIOS update. Compliant.' -Severity 1
        Write-Output 'BIOS up to date.'
        exit 0
    }
    $target = $bios | Select-Object -First 1
    Write-CMLogEntry -Value "Applicable BIOS: $($target.Title) [ID=$($target.ID) Ver=$($target.Version)]" -Severity 1

    # Already staged and awaiting reboot -> don't re-flash.
    if (Test-Path $StagedFile) {
        $staged = Get-Content $StagedFile -Raw | ConvertFrom-Json
        if ($staged.ID -eq $target.ID) {
            Write-CMLogEntry -Value "BIOS $($target.ID) already staged on $($staged.StagedAtUtc) - awaiting reboot. Compliant." -Severity 1
            Write-Output "BIOS $($target.Version) staged; awaiting reboot."
            exit 0
        }
    }

    # Stop hammering a version that keeps failing to flash.
    if (Test-Path $FailedFile) {
        $failed = Get-Content $FailedFile -Raw | ConvertFrom-Json
        if ($failed.ID -eq $target.ID -and [int]$failed.Count -ge $MaxFailedAttempts) {
            Write-CMLogEntry -Value "BIOS $($target.ID) failed $($failed.Count)x; suppressing until a newer BIOS is published." -Severity 3
            Write-Output "BIOS $($target.Version) repeatedly failed; suppressed."
            exit 0
        }
    }

    Write-CMLogEntry -Value "UPDATE AVAILABLE: $($target.Version). Flagging for remediation." -Severity 1
    Write-Output "BIOS update available: $($target.Version)"
    exit 1
}
catch {
    Write-CMLogEntry -Value "Detection error: $($_.Exception.Message)" -Severity 3
    Write-Output "Detection error: $($_.Exception.Message)"
    exit 0   # never trigger remediation on a detection failure
}
