<#

.SYNOPSIS
PSAppDeployToolkit.Extensions - Custom Xerox printer-install helpers for the deployment script.

.DESCRIPTION
Discovery (SNMP), runtime V4 driver resolution, INF driver-name parsing, and the per-queue
XeroxQueueProperties builder used by Invoke-AppDeployToolkit.ps1. Imported automatically by the
launcher so the main script stays focused on the Install/Uninstall/Repair flow.

#>

##*===============================================
##* MARK: MODULE GLOBAL SETUP
##*===============================================

# Set strict error handling across entire module.
$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
$ProgressPreference = [System.Management.Automation.ActionPreference]::SilentlyContinue
Set-StrictMode -Version 1


##*===============================================
##* MARK: FUNCTION LISTINGS
##*===============================================

# --- Minimal dependency-free SNMP v1 GET (so we don't have to bundle an SNMP module) ---
function ConvertTo-XeroxSnmpOidBytes {
    param([string]$Oid)
    $arcs = $Oid.TrimStart('.') -split '\.' | ForEach-Object { [int]$_ }
    $bytes = [System.Collections.Generic.List[byte]]::new()
    $bytes.Add([byte](40 * $arcs[0] + $arcs[1]))   # first two arcs share one byte
    for ($i = 2; $i -lt $arcs.Count; $i++) {
        $v = $arcs[$i]
        if ($v -lt 128) { $bytes.Add([byte]$v) }
        else {
            # base-128 big-endian, high bit set on all but the final group
            $stack = [System.Collections.Generic.List[byte]]::new()
            $stack.Add([byte]($v -band 0x7F)); $v = [int][math]::Floor($v / 128)
            while ($v -gt 0) { $stack.Add([byte](($v -band 0x7F) -bor 0x80)); $v = [int][math]::Floor($v / 128) }
            for ($j = $stack.Count - 1; $j -ge 0; $j--) { $bytes.Add($stack[$j]) }
        }
    }
    , $bytes.ToArray()
}

function New-XeroxSnmpTlv {
    param([byte]$Tag, [byte[]]$Value)
    $out = [System.Collections.Generic.List[byte]]::new()
    $out.Add($Tag)
    $len = $Value.Length
    if ($len -lt 128) { $out.Add([byte]$len) }
    elseif ($len -lt 256) { $out.Add(0x81); $out.Add([byte]$len) }
    else { $out.Add(0x82); $out.Add([byte]($len -shr 8)); $out.Add([byte]($len -band 0xFF)) }
    if ($len -gt 0) { $out.AddRange($Value) }
    , $out.ToArray()
}

function Read-XeroxSnmpFirstVarbindValue {
    param([byte[]]$Data)
    $pos = 0
    function Read-Len {
        param([byte[]]$d, [ref]$p)
        $b = $d[$p.Value]; $p.Value++
        if ($b -lt 128) { return [int]$b }
        $n = $b -band 0x7F; $len = 0
        for ($i = 0; $i -lt $n; $i++) { $len = ($len -shl 8) -bor $d[$p.Value]; $p.Value++ }
        return $len
    }
    if ($Data[$pos] -ne 0x30) { throw 'Not a SNMP SEQUENCE' }; $pos++; [void](Read-Len $Data ([ref]$pos))
    $pos++; $l = Read-Len $Data ([ref]$pos); $pos += $l   # version
    $pos++; $l = Read-Len $Data ([ref]$pos); $pos += $l   # community
    $pos++; [void](Read-Len $Data ([ref]$pos))            # PDU
    $errStatus = 0
    for ($k = 0; $k -lt 3; $k++) { $pos++; $l = Read-Len $Data ([ref]$pos); if ($k -eq 1) { $errStatus = $Data[$pos] }; $pos += $l }
    if ($errStatus -ne 0) { throw "SNMP error-status=$errStatus" }
    $pos++; [void](Read-Len $Data ([ref]$pos))            # varbind list
    $pos++; [void](Read-Len $Data ([ref]$pos))            # first varbind
    $pos++; $l = Read-Len $Data ([ref]$pos); $pos += $l   # OID
    $vtag = $Data[$pos]; $pos++; $vlen = Read-Len $Data ([ref]$pos)
    $val = $Data[$pos..($pos + $vlen - 1)]
    if ($vtag -eq 0x04) { return [System.Text.Encoding]::UTF8.GetString($val) }
    return [System.Text.Encoding]::UTF8.GetString($val)
}

function Get-XeroxSnmpValue {
    param(
        [Parameter(Mandatory)][string]$Target,
        [string]$Oid = '1.3.6.1.2.1.1.1.0',   # sysDescr.0
        [string]$Community = 'public',
        [int]$TimeoutMs = 3000,
        [int]$Retries = 2
    )
    $oidTlv  = New-XeroxSnmpTlv 0x06 (ConvertTo-XeroxSnmpOidBytes $Oid)
    $nullTlv = New-XeroxSnmpTlv 0x05 @()
    $vbList  = New-XeroxSnmpTlv 0x30 (New-XeroxSnmpTlv 0x30 ($oidTlv + $nullTlv))
    $ridB    = [BitConverter]::GetBytes([int](Get-Random -Minimum 1 -Maximum 2147483647)); [array]::Reverse($ridB)
    $pdu     = New-XeroxSnmpTlv 0xA0 ((New-XeroxSnmpTlv 0x02 $ridB) + (New-XeroxSnmpTlv 0x02 @([byte]0)) + (New-XeroxSnmpTlv 0x02 @([byte]0)) + $vbList)
    $msg     = New-XeroxSnmpTlv 0x30 ((New-XeroxSnmpTlv 0x02 @([byte]0)) + (New-XeroxSnmpTlv 0x04 ([System.Text.Encoding]::ASCII.GetBytes($Community))) + $pdu)

    $udp = [System.Net.Sockets.UdpClient]::new()
    try {
        $udp.Client.ReceiveTimeout = $TimeoutMs
        $udp.Connect($Target, 161)
        for ($try = 0; $try -le $Retries; $try++) {
            try {
                [void]$udp.Send($msg, $msg.Length)
                $remote = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
                return (Read-XeroxSnmpFirstVarbindValue $udp.Receive([ref]$remote))
            }
            catch [System.Net.Sockets.SocketException] { if ($try -eq $Retries) { throw } }
        }
    }
    finally { $udp.Close() }
}

# Resolve an AltaLink model + series digit from a printer over SNMP. Returns $null if unreachable.
function Get-XeroxPrinterModel {
    param([Parameter(Mandatory)][string[]]$Targets)
    $oids = @('1.3.6.1.2.1.1.1.0', '1.3.6.1.2.1.25.3.2.1.3.1')   # sysDescr, hrDeviceDescr
    foreach ($target in $Targets) {
        if ([string]::IsNullOrWhiteSpace($target)) { continue }
        foreach ($oid in $oids) {
            try {
                $raw = Get-XeroxSnmpValue -Target $target -Oid $oid
                if ($raw -match 'C8(\d)\d{2}') {
                    return [pscustomobject]@{ Model = $Matches[0]; SeriesDigit = [int]$Matches[1]; Raw = $raw }
                }
            }
            catch { Write-ADTLogEntry "SNMP $oid on $target failed: $($_.Exception.Message)" -Severity 2 }
        }
    }
    return $null
}

# Scrape support.xerox.com for the CURRENT V4 PostScript x64 driver ZIP of a given series.
# This means we always pull Xerox's latest build with no hard-coded version in the package.
function Resolve-XeroxDriverUrl {
    param([Parameter(Mandatory)][int]$SeriesDigit)
    $slug = "altalink-c8${SeriesDigit}00-series"
    $page = "https://www.support.xerox.com/en-us/product/$slug/downloads?platform=win10x64&language=en"
    $html = (Invoke-WebRequest -Uri $page -UseBasicParsing -TimeoutSec 30).Content
    $rx   = "https?://download\.support\.xerox\.com/pub/drivers/[^""'' <\\]*C8${SeriesDigit}xx[^""'' <\\]*PS_x64\.zip"
    [regex]::Matches($html, $rx, 'IgnoreCase') | Select-Object -ExpandProperty Value -Unique | Select-Object -First 1
}

# Pick the exact print-driver name from the extracted INF for a detected model (e.g. C8270).
function Get-XeroxDriverNameFromInf {
    param([Parameter(Mandatory)][string]$InfPath, [Parameter(Mandatory)][string]$Model)
    $text  = Get-Content -LiteralPath $InfPath -Raw
    $names = [regex]::Matches($text, '"(Xerox[^"]*V4 PS)"') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique
    $exact = $names | Where-Object { $_ -match [regex]::Escape($Model) -and $_ -notmatch '/' } | Select-Object -First 1
    if ($exact) { return $exact }
    $loose = $names | Where-Object { $_ -match [regex]::Escape($Model) } | Select-Object -First 1
    if ($loose) { return $loose }
    return ($names | Select-Object -First 1)
}

# Build the COMPLETE per-queue XeroxQueueProperties value from the known-good "golden" device-settings
# captured from a correctly-configured queue: Acquire Device Status = Never
# (xdrv-device-bidi-communication = bidi-communication-off), Share Diagnostic Data = off, Windows
# PIN-Protected Printing = disabled (by ABSENCE of any key), plus Xerox Standard Accounting.
#
# We write this ourselves every time and never poll/wait, because the Desktop Print Experience only
# materializes XeroxQueueProperties as a side-effect of its FIRST install -- the 2nd+ queue on a machine
# never gets one on its own. host/IP/code are parameterized; only 3 cosmetic identity fields differ
# between series and are swapped by series digit. If $Code is not 4 digits (e.g. a no-code/guest printer)
# accounting is turned off but the device settings still apply.
function New-XeroxQueuePropertiesValue {
    param(
        [AllowNull()][string]$Existing,
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][string]$IpAddress,
        [AllowNull()][string]$Code,
        [Parameter(Mandatory)][string]$PortName,
        [Parameter(Mandatory)][int]$SeriesDigit
    )

    # The ONLY fields that differ between the C81xx and C82xx golden values (everything else identical).
    $idMap = @{
        1 = @{ Release = 'XeroxAltaLinkC81xx'; Product = 'Corvo';  Creator = 'V4Driver 7.146.0.0 2019 Nov-20 21:23:40-05:00 | QueueSettings 8.158.0.0V 2025.01.30' }
        2 = @{ Release = 'XeroxAltalinkC82xx'; Product = 'Corrib'; Creator = 'V4Driver 8.132.0.0 2024 May-1 23:55:47-04:00 | QueueSettings 8.158.0.0V 2025.01.30' }
    }
    $id = if ($idMap.ContainsKey($SeriesDigit)) { $idMap[$SeriesDigit] } else { @{ Release = "XeroxAltaLinkC8${SeriesDigit}xx"; Product = 'Xerox'; Creator = 'V4Driver | QueueSettings' } }

    $hasCode = $Code -match '^\d{4}$'

    $golden = @'
<?xml version="1.0" encoding="UTF-8"?>
<XeroxDeviceSettings cpss-version="2.07" version="2.0" xml:lang="en-US" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
	<color-supported syntax="boolean">true</color-supported>
	<creator-name-attributes syntax="keyword">windows-queue-settings-manager</creator-name-attributes>
	<creator-name-pdl syntax="keyword">unknown-application</creator-name-pdl>
	<creator-version-attributes syntax="text" xml:space="preserve">%%CREATOR%%</creator-version-attributes>
	<date-time-at-creation syntax="dateTime">%%DATETIME%%</date-time-at-creation>
	<host-address-col syntax="collection">
		<host-address syntax="text" xml:space="preserve">%%IP%%</host-address>
		<host-address-type syntax="keyword">ipv4</host-address-type>
	</host-address-col>
	<job-accounting-required syntax="1setOf">
		<value syntax="keyword">color-jobs</value>
		<value syntax="keyword">monochrome-jobs</value>
	</job-accounting-required>
	<time-zone-offset syntax="integer">-240</time-zone-offset>
	<user-domain-api syntax="name" xml:space="preserve">%%USERDOMAIN%%</user-domain-api>
	<user-name-api syntax="name" xml:space="preserve">%%USERNAME%%</user-name-api>
	<xdrv-accounting-print-time-prompt-toggle syntax="keyword">disabled</xdrv-accounting-print-time-prompt-toggle>
	<xdrv-al-handler syntax="keyword">enabled</xdrv-al-handler>
	<xdrv-dev-accounting-mask-account-id syntax="keyword">on</xdrv-dev-accounting-mask-account-id>
	<xdrv-dev-accounting-mask-user-id syntax="keyword">on</xdrv-dev-accounting-mask-user-id>
	<xdrv-dev-accounting-prompt-option syntax="keyword">for-monochrome-and-color</xdrv-dev-accounting-prompt-option>
	<xdrv-dev-accounting-save-ids syntax="keyword">off</xdrv-dev-accounting-save-ids>
	<xdrv-dev-bidi-toggle syntax="keyword">automatic</xdrv-dev-bidi-toggle>
	<xdrv-dev-configure-doc-encryption syntax="keyword">manually-encrypt-documents</xdrv-dev-configure-doc-encryption>
	<xdrv-dev-sync-app-and-driver-black-and-white syntax="keyword">sync-bw-not-forced</xdrv-dev-sync-app-and-driver-black-and-white>
	<xdrv-device-al-complex-job-settings syntax="keyword">enable-complex-settings</xdrv-device-al-complex-job-settings>
	<xdrv-device-al-repeated-job-settings syntax="keyword">enable-repetitive-settings</xdrv-device-al-repeated-job-settings>
	<xdrv-device-bidi-communication syntax="keyword">bidi-communication-off</xdrv-device-bidi-communication>
	<xdrv-device-bidi-ip-address syntax="name" xml:space="preserve">%%HOST%%</xdrv-device-bidi-ip-address>
	<xdrv-device-bidi-refresh-rate syntax="integer">5</xdrv-device-bidi-refresh-rate>
	<xdrv-device-bidi-snmp-read-community-name syntax="name" xml:space="preserve">public</xdrv-device-bidi-snmp-read-community-name>
	<xdrv-device-bidi-snmp-write-community-name syntax="name" xml:space="preserve">private</xdrv-device-bidi-snmp-write-community-name>
	<xdrv-device-black-and-white-only syntax="keyword">black-and-white-only-disabled</xdrv-device-black-and-white-only>
	<xdrv-device-secure-print-only syntax="keyword">secure-print-only-disabled</xdrv-device-secure-print-only>
	<xdrv-device-share-diagnostic-data syntax="keyword">off</xdrv-device-share-diagnostic-data>
	<xdrv-driver-pdl syntax="keyword">pdl-ps</xdrv-driver-pdl>
	<xdrv-driver-version-high syntax="integer">524446</xdrv-driver-version-high>
	<xdrv-driver-version-low syntax="integer">0</xdrv-driver-version-low>
	<xdrv-job-account-type syntax="keyword">default-group-account</xdrv-job-account-type>
	<xdrv-job-accounting-required-enabled syntax="keyword">%%ACCT%%</xdrv-job-accounting-required-enabled>
	<xdrv-job-accounting-user-id syntax="name" xml:space="preserve">%%CODE%%</xdrv-job-accounting-user-id>
	<xdrv-ms-separator syntax="boolean">false</xdrv-ms-separator>
	<xdrv-printer-company-name syntax="keyword">xdrv-printer-company-name-xerox</xdrv-printer-company-name>
	<xdrv-printer-controller-family syntax="keyword">xdrv-discovery</xdrv-printer-controller-family>
	<xdrv-printer-product-name syntax="name" xml:space="preserve">%%PRODUCT%%</xdrv-printer-product-name>
	<xdrv-prompt-me-to-choose-accounting-type syntax="keyword">off</xdrv-prompt-me-to-choose-accounting-type>
	<xdrv-release-descriptor syntax="name" xml:space="preserve">%%RELEASE%%</xdrv-release-descriptor>
	<xdrv-ui-auto-config-status syntax="keyword">configured-xbds</xdrv-ui-auto-config-status>
	<xdrv-ui-device-configuration syntax="keyword">automatic</xdrv-ui-device-configuration>
</XeroxDeviceSettings>
'@

    $tokens = @{
        '%%CREATOR%%'    = $id.Creator
        '%%DATETIME%%'   = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
        '%%IP%%'         = $IpAddress
        '%%USERDOMAIN%%' = $env:USERDOMAIN
        '%%USERNAME%%'   = $env:USERNAME
        '%%HOST%%'       = $HostName
        '%%ACCT%%'       = $(if ($hasCode) { 'on' } else { 'off' })
        '%%CODE%%'       = $(if ($hasCode) { $Code } else { '' })
        '%%PRODUCT%%'    = $id.Product
        '%%RELEASE%%'    = $id.Release
    }
    $inner = $golden
    foreach ($t in $tokens.Keys) { $inner = $inner.Replace($t, [string]$tokens[$t]) }

    # The inner device-settings is the single source of truth. If a value already exists (re-run, or the
    # rare case the extension wrote one), swap ONLY its CDATA payload and keep the outer wrapper
    # (PortInfo / TelemetryData / DeviceName). Otherwise build a fresh, minimal-but-valid outer.
    if ($Existing -match '(?s)<XeroxDeviceSettings>\s*<!\[CDATA\[.*?\]\]>\s*</XeroxDeviceSettings>') {
        return [regex]::Replace($Existing, '(?s)(<XeroxDeviceSettings>\s*<!\[CDATA\[).*?(\]\]>\s*</XeroxDeviceSettings>)',
            [System.Text.RegularExpressions.MatchEvaluator] { param($m) $m.Groups[1].Value + $inner + $m.Groups[2].Value })
    }
    return "<?xml version=`"1.0`" encoding=`"utf-8`"?><XeroxQueueProperties><PortInfo><![CDATA[Name,$PortName;MonitorName,TCPMON.DLL;Description,Standard TCP/IP Port;Protocol,1]]></PortInfo><IpOrHostName><![CDATA[$HostName]]></IpOrHostName><AutomaticIpOrHostName><![CDATA[$HostName]]></AutomaticIpOrHostName><IpOrHostNameManuallyOverridden><![CDATA[0]]></IpOrHostNameManuallyOverridden><SnmpReadCommunityNameManuallyOverridden><![CDATA[0]]></SnmpReadCommunityNameManuallyOverridden><SnmpReadCommunityName><![CDATA[public]]></SnmpReadCommunityName><XeroxDeviceSettings><![CDATA[$inner]]></XeroxDeviceSettings></XeroxQueueProperties>"
}


##*===============================================
##* MARK: SCRIPT BODY
##*===============================================

# Announce successful importation of module.
Write-ADTLogEntry -Message "Module [$($MyInvocation.MyCommand.ScriptBlock.Module.Name)] imported successfully." -ScriptSection Initialization
