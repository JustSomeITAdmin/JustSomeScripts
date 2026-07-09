<#
.SYNOPSIS
    Intune Remediation - REMEDIATION script.
    Downloads the BIOS package flagged by the detection script, verifies it,
    suspends BitLocker, and stages the BIOS flash WITHOUT rebooting.

.DESCRIPTION
    - Reads pending.json (written by Detect-DellBiosUpdate.ps1).
    - Downloads the BIOS .exe directly from downloads.dell.com via BITS (HTTPS).
    - Verifies size + SHA1 against the catalog's published digest.
    - Suspends BitLocker for the next reboot(s) so the firmware change does not
      trigger a recovery prompt.
    - Runs the BIOS .exe with /s (silent) and NO /r, so the update is staged and
      applied on the NEXT reboot (performed later by the user or another process).
    - Writes staged.json so detection won't re-flash while awaiting that reboot.

    Run as SYSTEM, 64-bit PowerShell.

    BIOS password: stored AES-encrypted (see New-EncryptedBiosPassword.ps1). The
    plaintext only exists in memory and is redacted from logs. If your fleet has
    NO BIOS password, leave $BiosPasswordBlob empty.

    NOTE: $StateDir must match the detection script (the two scripts hand off via
    pending.json/staged.json/failed.json in this folder).
#>

#=================================================
# Config
#=================================================
$StateDir    = 'C:\ProgramData\Dell'
$TempDir     = Join-Path $env:TEMP 'DellBiosUpdate'
$LogDir      = 'C:\Windows\Logs\Software'
$LogFile     = 'DellBIOSUpdate.log'
$FlashLogName = 'DellFlashBIOS.log'
$RebootCount = 2        # BitLocker stays suspended across this many reboots, then auto-resumes
# (The flash retry cap, $MaxFailedAttempts, is enforced by the DETECTION script.)

# ---- BIOS admin password (AES). Generate with New-EncryptedBiosPassword.ps1 and paste below. ----
# 32-byte key (decimal bytes). Leave both empty if no BIOS password is set.
$BiosPasswordKey  = [byte[]]@()           # e.g. @(12,34,...,255)  (32 values)
$BiosPasswordBlob = ''                    # Base64 string from the helper
# ------------------------------------------------------------------------------------------------

$PendingFile = Join-Path $StateDir 'pending.json'
$StagedFile  = Join-Path $StateDir 'staged.json'
$FailedFile  = Join-Path $StateDir 'failed.json'

#=================================================
# Logging (CMTrace format)
#=================================================
function Write-CMLogEntry {
    param(
        [Parameter(Mandatory)][string]$Value,
        [ValidateSet('1','2','3')][string]$Severity = '1',
        [string]$Component = 'DellBIOSUpdate-Remediate',
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
# Helpers
#=================================================
function ConvertTo-BiosKind {
    # Classify a Dell BIOS version: numeric (x.x[.x]) or legacy Axx.
    param([string]$v)
    if ($v -match '^A(\d+)') { return @{ Kind = 'Axx'; Num = [int]$Matches[1] } }
    $ver = $null
    if ([version]::TryParse($v, [ref]$ver)) { return @{ Kind = 'Num'; Ver = $ver } }
    return @{ Kind = 'Unknown' }
}

function Test-NewerVersion {
    # True if $Candidate is a newer BIOS than $Current. Handles numeric and legacy Axx.
    param([string]$Candidate, [string]$Current)
    if ([string]::IsNullOrWhiteSpace($Candidate) -or [string]::IsNullOrWhiteSpace($Current)) { return $false }
    if ($Candidate.Trim() -ieq $Current.Trim()) { return $false }
    $c = ConvertTo-BiosKind $Candidate.Trim()
    $u = ConvertTo-BiosKind $Current.Trim()
    if ($c.Kind -eq 'Num' -and $u.Kind -eq 'Num') { return ($c.Ver -gt $u.Ver) }
    if ($c.Kind -eq 'Axx' -and $u.Kind -eq 'Axx') { return ($c.Num -gt $u.Num) }
    if ($c.Kind -eq 'Num' -and $u.Kind -eq 'Axx') { return $true }   # numeric supersedes legacy Axx
    if ($c.Kind -eq 'Axx' -and $u.Kind -eq 'Num') { return $false }
    return $false
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

function Remove-IfExists { param([string]$Path) if (Test-Path $Path) { Remove-Item $Path -Force -ErrorAction SilentlyContinue } }

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

#=================================================
# Main
#=================================================
$ProgressPreference = 'SilentlyContinue'
$BIOSPassword = $null
try {
    foreach ($d in @($StateDir, $TempDir, $LogDir)) { if (-not (Test-Path $d)) { $null = New-Item -Path $d -ItemType Directory -Force } }
    Write-CMLogEntry -Value '--- Remediation started ---' -Severity 1

    if (-not (Test-Path $PendingFile)) {
        Write-CMLogEntry -Value 'No pending.json found; nothing to remediate.' -Severity 2
        Write-Output 'Nothing pending.'
        exit 0
    }
    $p = Get-Content $PendingFile -Raw | ConvertFrom-Json
    $currentBios = ((Get-CimInstance -ClassName Win32_BIOS).SMBIOSBIOSVersion).Trim()
    Write-CMLogEntry -Value "Pending BIOS=$($p.Version)  Installed=$currentBios  File=$($p.FileName)" -Severity 1

    if (-not (Test-NewerVersion -Candidate $p.Version -Current $currentBios)) {
        Write-CMLogEntry -Value "Installed BIOS ($currentBios) already >= pending ($($p.Version)). Clearing." -Severity 1
        Remove-IfExists $PendingFile
        Write-Output "Already at $currentBios."
        exit 0
    }

    #--- Download ---
    if (-not (Test-Path $TempDir)) { $null = New-Item -Path $TempDir -ItemType Directory -Force }
    $exe = Join-Path $TempDir $p.FileName
    Remove-IfExists $exe
    Write-CMLogEntry -Value "Downloading via BITS: $($p.Uri)" -Severity 1
    Start-BitsTransfer -Source $p.Uri -Destination $exe -ErrorAction Stop

    #--- Verify size + SHA1 (Dell publishes SHA1 as Base64) ---
    $actualSize = (Get-Item $exe).Length
    if ($p.Size -and [int64]$p.Size -ne $actualSize) {
        throw "Size mismatch: expected $($p.Size), got $actualSize."
    }
    if ($p.Digest) {
        $expectedHex = ([Convert]::FromBase64String($p.Digest) | ForEach-Object { $_.ToString('x2') }) -join ''
        $actualHex   = (Get-FileHash -Path $exe -Algorithm SHA1).Hash.ToLower()
        if ($actualHex -ne $expectedHex) { throw "SHA1 mismatch: expected $expectedHex, got $actualHex." }
        Write-CMLogEntry -Value "Verified SHA1 ($actualHex) and size ($actualSize bytes)." -Severity 1
    }

    #--- BIOS password ---
    $BIOSPassword = Unprotect-BiosPassword -Key $BiosPasswordKey -Blob $BiosPasswordBlob
    if ($BIOSPassword) { Write-CMLogEntry -Value 'BIOS password decrypted (in memory).' -Severity 1 }
    else               { Write-CMLogEntry -Value 'No BIOS password configured; flashing without /p.' -Severity 1 }

    #--- Suspend BitLocker so the firmware change does not force a recovery prompt ---
    try {
        $blv = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
        if ($blv.ProtectionStatus -eq 'On') {
            Suspend-BitLocker -MountPoint $env:SystemDrive -RebootCount $RebootCount -ErrorAction Stop | Out-Null
            Write-CMLogEntry -Value "BitLocker on $env:SystemDrive suspended for $RebootCount reboot(s)." -Severity 1
        } else {
            Write-CMLogEntry -Value "BitLocker not active on $env:SystemDrive; no suspend needed." -Severity 1
        }
    } catch { Write-CMLogEntry -Value "BitLocker suspend step warning: $($_.Exception.Message)" -Severity 2 }

    #--- Flash (silent, NO /r -> staged, applied on next reboot) ---
    $flashLog = Join-Path $LogDir $FlashLogName
    if ($BIOSPassword) { $argList = "/s /p=""$BIOSPassword"" /l=""$flashLog""" }
    else               { $argList = "/s /l=""$flashLog""" }
    $obscured = if ($BIOSPassword) { $argList.Replace($BIOSPassword, '<redacted>') } else { $argList }
    Write-CMLogEntry -Value "Flashing: $($p.FileName) $obscured  (reboot suppressed)" -Severity 1

    $proc = Start-Process -FilePath $exe -ArgumentList $argList -Wait -PassThru
    $rc = $proc.ExitCode
    if ($BIOSPassword) { Clear-Variable BIOSPassword; $BIOSPassword = $null }
    Write-CMLogEntry -Value "Flash utility exit code: $rc" -Severity 1

    # Per Dell's catalog ReturnCode mapping: 0 = success (no reboot), 2 = success (reboot required).
    if ($rc -eq 0 -or $rc -eq 2) {
        [pscustomobject]@{ StagedVersion = $p.Version; StagedAtUtc = (Get-Date).ToUniversalTime().ToString('o'); ExitCode = $rc } |
            ConvertTo-Json | Set-Content -Path $StagedFile -Encoding UTF8
        Remove-IfExists $PendingFile
        Remove-IfExists $FailedFile
        Remove-IfExists $exe
        Write-CMLogEntry -Value "SUCCESS: BIOS $($p.Version) staged. Reboot required to apply." -Severity 1
        Write-Output "BIOS $($p.Version) staged; reboot required to apply."
        exit 0
    }
    else {
        # Record the failure. The retry cap ($MaxFailedAttempts) is enforced by the DETECTION
        # script, which stops re-triggering this version once the count reaches the threshold.
        $attempts = Set-FailureRecord -Version $p.Version
        # Flash didn't take, so resume protection now rather than leaving it suspended.
        try {
            if ((Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop).ProtectionStatus -ne 'On') {
                Resume-BitLocker -MountPoint $env:SystemDrive -ErrorAction SilentlyContinue | Out-Null
                Write-CMLogEntry -Value 'BitLocker resumed after failed flash.' -Severity 2
            }
        } catch {}
        Remove-IfExists $exe
        Write-CMLogEntry -Value "FAILED: flash exit code $rc (attempt $attempts). See $flashLog." -Severity 3
        Write-Output "BIOS flash failed (exit $rc)."
        exit 1
    }
}
catch {
    if ($BIOSPassword) { Clear-Variable BIOSPassword -ErrorAction SilentlyContinue; $BIOSPassword = $null }
    Write-CMLogEntry -Value "Remediation error: $($_.Exception.Message)" -Severity 3
    Write-Output "Remediation error: $($_.Exception.Message)"
    exit 1
}
