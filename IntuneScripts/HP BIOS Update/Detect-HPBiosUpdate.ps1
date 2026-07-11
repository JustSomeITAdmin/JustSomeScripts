<#
.SYNOPSIS
    Intune Remediation - DETECTION script (HP BIOS via HP CMSL).
    Exit 1 if a newer BIOS is available for this HP device; exit 0 otherwise.

.DESCRIPTION
    Uses HP's Client Management Script Library (CMSL). Detection is a single call:
    Get-HPBIOSUpdates -Check returns $true (up to date) / $false (update available), by
    comparing the running BIOS to HP's public catalog (ftp.hp.com/pub/pcbios/<platform>).

    - Only the 4 CMSL sub-modules needed for BIOS are cached (HP.Private, HP.Utility,
      HP.ClientManagement, HP.Firmware) - not the full 14-module HPCMSL.
    - staged.json (written by the remediation) suppresses re-triggering while a flashed BIOS
      awaits its reboot.

    Run as SYSTEM, 64-bit PowerShell. CMSL supports HP business PCs (~2016+) booted UEFI.
#>

#=================================================
# Config
#=================================================
$StateDir   = 'C:\ProgramData\HP'
$ModuleDir  = Join-Path $StateDir 'Module'
$TempDir    = Join-Path $env:TEMP 'HPBiosUpdate'
$LogDir     = 'C:\Windows\Logs\Software'
$LogFile    = 'HPBIOSUpdate.log'
$GalleryFindUri = 'https://www.powershellgallery.com/api/v2/FindPackagesById()'
$HPModules  = 'HP.Private', 'HP.Utility', 'HP.ClientManagement', 'HP.Firmware'
$MaxFailedAttempts = 3

$StagedFile = Join-Path $StateDir 'staged.json'
$FailedFile = Join-Path $StateDir 'failed.json'

#=================================================
# Logging (CMTrace format)
#=================================================
function Write-CMLogEntry {
    param(
        [Parameter(Mandatory)][string]$Value,
        [ValidateSet('1','2','3')][string]$Severity = '1',
        [string]$Component = 'HPBIOSUpdate-Detect',
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
function Test-IsHP {
    (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).Manufacturer -match 'HP|Hewlett'
}

function Import-HPBiosModules {
    # Imports the 4 CMSL modules needed for BIOS. Uses a co-located Module\ (local testing),
    # then the ProgramData cache, then a system install, else downloads the sub-modules from
    # the gallery (at the current HPCMSL version) into the cache. No child process needed -
    # CMSL types load via Add-Type, so there's no ScriptsToProcess class-scope trap.
    foreach ($root in @((Join-Path $PSScriptRoot 'Module'), $ModuleDir)) {
        if (Test-Path (Join-Path $root 'HP.ClientManagement')) {
            if (";$env:PSModulePath;" -notlike "*;$root;*") { $env:PSModulePath = "$root;$env:PSModulePath" }
            Import-Module $HPModules -ErrorAction Stop
            return
        }
    }
    if (Get-Module -ListAvailable -Name 'HP.ClientManagement') { Import-Module $HPModules -ErrorAction Stop; return }

    foreach ($d in @($ModuleDir, $TempDir)) { if (-not (Test-Path $d)) { $null = New-Item -Path $d -ItemType Directory -Force } }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $find = Invoke-RestMethod -Uri $GalleryFindUri -Body @{ '$filter' = 'IsLatestVersion eq true'; id = "'HPCMSL'" } -ErrorAction Stop
    $ver = ($find | Sort-Object { [version]$_.properties.version } -Descending | Select-Object -First 1).properties.version
    Write-CMLogEntry -Value "Downloading HP CMSL BIOS modules v$ver ($($HPModules -join ', '))..." -Severity 1
    foreach ($m in $HPModules) {
        $dest = Join-Path $ModuleDir "$m\$ver"
        if (Test-Path (Join-Path $dest "$m.psd1")) { continue }
        $null = New-Item -Path $dest -ItemType Directory -Force
        $zip = Join-Path $TempDir "$m.zip"
        Invoke-RestMethod -Uri "https://www.powershellgallery.com/api/v2/package/$m/$ver" -OutFile $zip -ErrorAction Stop
        Expand-Archive -Path $zip -DestinationPath $dest -Force
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
    }
    if (";$env:PSModulePath;" -notlike "*;$ModuleDir;*") { $env:PSModulePath = "$ModuleDir;$env:PSModulePath" }
    Import-Module $HPModules -ErrorAction Stop
}

function Remove-IfExists { param([string]$Path) if (Test-Path $Path) { Remove-Item $Path -Force -ErrorAction SilentlyContinue } }

#=================================================
# Main
#=================================================
$ProgressPreference = 'SilentlyContinue'
try {
    foreach ($d in @($StateDir, $LogDir)) { if (-not (Test-Path $d)) { $null = New-Item -Path $d -ItemType Directory -Force } }
    Write-CMLogEntry -Value '--- Detection started ---' -Severity 1

    if (-not (Test-IsHP)) {
        Write-CMLogEntry -Value 'Not an HP device. Nothing to do.' -Severity 2
        Write-Output 'Not an HP; skipping.'
        exit 0
    }
    Write-CMLogEntry -Value "HP device: $((Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).Model)" -Severity 1

    Import-HPBiosModules
    $current = Get-HPBIOSVersion
    # Fleet visibility: is a Setup password set, and what's the Sure Admin state? (both best-effort)
    $pwSet     = try { [bool](Get-HPBIOSSetupPasswordIsSet) } catch { 'unknown' }
    $sureAdmin = try { "$((Get-HPSureAdminState -ErrorAction Stop).SureAdminMode)" } catch { 'unknown' }
    Write-CMLogEntry -Value "Installed=$current | SetupPasswordSet=$pwSet | SureAdmin=$sureAdmin" -Severity 1
    $upToDate = [bool](Get-HPBIOSUpdates -Check -ErrorAction Stop)

    if ($upToDate) {
        Remove-IfExists $StagedFile   # any previously-staged BIOS is now applied
        Write-CMLogEntry -Value "BIOS up to date ($current)." -Severity 1
        Write-Output "BIOS up to date ($current)."
        exit 0
    }

    $latest = try { "$((Get-HPBIOSUpdates -Latest -ErrorAction Stop).Ver)" } catch { '' }
    Write-CMLogEntry -Value "Update available: installed=$current latest=$latest" -Severity 1

    # Already staged and awaiting reboot (running BIOS unchanged since the flash) -> don't re-flash.
    if (Test-Path $StagedFile) {
        $staged = Get-Content $StagedFile -Raw | ConvertFrom-Json
        if ($staged.RunningAtFlash -eq $current) {
            Write-CMLogEntry -Value "BIOS already staged on $($staged.StagedAtUtc) (from $current) - awaiting reboot. Compliant." -Severity 1
            Write-Output "BIOS staged; awaiting reboot."
            exit 0
        }
    }

    # Stop hammering a BIOS level that keeps failing to flash.
    if (Test-Path $FailedFile) {
        $failed = Get-Content $FailedFile -Raw | ConvertFrom-Json
        if ($failed.Version -eq $current -and [int]$failed.Count -ge $MaxFailedAttempts) {
            Write-CMLogEntry -Value "Flash from $current failed $($failed.Count)x; suppressing until the BIOS changes." -Severity 3
            Write-Output "BIOS flash repeatedly failed; suppressed."
            exit 0
        }
    }

    Write-CMLogEntry -Value "UPDATE AVAILABLE ($current -> $latest). Flagging for remediation." -Severity 1
    Write-Output "BIOS update available: $current -> $latest"
    exit 1
}
catch {
    Write-CMLogEntry -Value "Detection error: $($_.Exception.Message)" -Severity 3
    Write-Output "Detection error: $($_.Exception.Message)"
    exit 0   # never trigger remediation on a detection failure
}
