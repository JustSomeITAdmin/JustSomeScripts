<#
.SYNOPSIS
    Intune Remediation - DETECTION script.
    Determines whether a newer Dell System BIOS is available for THIS device by
    querying Dell's current Enterprise SDP catalog (DellSDPCatalogPC.cab).

.DESCRIPTION
    - Identifies the device by Win32_ComputerSystem.SystemSKUNumber (Dell hex System ID,
      e.g. "0A9F"), converted to decimal to match the catalog's SystemTypeID (2719).
    - Downloads the SDP catalog via BITS (HTTPS) only when Dell has published a newer one
      (cached/keyed on the catalog's Last-Modified header), then stream-parses it for the
      latest "System BIOS" package applicable to this SystemTypeID.
    - Compares the catalog's latest BIOS version to the installed version.

    Exit 0 = compliant (no update / already staged / could not evaluate).
    Exit 1 = NON-compliant -> triggers the remediation script.

    Run as SYSTEM, 64-bit PowerShell.

    NOTE: The old CatalogPC.cab was RETIRED by Dell in Dec 2025 and is now stale.
          This script uses DellSDPCatalogPC.cab, which Dell keeps current.
#>

#=================================================
# Config
#=================================================
$CatalogUri = 'https://downloads.dell.com/catalog/DellSDPCatalogPC.cab'
$StateDir   = 'C:\ProgramData\Dell'
$TempDir    = Join-Path $env:TEMP 'DellBiosUpdate'
$LogDir     = 'C:\Windows\Logs\Software'
$LogFile    = 'DellBIOSUpdate.log'
$MaxFailedAttempts = 3   # stop re-triggering a version that keeps failing to flash

$PendingFile = Join-Path $StateDir 'pending.json'
$StagedFile  = Join-Path $StateDir 'staged.json'
$CacheFile   = Join-Path $StateDir 'modelcache.json'
$FailedFile  = Join-Path $StateDir 'failed.json'

#=================================================
# Logging (CMTrace format)
#=================================================
function Write-CMLogEntry {
    param(
        [Parameter(Mandatory)][string]$Value,
        [ValidateSet('1','2','3')][string]$Severity = '1',
        [string]$Component = 'DellBIOSUpdate-Detect',
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
function Get-DellSystemTypeId {
    # Returns the Dell SystemTypeID as a decimal integer (catalog format), or $null.
    $sku = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue).SystemSKUNumber
    if ([string]::IsNullOrWhiteSpace($sku)) {
        $sku = (Get-CimInstance -Namespace 'root\wmi' -ClassName MS_SystemInformation -ErrorAction SilentlyContinue).SystemSku
    }
    if ([string]::IsNullOrWhiteSpace($sku)) { return $null }
    $sku = $sku.Trim()
    if ($sku -notmatch '^[0-9A-Fa-f]{3,4}$') { return $null }   # business systems use a 3-4 char hex System ID
    try { return [Convert]::ToInt32($sku, 16) } catch { return $null }
}

function Get-BiosVersionFromTitle {
    # Title: "Dell <model>[, <descriptor>] System BIOS,<ver>,<ver-suffix>".
    # Most are 3 fields, but some insert ", Intel vPro supported" before the version,
    # so return the FIRST comma-field (after field 0) that is version-shaped.
    param([string]$Title)
    $fields = $Title -split ','
    for ($k = 1; $k -lt $fields.Count; $k++) {
        $f = $fields[$k].Trim()
        if ($f -match '^(A\d+(-\d+)?|\d+(\.\d+)*)$') { return $f }
    }
    return $null
}

function ConvertTo-BiosKind {
    # Classify a Dell BIOS version: numeric (x.x[.x]) or legacy Axx.
    param([string]$v)
    if ($v -match '^A(\d+)') { return @{ Kind = 'Axx'; Num = [int]$Matches[1] } }
    $ver = $null
    if ([version]::TryParse($v, [ref]$ver)) { return @{ Kind = 'Num'; Ver = $ver } }
    return @{ Kind = 'Unknown' }
}

function Test-NewerVersion {
    # True if $Candidate is a newer BIOS than $Current. Handles both numeric and Axx,
    # and the rare numeric/Axx transition (numeric scheme supersedes Axx).
    param([string]$Candidate, [string]$Current)
    if ([string]::IsNullOrWhiteSpace($Candidate) -or [string]::IsNullOrWhiteSpace($Current)) { return $false }
    if ($Candidate.Trim() -ieq $Current.Trim()) { return $false }
    $c = ConvertTo-BiosKind $Candidate.Trim()
    $u = ConvertTo-BiosKind $Current.Trim()
    if ($c.Kind -eq 'Num' -and $u.Kind -eq 'Num') { return ($c.Ver -gt $u.Ver) }
    if ($c.Kind -eq 'Axx' -and $u.Kind -eq 'Axx') { return ($c.Num -gt $u.Num) }
    if ($c.Kind -eq 'Num' -and $u.Kind -eq 'Axx') { return $true }   # numeric supersedes legacy Axx
    if ($c.Kind -eq 'Axx' -and $u.Kind -eq 'Num') { return $false }
    return $false   # unknown format on either side: don't flag (conservative)
}

function Test-ModelMatch {
    # True if the device model exactly matches a model token in a BIOS package Title.
    # Title looks like "Dell <model>[ and <model>][/<model>] System BIOS,<ver>,<ver>".
    param([string]$Title, [string]$Model)
    if ([string]::IsNullOrWhiteSpace($Model)) { return $false }
    $i = $Title.IndexOf(' System BIOS'); if ($i -lt 0) { return $false }
    $seg = $Title.Substring(0, $i)
    if ($seg -like 'Dell *') { $seg = $seg.Substring(5) }
    foreach ($tok in ($seg -split ',|/|\s+and\s+')) { if ($tok.Trim() -ieq $Model) { return $true } }
    return $false
}

function Get-LatestDellBios {
    # Stream-parse the SDP catalog for the newest "System BIOS" package applicable to this device.
    # A package matches if its applicability lists our SystemTypeID OR its Title names our model.
    # (Most superseded BIOS packages are "bare" - only the current one carries SystemTypeID -
    #  so model-name matching is what reliably catches the full version history.)
    param(
        [Parameter(Mandatory)][int]$SystemTypeId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Model,
        [Parameter(Mandatory)][string]$XmlPath
    )

    $needle  = "SystemTypeID = '$SystemTypeId'"
    $startTag = '<smc:SoftwareDistributionPackage'
    $endTag   = '</smc:SoftwareDistributionPackage>'
    $reader  = [System.IO.StreamReader]::new($XmlPath)
    $sb      = [System.Text.StringBuilder]::new()
    $inPkg   = $false
    $best    = $null

    try {
        while ($null -ne ($line = $reader.ReadLine())) {
            if (-not $inPkg) {
                if ($line.Contains($startTag)) { $inPkg = $true; [void]$sb.Clear(); [void]$sb.AppendLine($line) }
                continue
            }
            [void]$sb.AppendLine($line)
            if (-not $line.Contains($endTag)) { continue }

            # End of a package block - evaluate it.
            $inPkg = $false
            $block = $sb.ToString()
            if (-not $block.Contains('System BIOS')) { continue }

            if ($block -notmatch '<sdp:Title>([^<]*System BIOS[^<]*)</sdp:Title>') { continue }
            $title = $matches[1].Trim()
            if (-not ($block.Contains($needle) -or (Test-ModelMatch -Title $title -Model $Model))) { continue }
            $ver = Get-BiosVersionFromTitle -Title $title
            if ([string]::IsNullOrWhiteSpace($ver)) { continue }

            $uri = if ($block -match 'OriginFile[^>]*\bOriginUri="([^"]+)"') { $matches[1] } else { $null }
            if (-not $uri) { continue }
            $digest = if ($block -match 'OriginFile[^>]*\bDigest="([^"]+)"')   { $matches[1] } else { $null }
            $fname  = if ($block -match 'OriginFile[^>]*\bFileName="([^"]+)"') { $matches[1] } else { ($uri -split '/')[-1] }
            $size   = if ($block -match 'OriginFile[^>]*\bSize="([^"]+)"')     { [int64]$matches[1] } else { 0 }

            if ($null -eq $best -or (Test-NewerVersion -Candidate $ver -Current $best.Version)) {
                $best = [pscustomobject]@{
                    Title = $title; Version = $ver; Uri = $uri; FileName = $fname; Digest = $digest; Size = $size
                }
            }
        }
    } finally { $reader.Dispose() }
    return $best
}

function Remove-IfExists { param([string]$Path) if (Test-Path $Path) { Remove-Item $Path -Force -ErrorAction SilentlyContinue } }

#=================================================
# Main
#=================================================
$ProgressPreference = 'SilentlyContinue'
try {
    foreach ($d in @($StateDir, $TempDir, $LogDir)) { if (-not (Test-Path $d)) { $null = New-Item -Path $d -ItemType Directory -Force } }
    Write-CMLogEntry -Value '--- Detection started ---' -Severity 1

    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    if ($cs.Manufacturer -notmatch 'Dell') {
        Write-CMLogEntry -Value "Manufacturer '$($cs.Manufacturer)' is not Dell. Nothing to do." -Severity 2
        Write-Output 'Not a Dell system; skipping.'
        exit 0
    }
    $model = if ($cs.Model) { $cs.Model.Trim() } else { '' }
    $sysId = Get-DellSystemTypeId
    if ($null -eq $sysId -and [string]::IsNullOrWhiteSpace($model)) {
        Write-CMLogEntry -Value 'Could not determine a Dell SystemTypeID or model. Nothing to do.' -Severity 2
        Write-Output 'No usable Dell identifier; skipping.'
        exit 0
    }
    $sysIdForMatch = if ($null -ne $sysId) { $sysId } else { -1 }   # -1 = no SystemTypeID match; rely on model name
    $currentBios = ((Get-CimInstance -ClassName Win32_BIOS).SMBIOSBIOSVersion).Trim()
    Write-CMLogEntry -Value "Model='$model'  SystemTypeID=$sysId  InstalledBIOS=$currentBios" -Severity 1

    #--- Already-staged guard: don't re-flash while waiting for the user to reboot ---
    if (Test-Path $StagedFile) {
        $staged = Get-Content $StagedFile -Raw | ConvertFrom-Json
        if (-not (Test-NewerVersion -Candidate $staged.StagedVersion -Current $currentBios)) {
            Write-CMLogEntry -Value "Staged BIOS $($staged.StagedVersion) now applied (installed=$currentBios). Clearing marker." -Severity 1
            Remove-IfExists $StagedFile
            Remove-IfExists $FailedFile
        }
        else {
            Write-CMLogEntry -Value "BIOS $($staged.StagedVersion) already staged on $($staged.StagedAtUtc) - awaiting reboot. Compliant." -Severity 1
            Write-Output "BIOS $($staged.StagedVersion) staged; awaiting reboot."
            exit 0
        }
    }

    #--- Find the latest BIOS for this model (cache keyed on Dell's catalog Last-Modified) ---
    $lastMod = $null
    try {
        $head = Invoke-WebRequest -Uri $CatalogUri -Method Head -UseBasicParsing -TimeoutSec 60
        $lastMod = ($head.Headers['Last-Modified'] | Select-Object -First 1)
    } catch { Write-CMLogEntry -Value "HEAD on catalog failed ($($_.Exception.Message)); will download fresh." -Severity 2 }

    $latest = $null
    if ($lastMod -and (Test-Path $CacheFile)) {
        $cache = Get-Content $CacheFile -Raw | ConvertFrom-Json
        if ($cache.CatalogLastModified -eq $lastMod -and $cache.Model -eq $model -and $cache.SystemTypeId -eq $sysId -and $cache.Latest) {
            $latest = $cache.Latest
            Write-CMLogEntry -Value "Catalog unchanged ($lastMod); using cached latest = $($latest.Version)." -Severity 1
        }
    }

    if (-not $latest) {
        $cab = Join-Path $TempDir 'DellSDPCatalogPC.cab'
        $xml = Join-Path $TempDir 'DellSDPCatalogPC.xml'
        Remove-IfExists $cab; Remove-IfExists $xml
        Write-CMLogEntry -Value "Downloading catalog via BITS: $CatalogUri" -Severity 1
        Start-BitsTransfer -Source $CatalogUri -Destination $cab -ErrorAction Stop
        Write-CMLogEntry -Value "Expanding catalog ($([math]::Round((Get-Item $cab).Length/1MB,1)) MB)..." -Severity 1
        $null = & "$env:windir\System32\expand.exe" "$cab" -F:* "$TempDir"
        if (-not (Test-Path $xml)) { throw "Catalog expand failed; $xml not found." }

        Write-CMLogEntry -Value "Parsing catalog (SystemTypeID=$sysId, Model='$model') ..." -Severity 1
        $latest = Get-LatestDellBios -SystemTypeId $sysIdForMatch -Model $model -XmlPath $xml

        if ($latest) {
            [pscustomobject]@{ CatalogLastModified = $lastMod; SystemTypeId = $sysId; Model = $model; Latest = $latest } |
                ConvertTo-Json -Depth 5 | Set-Content -Path $CacheFile -Encoding UTF8
        }
        # Honor "remove temp files once we're done" - keep only the tiny state files.
        Remove-IfExists $cab; Remove-IfExists $xml
    }

    if (-not $latest) {
        Write-CMLogEntry -Value "No System BIOS package found in catalog for SystemTypeID $sysId." -Severity 2
        Write-Output "No BIOS found in catalog for SystemTypeID $sysId."
        exit 0
    }
    Write-CMLogEntry -Value "Latest catalog BIOS for $sysId = $($latest.Version) ($($latest.FileName))." -Severity 1

    #--- Compare ---
    if (Test-NewerVersion -Candidate $latest.Version -Current $currentBios) {

        # Cooldown: stop hammering a version that keeps failing to flash.
        if (Test-Path $FailedFile) {
            $failed = Get-Content $FailedFile -Raw | ConvertFrom-Json
            if ($failed.Version -eq $latest.Version -and [int]$failed.Count -ge $MaxFailedAttempts) {
                Write-CMLogEntry -Value "BIOS $($latest.Version) has failed $($failed.Count) times; suppressing further attempts until a newer BIOS is published." -Severity 3
                Write-Output "BIOS $($latest.Version) repeatedly failed; suppressed."
                exit 0
            }
        }

        [pscustomobject]@{
            Version = $latest.Version; Uri = $latest.Uri; FileName = $latest.FileName
            Digest = $latest.Digest; Size = $latest.Size; DetectedUtc = (Get-Date).ToUniversalTime().ToString('o')
        } | ConvertTo-Json -Depth 5 | Set-Content -Path $PendingFile -Encoding UTF8

        Write-CMLogEntry -Value "UPDATE AVAILABLE: installed=$currentBios -> latest=$($latest.Version). Flagging for remediation." -Severity 1
        Write-Output "BIOS update available: $currentBios -> $($latest.Version)"
        exit 1
    }
    else {
        Remove-IfExists $PendingFile
        Write-CMLogEntry -Value "BIOS up to date (installed=$currentBios, latest=$($latest.Version))." -Severity 1
        Write-Output "BIOS up to date ($currentBios)."
        exit 0
    }
}
catch {
    Write-CMLogEntry -Value "Detection error: $($_.Exception.Message)" -Severity 3
    Write-Output "Detection error: $($_.Exception.Message)"
    exit 0   # never trigger remediation on a detection failure
}
