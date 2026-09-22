# Self-contained tests for PSAppDeployToolkit.Extensions. Stubs the PSADT cmdlets the module calls, points state at a
# throwaway HKCU key, and (for the restart-phase checks) injects a controlled window so they pass on any date. No frameworks.
$ErrorActionPreference = 'Stop'

function global:Write-ADTLogEntry { param($Message, $Severity, $ScriptSection) }
$global:StubSessions = @(); $global:StubActive = $null; $global:StubBusy = $false
$global:StubBattery = @{ IsLaptop = $false; IsUsingACPower = $true; BatteryLifePercent = 1.0 }
$global:PromptCalls = @()
function global:Get-ADTLoggedOnUser { $global:StubSessions }
function global:Get-ADTEnvironmentTable { @{ RunAsActiveUser = $global:StubActive } }
function global:Test-ADTBattery { param([switch]$PassThru) [pscustomobject]$global:StubBattery }
function global:Test-ADTUserIsBusy { $global:StubBusy }
function global:Show-ADTInstallationRestartPrompt { param($Countdown, $CountdownNoHide, [switch]$SilentRestart, $SilentCountdown, [switch]$NoCountdown, [switch]$AllowCancel, [switch]$PersistPrompt, $Subtitle, $ShutdownReasonText, [switch]$CustomMessage, $CustomMessageText) $global:PromptCalls += , $PSBoundParameters }

Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'PSAppDeployToolkit.Extensions\PSAppDeployToolkit.Extensions.psm1') -Force
$m = Get-Module PSAppDeployToolkit.Extensions

# Point state at a test hive, and add a synthetic 'Lab' profile (silent, never self-restarts, blocks on console) to
# exercise the config-flexible branches - proving those behaviors are reachable purely from driverConfig.json.
& $m.NewBoundScriptBlock({
    $script:ODU.RegRoot = 'HKCU:\SOFTWARE\ODUTest\Drivers'
    $script:ODU.Profiles['Lab'] = @{ Time = '00:30'; DeployMode = 'Silent'; Prompt = $false; BlockOnConsoleUser = $true; RestartAfterCycle = $false }
})

Remove-Item 'HKCU:\SOFTWARE\ODUTest' -Recurse -Force -ErrorAction SilentlyContinue
$fails = 0
function A([string]$name, [bool]$cond) { if ($cond) { "PASS $name" } else { $script:fails++; "FAIL $name" } }
function Only([string]$key) { $global:PromptCalls.Count -eq 1 -and $global:PromptCalls[0].ContainsKey($key) }
function None() { $global:PromptCalls.Count -eq 0 }

"--- profile resolution ---"
A 'default Production'   ((Resolve-ODUProfile) -eq 'Production')
A 'param wins'           ((Resolve-ODUProfile -CustomParam Pilot) -eq 'Pilot')
Set-ODUState @{ Profile = 'Pilot' }
A 'registry fallback'    ((Resolve-ODUProfile) -eq 'Pilot')
A 'bogus -> Production'  ((Resolve-ODUProfile -CustomParam Bogus) -eq 'Production')

"--- window math: Production opens PT+n, Pilot leads it (real function, fixed month Sep 2026, PT = Sep 8) ---"
$sep = Get-Date -Year 2026 -Month 9 -Day 1
$wProd = Get-ODUWindow $sep -Profile Production
$wPilot = Get-ODUWindow $sep -Profile Pilot
A 'Production window is 7 days long, closes-exclusive' ((($wProd.Close - $wProd.Open).Days) -eq 7)
A 'Pilot opens on Patch Tuesday (Sep 8)'               ($wPilot.Open.Day -eq 8)
A 'Production opens PT+3 (Sep 11), leads by config'     ($wProd.Open.Day -eq 11 -and (($wProd.Open - $wPilot.Open).Days) -eq 3)
A 'next window is next month'                           ($wProd.NextOpen.Month -eq 10)

"--- skip reasons ---"
A 'AC desktop, Production -> run'        ($null -eq (Get-ODUSkipReason -Profile Production))
$global:StubBattery = @{ IsLaptop = $true; IsUsingACPower = $false; BatteryLifePercent = 0.3 }
A 'battery 30% -> skip'                  ((Get-ODUSkipReason -Profile Production) -match 'battery')
$global:StubBattery = @{ IsLaptop = $true; IsUsingACPower = $false; BatteryLifePercent = 0.8 }
A 'battery 80% -> run'                   ($null -eq (Get-ODUSkipReason -Profile Production))
$global:StubSessions = @([pscustomobject]@{ NTAccount = 'X\u'; ConnectState = 'Active'; IsConsoleSession = $true })
A 'Production ignores console user'      ($null -eq (Get-ODUSkipReason -Profile Production))
A 'Lab blocks on active console'         ((Get-ODUSkipReason -Profile Lab) -match 'console')
$global:StubSessions = @()

"--- pending restart marker ---"
A 'no marker -> null' ($null -eq (Get-ODUPendingRestart))
$boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
$now  = (Get-Date).ToUniversalTime().ToString('o')
Set-ODUState @{ RebootPendingSince = $now; BootTimeAtFlag = $boot; PromptCount = 0; Vendor = 'TestCo' }
$p = Get-ODUPendingRestart
A 'marker read' ($p -and $p.PromptCount -eq 0)

"--- Lab profile: never restarts itself (restartAfterCycle = false) ---"
$global:PromptCalls = @(); $global:StubSessions = @([pscustomobject]@{ NTAccount = 'x'; ConnectState = 'Active'; IsConsoleSession = $true }); Invoke-ODURestart -Pending $p -Profile Lab
A 'Lab + console user -> no restart call' (None)

# From here, override the window so gentle/enforcing is set by us, not by today's date.
& $m.NewBoundScriptBlock({ function script:Get-ODUWindow { param([datetime]$Month = (Get-Date), [string]$Profile = 'Production') $script:TestWindow } })
function Set-Window([int]$openOffsetDays) {
    $o = (Get-Date).Date.AddDays($openOffsetDays)
    & $m.NewBoundScriptBlock([scriptblock]::Create("`$script:TestWindow = @{ Open = [datetime]'$($o.ToString('o'))'; Close = [datetime]'$($o.AddDays(7).ToString('o'))'; NextOpen = [datetime]'$($o.AddMonths(1).ToString('o'))' }"))
}

"--- Production, GENTLE phase (window opened today -> deadline ahead) ---"
Set-Window 0
$global:StubActive = $null
$global:PromptCalls = @(); $global:StubSessions = @(); Invoke-ODURestart -Pending $p -Profile Production
A 'nobody logged on -> silent restart' ((Only 'SilentRestart') -and -not $global:PromptCalls[0].ContainsKey('AllowCancel'))
$global:StubActive = 'x'; $global:StubSessions = @([pscustomobject]@{ NTAccount = 'x'; ConnectState = 'Active'; IsConsoleSession = $true })
$global:PromptCalls = @(); $global:StubBusy = $true; Invoke-ODURestart -Pending $p -Profile Production
A 'active user BUSY, gentle -> deferred' (None -and (Get-ODUState).PromptDeferredReason -match 'busy')
$global:PromptCalls = @(); $global:StubBusy = $false; Invoke-ODURestart -Pending $p -Profile Production
A 'active user free, gentle -> NoCountdown + Cancel' ((Only 'NoCountdown') -and $global:PromptCalls[0].AllowCancel -and -not $global:PromptCalls[0].ContainsKey('Countdown'))

"--- Production, ENFORCING phase (window opened 6 days ago -> past deadline) ---"
Set-Window -6
$global:StubActive = 'x'; $global:StubSessions = @([pscustomobject]@{ NTAccount = 'x'; ConnectState = 'Active'; IsConsoleSession = $true })
$global:PromptCalls = @(); $global:StubBusy = $true; Invoke-ODURestart -Pending $p -Profile Production
A 'active user BUSY, deadline -> FORCED anyway' ((Only 'Countdown') -and -not $global:PromptCalls[0].ContainsKey('AllowCancel') -and $global:PromptCalls[0].PersistPrompt)

"--- reboot clears the marker ---"
Set-ODUState @{ BootTimeAtFlag = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.AddMinutes(-5).ToUniversalTime().ToString('o') }
A 'rebooted since -> marker cleared' ($null -eq (Get-ODUPendingRestart) -and $null -eq (Get-ODUState).RebootPendingSince)

Remove-Item 'HKCU:\SOFTWARE\ODUTest' -Recurse -Force -ErrorAction SilentlyContinue
""; if ($fails) { "RESULT: $fails FAIL" } else { 'RESULT: ALL PASS' }
