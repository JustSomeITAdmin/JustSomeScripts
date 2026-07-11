<#
.SYNOPSIS
    Intune Remediation - REMEDIATION script (HP BIOS via HP CMSL).
    Stages the latest BIOS with Get-HPBIOSUpdates -Flash, WITHOUT rebooting.

.DESCRIPTION
    - Get-HPBIOSUpdates -Flash -Yes -BitLocker Suspend downloads the BIOS from HP's catalog,
      SHA384-verifies it, suspends BitLocker itself, and STAGES the flash (a reboot is required
      to complete - CMSL does not reboot). That is the "suppress reboot" model.
    - Authentication is adaptive (fleet is mixed): tries the flash with no password first; if HP
      reports a Setup Password is required, retries with the AES-decrypted password; if HP Sure
      Admin is enabled, stops (Sure Admin needs a SIGNED payload via Update-HPFirmware - not
      handled here).
    - Writes staged.json so detection won't re-flash while the staged BIOS awaits its reboot.

    Run as SYSTEM, 64-bit PowerShell. $StateDir must match the detection script.

    BIOS Setup password: stored AES-encrypted (see New-EncryptedBiosPassword.ps1). Leave
    $BiosPasswordBlob empty if no Setup password is set.
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

# ---- BIOS Setup password (AES). Generate with New-EncryptedBiosPassword.ps1 and paste below. ----
# 32-byte key (decimal bytes). Leave both empty if no BIOS Setup password is set.
$BiosPasswordKey  = [byte[]]@()           # e.g. @(12,34,...,255)  (32 values)
$BiosPasswordBlob = ''                    # Base64 string from the helper
# ------------------------------------------------------------------------------------------------

$StagedFile = Join-Path $StateDir 'staged.json'
$FailedFile = Join-Path $StateDir 'failed.json'

#=================================================
# Logging (CMTrace format)
#=================================================
function Write-CMLogEntry {
    param(
        [Parameter(Mandatory)][string]$Value,
        [ValidateSet('1','2','3')][string]$Severity = '1',
        [string]$Component = 'HPBIOSUpdate-Remediate',
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
function Test-IsHP {
    (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).Manufacturer -match 'HP|Hewlett'
}

function Import-HPBiosModules {
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

function Unprotect-BiosPassword {
    param([byte[]]$Key, [string]$Blob)
    if (-not $Key -or $Key.Count -eq 0 -or [string]::IsNullOrEmpty($Blob)) { return $null }
    $all = [Convert]::FromBase64String($Blob)
    $aes = [System.Security.Cryptography.Aes]::Create()
    try {
        $aes.Key = $Key
        $aes.IV  = $all[0..15]
        $ct = $all[16..($all.Length - 1)]
        $dec = $aes.CreateDecryptor()
        $pt  = $dec.TransformFinalBlock($ct, 0, $ct.Length)
        return [System.Text.Encoding]::UTF8.GetString($pt)
    } finally { $aes.Dispose() }
}

function Set-FailureRecord {
    param([string]$Version)
    $count = 1
    if (Test-Path $FailedFile) {
        $f = Get-Content $FailedFile -Raw | ConvertFrom-Json
        if ($f.Version -eq $Version) { $count = [int]$f.Count + 1 }
    }
    [pscustomobject]@{ Version = $Version; Count = $count; LastUtc = (Get-Date).ToUniversalTime().ToString('o') } |
        ConvertTo-Json | Set-Content -Path $FailedFile -Encoding UTF8
    return $count
}

function Remove-IfExists { param([string]$Path) if (Test-Path $Path) { Remove-Item $Path -Force -ErrorAction SilentlyContinue } }

#=================================================
# Main
#=================================================
$ProgressPreference = 'SilentlyContinue'
$BIOSPassword = $null
try {
    foreach ($d in @($StateDir, $LogDir, $TempDir)) { if (-not (Test-Path $d)) { $null = New-Item -Path $d -ItemType Directory -Force } }
    Write-CMLogEntry -Value '--- Remediation started ---' -Severity 1

    if (-not (Test-IsHP)) { Write-Output 'Not an HP; skipping.'; exit 0 }
    Write-CMLogEntry -Value "HP device: $((Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).Model)" -Severity 1

    Import-HPBiosModules
    $current = Get-HPBIOSVersion
    if ([bool](Get-HPBIOSUpdates -Check -ErrorAction Stop)) {
        Remove-IfExists $StagedFile
        Write-CMLogEntry -Value "BIOS already up to date ($current); nothing to do." -Severity 2
        Write-Output "Already up to date ($current)."
        exit 0
    }

    #--- Flash (stages; CMSL suspends BitLocker and does NOT reboot). Auth is adaptive. ---
    Write-CMLogEntry -Value "Flashing BIOS (installed=$current)..." -Severity 1
    $flashed = $false
    try {
        Get-HPBIOSUpdates -Flash -Yes -BitLocker Suspend -Quiet -ErrorAction Stop
        $flashed = $true
    }
    catch {
        $msg = "$($_.Exception.Message)"
        if ($msg -match 'Sure\s?Admin') {
            Write-CMLogEntry -Value "HP Sure Admin is enabled - flashing requires a signed payload (New-HPSureAdminFirmwareUpdatePayload + Update-HPFirmware). Not handled by this script." -Severity 3
            Write-Output 'Sure Admin enabled; signed payload required.'
            exit 1
        }
        elseif ($msg -match 'password') {
            if ([string]::IsNullOrEmpty($BiosPasswordBlob)) {
                $null = Set-FailureRecord -Version $current
                Write-CMLogEntry -Value "BIOS Setup password required but none is configured in the script. Set it with New-EncryptedBiosPassword.ps1." -Severity 3
                Write-Output 'BIOS password required but not configured.'
                exit 1
            }
            Write-CMLogEntry -Value 'Setup password required; retrying flash with the stored password.' -Severity 2
            $BIOSPassword = Unprotect-BiosPassword -Key $BiosPasswordKey -Blob $BiosPasswordBlob
            try {
                Get-HPBIOSUpdates -Flash -Yes -BitLocker Suspend -Quiet -Password $BIOSPassword -ErrorAction Stop
                $flashed = $true
            }
            catch {
                $attempts = Set-FailureRecord -Version $current
                Write-CMLogEntry -Value "Flash failed with password (attempt $attempts): $($_.Exception.Message)" -Severity 3
                Write-Output 'BIOS flash failed (with password).'
                exit 1
            }
            finally { if ($BIOSPassword) { Clear-Variable BIOSPassword; $BIOSPassword = $null } }
        }
        else {
            $attempts = Set-FailureRecord -Version $current
            Write-CMLogEntry -Value "Flash failed (attempt $attempts): $msg" -Severity 3
            Write-Output "BIOS flash failed: $msg"
            exit 1
        }
    }

    if ($flashed) {
        [pscustomobject]@{ RunningAtFlash = $current; StagedAtUtc = (Get-Date).ToUniversalTime().ToString('o') } |
            ConvertTo-Json | Set-Content -Path $StagedFile -Encoding UTF8
        Remove-IfExists $FailedFile
        Write-CMLogEntry -Value "SUCCESS: BIOS flash staged (from $current). Reboot required to apply." -Severity 1
        Write-Output "BIOS flash staged (from $current); reboot required to apply."
        exit 0
    }
}
catch {
    if ($BIOSPassword) { Clear-Variable BIOSPassword -ErrorAction SilentlyContinue; $BIOSPassword = $null }
    Write-CMLogEntry -Value "Remediation error: $($_.Exception.Message)" -Severity 3
    Write-Output "Remediation error: $($_.Exception.Message)"
    exit 1
}
