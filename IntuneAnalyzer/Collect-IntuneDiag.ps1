<#
.SYNOPSIS
    Offline Intune-style diagnostics collector. Produces DiagLogs-<PC>-<ts>Z.zip
    in the same self-describing "(N) CollectorType descriptor" layout the Intune
    "Collect diagnostics" package uses, so the RCA tool ingests it natively.
.DESCRIPTION
    Use when Intune's diagnostic pipeline is slow/stuck, or when you're already
    on the machine (RMM). Run ELEVATED for full coverage (event log export,
    manage-bde, mdmdiagnosticstool); unelevated runs produce a degraded package.
    Extras beyond the Intune manifest: SecureBoot servicing registry (BitLocker
    suspend-guard analysis) and full schtasks inventory (reboot forensics).
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Collect-IntuneDiag.ps1
    # -> DiagLogs-<HOSTNAME>-20260716T190000Z.zip in %TEMP% (or -OutDir)
#>
param([string]$OutDir = $env:TEMP)

$ErrorActionPreference = 'Continue'
$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmss') + 'Z'
$name  = "DiagLogs-$env:COMPUTERNAME-$stamp"
$work  = Join-Path $env:TEMP $name
New-Item -ItemType Directory -Path $work -Force | Out-Null
$script:i = 0
function NextName([string]$label) { $script:i++; Join-Path $work "($script:i) $label" }
function Log([string]$m) { Write-Host "[$('{0:mm\:ss}' -f ((Get-Date) - $start))] $m" }
$start = Get-Date

# ---- 1. Event logs (channels the RCA parsers/rules actually consume) --------
$channels = @(
    'System', 'Application',
    'Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin',
    'Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Operational',
    'Microsoft-Windows-BitLocker/BitLocker Management',
    'Microsoft-Windows-AAD/Operational',
    'Microsoft-Windows-User Device Registration/Admin',
    'Microsoft-Windows-AppXDeploymentServer/Operational',
    'Microsoft-Windows-WMI-Activity/Operational',
    'Microsoft-Windows-TaskScheduler/Operational',
    'Microsoft-Windows-Audio/CaptureMonitor',                # mic capture session start/stop (dropout cases)
    'Microsoft-Windows-Audio/Operational'
)
foreach ($ch in $channels) {
    $safe = $ch -replace '[\\/ ]', '_'
    $dest = NextName "Events $safe Events.evtx"
    wevtutil epl "$ch" "$dest" 2>$null
    if (-not (Test-Path $dest)) { Log "skip (no access/log): $ch" }
}
Log "event logs done"

# ---- 2. Registry exports (reg.exe emits UTF-16 .reg, as the parser expects) -
$regKeys = @(
    'HKLM\SYSTEM\CurrentControlSet\Control\SecureBoot',              # suspend-guard state (NOT in Intune manifest)
    'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',      # installed apps
    'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM\SOFTWARE\Microsoft\Enrollments',                           # ESP FirstSync state
    'HKLM\SOFTWARE\Microsoft\IntuneManagementExtension',
    'HKLM\SOFTWARE\Policies\Microsoft\FVE',                          # BitLocker policy
    'HKLM\SOFTWARE\Microsoft\Policies\PassportForWork',              # WHfB tombstones (PIN expiry lives here)
    'HKLM\SYSTEM\CurrentControlSet\Control\ComputerName',            # pending rename
    'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion'              # build/UBR
)
foreach ($k in $regKeys) {
    $safe = $k -replace '[\\ ]', '_'
    reg export "$k" (NextName "RegistryKey $safe export.reg") /y *> $null
}
Log "registry exports done"

# ---- 3. Command outputs ------------------------------------------------------
$commands = @(
    @{ Label = 'dsregcmd_status';        Cmd = { dsregcmd /status } },
    @{ Label = 'manage-bde_status';      Cmd = { manage-bde -status } },
    @{ Label = 'schtasks_query_verbose'; Cmd = { schtasks /query /fo LIST /v } },
    @{ Label = 'ipconfig_all';           Cmd = { ipconfig /all } },
    @{ Label = 'systeminfo';             Cmd = { systeminfo } },
    @{ Label = 'audio_endpoints';        Cmd = { Get-PnpDevice -Class AudioEndpoint,MEDIA | Sort-Object Class | Format-List FriendlyName, Status, InstanceId } },
    @{ Label = 'net_localgroup';         Cmd = { net localgroup Users; net localgroup Administrators } }
)
foreach ($c in $commands) {
    & $c.Cmd 2>&1 | Out-File -FilePath (NextName "Command $($c.Label) output.log") -Encoding utf8
}
Log "commands done"

# ---- 4. Folder/file trees ----------------------------------------------------
function Copy-Tree([string]$src, [string]$label, [string[]]$include = @('*')) {
    if (-not (Test-Path $src)) { return }
    $dest = NextName "FoldersFiles $label"
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    Get-ChildItem $src -File -Recurse -Include $include -ErrorAction SilentlyContinue |
        ForEach-Object { Copy-Item $_.FullName -Destination $dest -ErrorAction SilentlyContinue }
}
Copy-Tree "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs" 'ProgramData_Microsoft_IntuneManagementExtension_Logs'
Copy-Tree "$env:windir\Logs\WindowsUpdate" 'windir_logs_windowsupdate_etl' @('*.etl')
Copy-Tree "$env:windir\Logs\MeasuredBoot" 'windir_logs_measuredboot' @('*.log')
# CBS.log named to match the BitLocker/CBS analysis path convention
$cbsDest = NextName "FoldersFiles windir_logs_CBS_cbs_log"
New-Item -ItemType Directory -Path $cbsDest -Force | Out-Null
Copy-Item "$env:windir\Logs\CBS\CBS.log" $cbsDest -ErrorAction SilentlyContinue
Log "file trees done"

# ---- 5. Battery report (ingest reads ReportUtcOffset for device-local time) --
$battDir = NextName "FoldersFiles temp_MDMDiagnostics_battery-report_html"
New-Item -ItemType Directory -Path $battDir -Force | Out-Null
powercfg /batteryreport /output (Join-Path $battDir 'battery-report.html') *> $null

# ---- 6. MDM diagnostics CAB (MDMDiagReport.xml + PolicyManager dump + evtx) --
$mdmDir = NextName "FoldersFiles temp_MDMDiagnostics_mdmlogs-$stamp`_cab"
New-Item -ItemType Directory -Path $mdmDir -Force | Out-Null
mdmdiagnosticstool.exe -area 'DeviceEnrollment;DeviceProvisioning;Autopilot' -cab (Join-Path $mdmDir "mdmlogs-$stamp.cab") *> $null
Log "mdm cab done"

# ---- 7. Zip it in the DiagLogs-<machine>-<ts>Z.zip convention ----------------
$zip = Join-Path $OutDir "$name.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $work '*') -DestinationPath $zip -CompressionLevel Optimal
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
Log "package ready: $zip ($([math]::Round((Get-Item $zip).Length/1MB,1)) MB)"
Write-Output $zip
