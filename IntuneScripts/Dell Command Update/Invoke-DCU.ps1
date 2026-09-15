#Requires -RunAsAdministrator

# Set your BIOS password here. Leave as empty string to skip the -BiosPassword flag entirely.
$BiosPassword = ""

if ((Get-CimInstance -ClassName CIM_BIOSElement).Manufacturer -notmatch 'Dell|Alienware') { exit 0 }

$debugLog = 'C:\ProgramData\Dell\InvokeDCU-debug.log'

# Stale task from a pre-cleanup run: remove it, and leave the same marker the inner script leaves.
$t = Get-ScheduledTask -TaskName 'Run on Dell Command Update Install' -ErrorAction SilentlyContinue
if ($t -and (Get-ScheduledTaskInfo -InputObject $t).LastTaskResult -eq 0) {
    if (Test-Path 'C:\Windows\Tasks\InvokeDCU.ps1') { Remove-Item 'C:\Windows\Tasks\InvokeDCU.ps1' -Force -ErrorAction SilentlyContinue }
    Unregister-ScheduledTask -TaskName 'Run on Dell Command Update Install' -Confirm:$false
    "[$(Get-Date -Format s)] Cleaning up: removing C:\Windows\Tasks\InvokeDCU.ps1 and scheduled task 'Run on Dell Command Update Install' (stale, removed by platform script)" |
        Out-File -FilePath $debugLog -Append -Encoding utf8
    exit 0
}

# Intune re-runs this script fleet-wide on every edit. Either cleanup path leaves this line behind; don't re-arm.
if ((Test-Path $debugLog) -and (Select-String -Path $debugLog -Pattern 'Cleaning up: removing' -Quiet)) { exit 0 }

$taskName = "Run on Dell Command Update Install"
$taskDescription = "Triggers when MsiInstaller logs Event ID 1033 for Dell Command | Update for Windows Universal."

# Event subscription XML for the trigger
$subscription = @"
<QueryList>
  <Query Id="0" Path="Application">
    <Select Path="Application">
      *[
        System[
          Provider[@Name='MsiInstaller']
          and
          EventID=1033
        ]
        and
        EventData[
          Data='Dell Command | Update for Windows Universal'
        ]
      ]
    </Select>
  </Query>
</QueryList>
"@

$configureArgs = '/configure -autoSuspendBitLocker=enable -scheduleManual -updatesNotification=disable -advancedDriverRestore=enable'
if ($BiosPassword) { $configureArgs += " -BiosPassword=$BiosPassword" }
$configureArgs += ' -silent'

$scriptContent = @'
$log = 'C:\ProgramData\Dell\InvokeDCU-debug.log'
$dcuPath = "C:\Program Files\Dell\CommandUpdate\dcu-cli.exe"
$taskName = '##TASK_NAME##'
$self = $PSCommandPath

function Write-Log {
    param([string]$Message)
    "[$(Get-Date -Format s)] $Message" | Out-File -FilePath $log -Append -Encoding utf8
}

# DCU skips the BIOS flash while BitLocker conversion is running, which it always is during ESP.
# -autoSuspendBitLocker only suspends protection, not the conversion - manage-bde -pause does that.
$script:paused = $false
function Suspend-Conversion {
    $status = (Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction SilentlyContinue).VolumeStatus
    if ($status -like '*InProgress') {
        Write-Log "BitLocker status is $status; pausing conversion so the BIOS update isn't skipped"
        & "$env:SystemRoot\System32\manage-bde.exe" -pause $env:SystemDrive 2>&1 | Out-Null
        $script:paused = $true
    }
}

# Must run on every exit path - a paused conversion left behind never finishes encrypting.
function Resume-Conversion {
    if (-not $script:paused) { return }
    $script:paused = $false
    & "$env:SystemRoot\System32\manage-bde.exe" -resume $env:SystemDrive 2>&1 | Out-Null
    Write-Log "Resumed BitLocker conversion; status is now $((Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction SilentlyContinue).VolumeStatus)"
}

# One-shot: drop the script and the task so a later DCU upgrade doesn't re-fire event 1033.
# Script first - deleting the task can take the running instance with it.
function Exit-Clean {
    param([int]$Code)
    Resume-Conversion
    Write-Log "Cleaning up: removing $self and scheduled task '$taskName'"
    Remove-Item -LiteralPath $self -Force -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    exit $Code
}

while (-not (Test-Path -LiteralPath $dcuPath)) {
    Start-Sleep -Seconds 2
}

Write-Log "Initial stabilization wait starting"
Start-Sleep -Seconds 30

$maxAttempts = 20

# Phase 1: initial configure
$configured = $false
for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    Write-Log "Configure attempt $attempt starting"

    & $dcuPath ##CONFIGURE_ARGS##
    $configureExit = $LASTEXITCODE
    Write-Log "First configure exit code: $configureExit"

    if ($configureExit -eq 0) {
        $configured = $true
        break
    }

    Write-Log "Configure returned $configureExit, retrying in 30 seconds"
    Start-Sleep -Seconds 30
}

if (-not $configured) {
    Write-Log "Configure never succeeded after $maxAttempts attempts"
    Exit-Clean 2
}

Start-Sleep -Seconds 2

# Phase 2: lock settings
$locked = $false
for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    Write-Log "Lock settings attempt $attempt starting"

    & $dcuPath /configure -silent -lockSettings=enable
    $lockExit = $LASTEXITCODE
    Write-Log "Lock settings exit code: $lockExit"

    if ($lockExit -eq 0) {
        $locked = $true
        break
    }

    Write-Log "Lock settings returned $lockExit, retrying in 30 seconds"
    Start-Sleep -Seconds 30
}

if (-not $locked) {
    Write-Log "Lock settings never succeeded after $maxAttempts attempts"
    Exit-Clean 2
}

Start-Sleep -Seconds 2

# Phase 3: apply updates
$applyArgs = @(
    '/applyUpdates'
    '-silent'
    '-updateType=bios,firmware,driver'
    '-outputLog=C:\ProgramData\Dell\DellCommandUpdate.log'
    '-autoSuspendBitLocker=enable'
    '-reboot=disable'
    '-forceUpdate=enable'
)

for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    Write-Log "Apply attempt $attempt starting"

    Suspend-Conversion

    $applyOutput = & $dcuPath @applyArgs 2>&1
    $applyExit = $LASTEXITCODE
    Write-Log "ApplyUpdates exit code: $applyExit"

    # Exit code is 0/1 even when the BIOS was silently dropped, so the warning is the only signal.
    if ($applyOutput -match 'BitLocker operation') {
        Write-Log "BIOS update was skipped for BitLocker; retrying in 30 seconds"
        Start-Sleep -Seconds 30
        continue
    }

    if ($applyExit -eq 0) {
        Write-Log "ApplyUpdates succeeded"
        Exit-Clean 0
    }
    if ($applyExit -in 1, 5) {
        Write-Log "ApplyUpdates succeeded, but a reboot is needed"
        Exit-Clean 0
    }

    if ($applyExit -eq 500) {
        Write-Log "No updates found; treating as success"
        Exit-Clean 0
    }

    Write-Log "ApplyUpdates returned $applyExit, retrying in 30 seconds"
    Start-Sleep -Seconds 30
}

Write-Log "ApplyUpdates never succeeded after $maxAttempts attempts"
Exit-Clean 2
'@

($scriptContent -replace '##CONFIGURE_ARGS##', $configureArgs -replace '##TASK_NAME##', $taskName) |
    Set-Content 'C:\Windows\Tasks\InvokeDCU.ps1'

# Action to run when the event is detected
# Replace this with your real command/script
$action = New-ScheduledTaskAction -Execute "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\Windows\Tasks\InvokeDCU.ps1'

# Event-based trigger
$class = Get-CimClass MSFT_TaskEventTrigger root/Microsoft/Windows/TaskScheduler
$Trigger_onEvent = $class | New-CimInstance -ClientOnly
$trigger_onEvent.Enabled = $true
$trigger_onEvent.Subscription = $subscription

#$trigger = New-ScheduledTaskTrigger -Once -At (get-date)

# Optional principal: run as SYSTEM
$principal = New-ScheduledTaskPrincipal "NT AUTHORITY\SYSTEM"
# Optional settings
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

# Register the task
Register-ScheduledTask -TaskName $taskName -Description $taskDescription -Action $action -Trigger $trigger_onEvent -Principal $principal -Settings $settings -Force | Out-Null