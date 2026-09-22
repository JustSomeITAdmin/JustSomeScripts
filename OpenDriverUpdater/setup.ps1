#Requires -Version 5.1
<#
.SYNOPSIS
    One-shot preparer for OpenDriverUpdater: validate the config, fetch PSADT, and generate everything that must
    stay in sync with driverConfig.json so an admin can't miss a step.

.DESCRIPTION
    Run this after cloning and editing driverConfig.json (or use -Interactive to fill the core fields). It:
      1. validates driverConfig.json (required fields, formats, profiles) and stops with a clear list if anything's off;
      2. fetches PSAppDeployToolkit 4.2 via tools\Get-PSADT.ps1 (unless already present or -SkipPSADT);
      3. GENERATES one Detection\DriverUpdate-Detection-<Profile>.ps1 per configured profile, stamped with the
         config's stateDir\Package and packageVersion - so the detection scripts can never drift from the config;
      4. syncs the launcher's -CustomParam ValidateSet to the configured profiles;
      5. prints a readiness summary and the exact install command per profile.

    It changes only Detection\*.ps1 and the ValidateSet line of Invoke-AppDeployToolkit.ps1 (and driverConfig.json
    when -Interactive). Re-run it any time you change the config.

.PARAMETER Interactive
    Prompt for the core organization fields and write them into driverConfig.json before validating.

.PARAMETER SkipPSADT
    Do not fetch PSAppDeployToolkit (offline, or you'll run tools\Get-PSADT.ps1 yourself).

.EXAMPLE
    .\setup.ps1
.EXAMPLE
    .\setup.ps1 -Interactive
#>
[CmdletBinding()]
param(
    [switch]$Interactive,
    [switch]$SkipPSADT
)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$configPath = Join-Path $root 'driverConfig.json'
function Info($m) { Write-Host "  $m" }
# BOM-less UTF-8 on both Windows PowerShell 5.1 and 7 (Set-Content -Encoding UTF8 adds a BOM on 5.1 -> spurious git diffs).
function Write-Utf8($path, $text) { [System.IO.File]::WriteAllText($path, $text, [System.Text.UTF8Encoding]::new($false)) }
function Ok($m)   { Write-Host "  [OK] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  [!] $m" -ForegroundColor Yellow }

if (-not (Test-Path -LiteralPath $configPath)) { throw "driverConfig.json not found next to setup.ps1 ($configPath)." }

# ---- 1. Optional interactive capture of the core org fields --------------------------------------------------------
if ($Interactive) {
    Write-Host "`n== Interactive setup (Enter keeps the current value) ==" -ForegroundColor Cyan
    $cfg = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    function Ask($label, $current) { $r = Read-Host "$label [$current]"; if ([string]::IsNullOrWhiteSpace($r)) { $current } else { $r.Trim() } }
    function AskInt($label, $current) { while ($true) { $r = Ask $label $current; if ("$r" -match '^\d+$') { return [int]$r }; Warn 'Enter a whole number.' } }
    # Add-Member -Force so this works even if a field was deleted from the config (PS 5.1 can't assign a missing property).
    function Set-Field($obj, $name, $value) { $obj | Add-Member -NotePropertyName $name -NotePropertyValue $value -Force }
    do { $org = Ask 'Organization (short, no spaces - drives paths/keys)' $cfg.organization
         if ($org -match '\s') { Warn 'Organization must not contain spaces (it feeds task/registry/path names).' } } while ($org -match '\s')
    Set-Field $cfg 'organization'   $org
    Set-Field $cfg 'publisher'      (Ask 'Publisher (shown as app vendor)'        $cfg.publisher)
    Set-Field $cfg 'installTitle'   (Ask 'Install title (restart-dialog header)'  $cfg.installTitle)
    Set-Field $cfg 'packageVersion' (Ask 'Package version (any string; bump to force redeploy)' $cfg.packageVersion)
    Set-Field $cfg 'taskName'       (Ask 'Scheduled task name'         $(if ($cfg.taskName)     { $cfg.taskName }     else { "$org-DriverUpdate" }))
    Set-Field $cfg 'registryRoot'   (Ask 'Registry root (64-bit HKLM)' $(if ($cfg.registryRoot) { $cfg.registryRoot } else { "HKLM:\SOFTWARE\$org\Drivers" }))
    Set-Field $cfg 'stateDir'       (Ask 'State dir'                   $(if ($cfg.stateDir)     { $cfg.stateDir }     else { "%ProgramData%\$org\DriverUpdates" }))
    if ($null -eq $cfg.schedule) { Set-Field $cfg 'schedule' ([pscustomobject]@{}) }
    Set-Field $cfg.schedule 'daysAfterPatchTuesday' (AskInt 'Schedule: days after Patch Tuesday the window opens' $cfg.schedule.daysAfterPatchTuesday)
    Set-Field $cfg.schedule 'windowDays'            (AskInt 'Schedule: window length in days'                     $cfg.schedule.windowDays)
    Set-Field $cfg.schedule 'promptDeadlineDays'    (AskInt 'Schedule: days before the ask becomes a forced countdown' $cfg.schedule.promptDeadlineDays)
    Write-Utf8 $configPath (($cfg | ConvertTo-Json -Depth 8) + "`r`n")
    Ok "Wrote driverConfig.json"
}

# ---- 2. Load + validate ------------------------------------------------------------------------------------------
Write-Host "`n== Validating driverConfig.json ==" -ForegroundColor Cyan
$cfg = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
$err = New-Object System.Collections.Generic.List[string]

foreach ($k in 'organization','publisher','installTitle','packageVersion','taskName','registryRoot','stateDir') {
    if ([string]::IsNullOrWhiteSpace("$($cfg.$k)")) { $err.Add("missing or empty: $k") }
}
if ("$($cfg.organization)" -match '\s') { $err.Add("organization must not contain spaces (it feeds task/registry/path names): got '$($cfg.organization)'") }
if ("$($cfg.registryRoot)" -and "$($cfg.registryRoot)" -notmatch '^HKLM:\\SOFTWARE\\') { $err.Add("registryRoot must be a 64-bit HKLM path like 'HKLM:\SOFTWARE\<Org>\Drivers' (got '$($cfg.registryRoot)')") }
if ("$($cfg.stateDir)" -and "$($cfg.stateDir)" -notmatch '\\')                          { $err.Add("stateDir looks wrong (got '$($cfg.stateDir)')") }
if ($null -eq $cfg.schedule) { $err.Add("missing 'schedule' block") } else {
    foreach ($k in 'daysAfterPatchTuesday','windowDays','promptDeadlineDays') { if ($null -eq $cfg.schedule.$k) { $err.Add("missing schedule.$k") } }
    if ($cfg.schedule.windowDays -and $cfg.schedule.promptDeadlineDays -ge $cfg.schedule.windowDays) { $err.Add("schedule.promptDeadlineDays ($($cfg.schedule.promptDeadlineDays)) should be < windowDays ($($cfg.schedule.windowDays)) or the forced countdown never lands in the window") }
}
if ($null -eq $cfg.restart) { $err.Add("missing 'restart' block") } else {
    foreach ($k in 'countdownHours','countdownMinutes','countdownNoHideHours','minBatteryPercent') { if ($null -eq $cfg.restart.$k) { $err.Add("missing restart.$k") } }
    if ($null -eq $cfg.restart.restartWhenNoUser) { $err.Add("missing restart.restartWhenNoUser") }
}
$profileNames = @($cfg.profiles.PSObject.Properties.Name)
if (-not $profileNames.Count) { $err.Add("no profiles defined under 'profiles'") }
foreach ($pn in $profileNames) {
    $p = $cfg.profiles.$pn
    foreach ($k in 'time','deployMode','prompt','blockOnConsoleUser','restartAfterCycle') { if ($null -eq $p.$k) { $err.Add("profile '$pn' missing '$k'") } }
    if ("$($p.time)" -and "$($p.time)" -notmatch '^\d{1,2}:\d{2}$')                 { $err.Add("profile '$pn' time must be HH:mm (got '$($p.time)')") }
    if ("$($p.deployMode)" -and "$($p.deployMode)" -notin 'Auto','Silent','Interactive','NonInteractive') { $err.Add("profile '$pn' deployMode must be Auto/Silent/Interactive/NonInteractive (got '$($p.deployMode)')") }
}
if ($err.Count) {
    Write-Host "`nConfig has $($err.Count) problem(s):" -ForegroundColor Red
    $err | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    throw "Fix driverConfig.json and re-run setup.ps1."
}
Ok "config valid: org '$($cfg.organization)', task '$($cfg.taskName)', $($profileNames.Count) profile(s): $($profileNames -join ', ')"

# ---- 3. Fetch PSADT ----------------------------------------------------------------------------------------------
Write-Host "`n== PSAppDeployToolkit ==" -ForegroundColor Cyan
$havePsadt = (Test-Path -LiteralPath (Join-Path $root 'PSAppDeployToolkit\PSAppDeployToolkit.psd1')) -and (Test-Path -LiteralPath (Join-Path $root 'Invoke-AppDeployToolkit.exe'))
if ($SkipPSADT) { Info "skipped (-SkipPSADT). Present: $havePsadt" }
elseif ($havePsadt) { Ok "already present" }
else { & (Join-Path $root 'tools\Get-PSADT.ps1'); Ok "fetched" }

# ---- 4. Generate detection scripts (one per profile), stamped from the config -------------------------------------
Write-Host "`n== Detection scripts ==" -ForegroundColor Cyan
$pkgDirDetect = ($cfg.stateDir -replace '%([^%]+)%', '$$env:$1') + '\Package'   # %ProgramData% -> $env:ProgramData (kept literal for runtime)
$detTemplate = @'
# OpenDriverUpdater - Intune detection script for the {{PROFILE}} profile.
# GENERATED by setup.ps1 from driverConfig.json - do not hand-edit; re-run setup.ps1 after any config change.
#
# Reads everything it can from the CACHED package's driverConfig.json (Install copies the whole package, config
# included, to $PackageDir), so only three values live here:
#   $PackageDir      - where Install caches the package (= stateDir\Package from driverConfig.json). The one path this
#                      script must know in order to find the config.
#   $ExpectedProfile - this app's profile (deploy one Intune app per profile, each with its matching script).
#   $ExpectedVersion - MUST stay here, NOT be read from the JSON: it is the redeploy trigger. Intune delivers this
#                      script fresh with each app version, so it carries the NEW version. The cached config on an old
#                      device only knows the OLD version - and so does the registry - so reading it from the cache would
#                      always agree with the registry and a version bump would never reinstall. setup.ps1 keeps it in
#                      step with packageVersion in driverConfig.json for you.
#
# Contract: write to stdout when installed; output nothing when not. Write-Output (not Write-Host) so the result is
# on the pipeline for in-process callers and on stdout for Intune alike.

$PackageDir      = "{{PACKAGEDIR}}"   # = stateDir\Package from driverConfig.json
$ExpectedProfile = '{{PROFILE}}'
$ExpectedVersion = '{{VERSION}}'                                        # = packageVersion in driverConfig.json

# No cached package (or an unreadable config) means NOT installed - a reinstall repairs either. A bare `return` emits
# nothing, and Intune's contract is "exit 0 + empty stdout = not installed", so silence IS the not-installed answer.
# Only the explicit Write-Output 'Installed' at the very end ever reports installed.
$cfgPath = Join-Path $PackageDir 'driverConfig.json'
if (-not (Test-Path -LiteralPath $cfgPath)) { return }
try { $cfg = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json } catch { return }

$Launcher = Join-Path $PackageDir 'Invoke-AppDeployToolkit.exe'
$Worker   = Join-Path $PackageDir 'SupportFiles\Invoke-DriverUpdate.ps1'
$task = Get-ScheduledTask -TaskName "$($cfg.taskName)" -ErrorAction SilentlyContinue
# Read the 64-bit hive explicitly: state lives under the 64-bit view, and if Intune ever runs this script as a 32-bit
# process, HKLM:\SOFTWARE\<Org> would silently redirect to WOW6432Node, report "not installed", and reinstall forever.
$hive = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
$key  = $hive.OpenSubKey(("$($cfg.registryRoot)" -replace '^HKLM:\\', ''))
$regProfile = if ($key) { $key.GetValue('Profile') }
$regVersion = if ($key) { $key.GetValue('PackageVersion') }

if ($null -ne $task -and (Test-Path -LiteralPath $Launcher) -and (Test-Path -LiteralPath $Worker) -and
    $regProfile -eq $ExpectedProfile -and $regVersion -eq $ExpectedVersion) {
    Write-Output 'Installed'
}
'@
$detDir = Join-Path $root 'Detection'
if (-not (Test-Path -LiteralPath $detDir)) { $null = New-Item -ItemType Directory -Path $detDir }
foreach ($pn in $profileNames) {
    $content = $detTemplate.Replace('{{PROFILE}}', $pn).Replace('{{VERSION}}', "$($cfg.packageVersion)").Replace('{{PACKAGEDIR}}', $pkgDirDetect)
    Write-Utf8 (Join-Path $detDir "DriverUpdate-Detection-$pn.ps1") ($content + "`r`n")
    Ok "generated Detection\DriverUpdate-Detection-$pn.ps1  (version $($cfg.packageVersion))"
}
# Flag stale detection scripts for profiles no longer in the config (left in place - remove them yourself if unused).
Get-ChildItem -LiteralPath $detDir -Filter 'DriverUpdate-Detection-*.ps1' | ForEach-Object {
    $pn = $_.BaseName -replace '^DriverUpdate-Detection-', ''
    if ($pn -notin $profileNames) { Warn "stale detection script for a profile not in the config: $($_.Name)" }
}

# ---- 5. Sync the launcher's -CustomParam ValidateSet to the configured profiles ----------------------------------
Write-Host "`n== Launcher -CustomParam ValidateSet ==" -ForegroundColor Cyan
$launcherPath = Join-Path $root 'Invoke-AppDeployToolkit.ps1'
$vs = '[ValidateSet(' + (($profileNames | ForEach-Object { "'$_'" }) -join ', ') + ')]'
$lc = Get-Content -LiteralPath $launcherPath -Raw
# The CustomParam ValidateSet is the one immediately preceding [System.String]$CustomParam.
$pattern = "\[ValidateSet\([^)]*\)\](\s*\r?\n\s*\[System\.String\]\`$CustomParam)"
if ($lc -match $pattern) {
    # $vs has no '$', so it needs no replacement-escaping; '$1' (single-quoted) is the captured newline + CustomParam line.
    $new = $lc -replace $pattern, ($vs + '$1')
    if ($new -ne $lc) { Write-Utf8 $launcherPath $new; Ok "set $vs" } else { Ok "already $vs" }
} else { Warn "could not find the -CustomParam ValidateSet to sync; ensure it lists: $($profileNames -join ', ')" }

# ---- 6. Summary --------------------------------------------------------------------------------------------------
Write-Host "`n== Ready ==" -ForegroundColor Cyan
Info "Organization : $($cfg.organization)"
Info "Task         : $($cfg.taskName)   (registry $($cfg.registryRoot))"
Info "State dir    : $($cfg.stateDir)"
Info "Version      : $($cfg.packageVersion)"
Info "Cadence      : opens Patch Tuesday +$($cfg.schedule.daysAfterPatchTuesday), $($cfg.schedule.windowDays)-day window, forced countdown at +$($cfg.schedule.promptDeadlineDays)"
Write-Host "  Fine-tune cadence, restart countdown, and per-profile times in driverConfig.json, then re-run setup.ps1." -ForegroundColor DarkGray
Write-Host "`nInstall (elevated), one Intune app / command per profile:" -ForegroundColor Cyan
foreach ($pn in $profileNames) { Write-Host "  Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent -CustomParam $pn" }
Write-Host "`nWrap each as a Win32 app with its Detection\DriverUpdate-Detection-<Profile>.ps1 as the detection script (run as 64-bit)." -ForegroundColor Cyan
