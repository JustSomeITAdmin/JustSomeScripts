#Requires -RunAsAdministrator

# Set your BIOS password here. Leave as empty string to skip the -BiosPassword flag entirely.
$BiosPassword = ""

if ((Get-CimInstance -ClassName CIM_BIOSElement).Manufacturer -notmatch 'Dell|Alienware') { exit 0 }
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

function Write-Log {
    param([string]$Message)
    "[$(Get-Date -Format s)] $Message" | Out-File -FilePath $log -Append -Encoding utf8
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

    Write-Log "Configure returned retryable code 2, retrying in 30 seconds"
    Start-Sleep -Seconds 30
}

if (-not $configured) {
    Write-Log "Configure never succeeded after $maxAttempts attempts"
    exit 2
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

    Write-Log "Lock settings returned retryable code 2, retrying in 30 seconds"
    Start-Sleep -Seconds 30
}

if (-not $locked) {
    Write-Log "Lock settings never succeeded after $maxAttempts attempts"
    exit 2
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

    & $dcuPath @applyArgs
    $applyExit = $LASTEXITCODE
    Write-Log "ApplyUpdates exit code: $applyExit"

    if ($applyExit -eq 0) {
        Write-Log "ApplyUpdates succeeded"
        exit 0
    }
    if ($applyExit -match '1|5') {
        Write-Log "ApplyUpdates succeeded, but a reboot is needed"
        exit 0
    }

    if ($applyExit -eq 500) {
        Write-Log "No updates found; treating as success"
        exit 0
    }

    Write-Log "ApplyUpdates returned retryable code 2, retrying in 30 seconds"
    Start-Sleep -Seconds 30
}

Write-Log "ApplyUpdates never succeeded after $maxAttempts attempts"
exit 2
'@

($scriptContent -replace '##CONFIGURE_ARGS##', $configureArgs) | Set-Content 'C:\Windows\Tasks\InvokeDCU.ps1'

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