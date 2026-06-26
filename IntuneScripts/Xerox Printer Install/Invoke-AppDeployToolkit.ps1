using namespace System.Net
using namespace System.Security.Cryptography.X509Certificates
[CmdletBinding()]
param
(
    [Parameter(Mandatory = $false)]
    [ValidateSet('Install', 'Uninstall', 'Repair')]
    [System.String]$DeploymentType = [System.Management.Automation.Language.NullString]::Value,

    [Parameter(Mandatory = $false)]
    [ValidateSet('Interactive', 'Silent', 'NonInteractive')]
    [System.String]$DeployMode = [System.Management.Automation.Language.NullString]::Value,

    [Parameter(Mandatory = $false)]
    [String]$CustomParam,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.SwitchParameter]$SuppressRebootPassThru,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.SwitchParameter]$TerminalServerMode,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.SwitchParameter]$DisableLogging
)


##================================================
## MARK: Variables
##================================================

# Zero-Config MSI support is provided when "AppName" is null or empty.
# By setting the "AppName" property, Zero-Config MSI will be disabled.
$adtSession = @{
    # App variables.
    AppVendor                   = 'Xerox'
    AppName                     = 'Printer Install'
    AppVersion                  = '2.0'
    AppArch                     = 'x64'
    AppLang                     = 'EN'
    AppRevision                 = '01'
    AppSuccessExitCodes         = @(0)
    AppRebootExitCodes          = @(1641, 3010)
    AppProcessesToClose         = @()
    AppScriptVersion            = '2.0.0'
    AppScriptDate               = '2026-06-13'
    AppScriptAuthor             = 'JustSomeITGuy'
    RequireAdmin                = $true

    # Install Titles (Only set here to override defaults set by the toolkit).
    InstallName                 = ''
    InstallTitle                = ''

    # Script variables.
    DeployAppScriptFriendlyName = $MyInvocation.MyCommand.Name
    DeployAppScriptParameters   = $PSBoundParameters
    DeployAppScriptVersion      = '4.1.7'
    ForceWimDetection           = $true
}


##================================================
## MARK: Xerox configuration (the ONLY part you normally edit)
##================================================
# Buildings you offer in the picker -> "<hostname>;<ip>[;<fallback model>]".
#   * <hostname>  : DNS name used for the print PORT (PrinterHostAddress) and SNMP discovery.
#   * <ip>        : written into the accounting XML <host-address>. Also used as a SNMP fallback target.
#   * <fallback model> (optional, e.g. C8270): used ONLY if live SNMP discovery fails, so an offline
#                   printer still installs. Leave it off and SNMP figures the model out by itself.
# The Xerox helper functions (SNMP discovery, driver resolution, XeroxQueueProperties builder) live in
# PSAppDeployToolkit.Extensions\PSAppDeployToolkit.Extensions.psm1.
$XeroxHostNameHashTable = @{
    # 'Display name shown in the picker' = '<hostname>;<ip>[;<fallback model>]'
    'Library'      = 'xerox-library.printers.example.com;192.0.2.10'
    'Lab 1'        = 'xerox-lab1.printers.example.com;192.0.2.11;C8170'
    'Front Office' = 'xerox-frontoffice.printers.example.com;192.0.2.12'
    'Lobby'        = 'xerox-lobby.printers.example.com;192.0.2.13'
}
# Display names that should NOT prompt for a 4-digit accounting code (e.g. a guest/lobby printer with no
# per-user quota). Their queue still gets the device settings, just with accounting turned off.
$XeroxNoCodeBuildings = @('Lobby')

# Subtitle shown on every dialog -- set this to your org / team name.
$DialogSubtitle = 'IT Department'


function Install-ADTDeployment {
    [CmdletBinding()]
    param
    (
    )

    ##================================================
    ## MARK: Pre-Install
    ##================================================
    $adtSession.InstallPhase = "Pre-$($adtSession.DeploymentType)"

    # 1) Ask which building's printer to install.
    $PickXeroxPrinter = Show-ADTInstallationPrompt -Message 'Choose your Xerox printer you wish to install' -ListItems ([string[]]($XeroxHostNameHashTable.Keys | Sort-Object)) -DefaultIndex 0 -ButtonRightText 'OK' -Title 'Xerox Printer Installer' -Subtitle $DialogSubtitle -PersistPrompt
    $Building = $PickXeroxPrinter.SelectedItem
    $QueueName = "$Building Xerox Printer"

    # 2) Ask for the 4-digit accounting code (unless this building is exempt).
    $InputXeroxCode = $null
    if ($XeroxNoCodeBuildings -notcontains $Building) {
        do {
            $InputXeroxCode = Show-ADTInstallationPrompt -Message "Please enter your four digit code for the $Building Xerox Printer" -ButtonRightText 'OK' -Title 'Xerox Printer Installer' -RequestInput -DefaultValue '####' -Subtitle $DialogSubtitle -PersistPrompt
        } until ($InputXeroxCode.Text -match '^\d{4}$')
    }
    else {
        Write-ADTLogEntry "Building [$Building] is exempt from the four-digit accounting code prompt."
    }

    # 3) Resolve hostname / IP / optional fallback model from the config table.
    $parts = $XeroxHostNameHashTable[$Building] -split ';'
    $XeroxHostName = $parts[0].Trim()
    $XeroxIPAddress = $parts[1].Trim()
    $FallbackModel = if ($parts.Count -ge 3) { $parts[2].Trim() } else { $null }
    $PortName = "X_$($XeroxHostName -replace '\.', '_')"
    $XeroxTempPath = Join-Path $envTemp 'PSAppDeployKit\XeroxStuff'
    New-ADTFolder -Path $XeroxTempPath

    Show-ADTInstallationProgress -StatusMessage "Detecting the $Building Xerox printer..." -WindowLocation BottomRight -Subtitle $DialogSubtitle -StatusMessageDetail 'Please be patient. This may take a while.' -Title 'Xerox Printer Install'

    # 4) Discover the model over SNMP (hostname first, then IP). Fall back to the table hint if offline.
    $detected = Get-XeroxPrinterModel -Targets @($XeroxHostName, $XeroxIPAddress)
    if ($detected) {
        $Model = $detected.Model
        $SeriesDigit = $detected.SeriesDigit
        Write-ADTLogEntry "SNMP discovered model [$Model] (C8${SeriesDigit}00 series) on [$XeroxHostName]. Raw: $($detected.Raw)"
    }
    elseif ($FallbackModel -match 'C8(\d)\d{2}') {
        $Model = $Matches[0]; $SeriesDigit = [int]$Matches[1]
        Write-ADTLogEntry "SNMP discovery failed; using table fallback model [$Model] (C8${SeriesDigit}00 series)." -Severity 2
    }
    else {
        Write-ADTLogEntry "Could not determine the printer model for [$Building] via SNMP and no fallback model is set." -Severity 3
        Close-ADTInstallationProgress
        Show-ADTInstallationPrompt -Message "Could not reach the $Building Xerox printer to detect its model. Please verify you are on the network and the printer is reachable, then try again." -ButtonRightText 'OK' -NoWait -Subtitle $DialogSubtitle -Title 'Xerox Printer Install'
        Close-ADTSession -ExitCode 77781
    }

    ##================================================
    ## MARK: Install
    ##================================================
    $adtSession.InstallPhase = $adtSession.DeploymentType

    # 5) Ensure the matching V4 PS driver is present. If a driver for this model is already installed
    #    (e.g. another building of the same series), reuse it and skip the download entirely.
    $driverName = (Get-PrinterDriver -ErrorAction SilentlyContinue | Where-Object { $_.Name -match [regex]::Escape($Model) -and $_.Name -match 'V4 PS' } | Select-Object -First 1).Name
    if ($driverName) {
        Write-ADTLogEntry "Driver already installed: [$driverName]. Skipping download."
    }
    else {
        Show-ADTInstallationProgress -StatusMessage "Downloading the driver for the $Building Xerox Printer..." -WindowLocation BottomRight -Subtitle $DialogSubtitle -StatusMessageDetail 'Please be patient. This may take a while.' -Title 'Xerox Printer Install'
        $driverUrl = Resolve-XeroxDriverUrl -SeriesDigit $SeriesDigit
        if (-not $driverUrl) {
            Write-ADTLogEntry "Could not resolve a V4 PS driver download URL for the C8${SeriesDigit}00 series." -Severity 3
            Close-ADTSession -ExitCode 77782
        }
        Write-ADTLogEntry "Resolved driver URL: $driverUrl"
        $driverZip = Join-Path $XeroxTempPath "AltaLinkC8${SeriesDigit}xx_PS.zip"
        Invoke-WebRequest -Uri $driverUrl -OutFile $driverZip -UseBasicParsing
        if (-not (Test-Path $driverZip)) {
            Write-ADTLogEntry 'Driver download failed.' -Severity 3
            Close-ADTSession -ExitCode 77783
        }
        $driverExtract = Join-Path $XeroxTempPath "driver_c8${SeriesDigit}xx"
        Expand-Archive -Path $driverZip -DestinationPath $driverExtract -Force
        $inf = Get-ChildItem -Path $driverExtract -Recurse -Filter "*c8${SeriesDigit}xx*.inf" | Select-Object -First 1
        if (-not $inf) {
            Write-ADTLogEntry 'No matching .inf found in the driver package.' -Severity 3
            Close-ADTSession -ExitCode 77784
        }
        $driverName = Get-XeroxDriverNameFromInf -InfPath $inf.FullName -Model $Model
        Write-ADTLogEntry "Staging driver [$driverName] from [$($inf.Name)]"
        Start-ADTProcess -FilePath "$env:SystemRoot\System32\pnputil.exe" -ArgumentList "/add-driver `"$($inf.FullName)`" /install" -CreateNoWindow
        if (-not (Get-PrinterDriver -Name $driverName -ErrorAction SilentlyContinue)) {
            Add-PrinterDriver -Name $driverName
        }
    }

    # 6) Create the TCP/IP port and the print queue (idempotent).
    Show-ADTInstallationProgress -StatusMessage "Creating the $Building Xerox print queue..." -WindowLocation BottomRight -Subtitle $DialogSubtitle -StatusMessageDetail 'Please be patient. This may take a while.' -Title 'Xerox Printer Install'
    if (-not (Get-PrinterPort -Name $PortName -ErrorAction SilentlyContinue)) {
        Add-PrinterPort -Name $PortName -PrinterHostAddress $XeroxHostName
        Write-ADTLogEntry "Created port [$PortName] -> [$XeroxHostName]"
    }
    if (Get-Printer -Name $QueueName -ErrorAction SilentlyContinue) {
        Set-Printer -Name $QueueName -DriverName $driverName -PortName $PortName
        Write-ADTLogEntry "Updated existing queue [$QueueName]"
    }
    else {
        Add-Printer -Name $QueueName -DriverName $driverName -PortName $PortName
        Write-ADTLogEntry "Created queue [$QueueName] with driver [$driverName] on port [$PortName]"
    }

    # 7) Install the Xerox Desktop Print Experience (the V4 companion). REQUIRED before we write the
    #    queue settings: the app must be present for the queue's Xerox options/accounting to be honored.
    #    The driver registers a PrinterExtensionUrl in PrinterDriverData once the queue exists; that URL
    #    is the matching MSI (found originally via a Wireshark capture, later confirmed in the registry).
    #    Shared by every Xerox V4 queue, so install it only once.
    $xpeExe = Join-Path $envProgramFiles 'Xerox\XeroxPrintExperience\XeroxPrintExperience\XeroxPrinterConfiguration.Exe'
    if (-not (Test-Path $xpeExe)) {
        Show-ADTInstallationProgress -StatusMessage 'Installing Xerox print components...' -WindowLocation BottomRight -Subtitle $DialogSubtitle -StatusMessageDetail 'Please be patient. This may take a while.' -Title 'Xerox Printer Install'
        $extUrl = $null
        for ($i = 0; $i -lt 15 -and -not $extUrl; $i++) {
            $extUrl = (Get-ADTRegistryKey -Path "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Print\Printers\$QueueName\PrinterDriverData" -Name 'PrinterExtensionUrl')
            if (-not $extUrl) { Start-Sleep -Seconds 2 }
        }
        if ($extUrl) {
            Write-ADTLogEntry "Downloading Xerox Desktop Print Experience from [$extUrl]"
            $xpeMsi = Join-Path $XeroxTempPath 'XeroxDesktopPrintExperience.msi'
            Start-BitsTransfer -Source $extUrl -Destination $xpeMsi
            if (Test-Path $xpeMsi) { Start-ADTMsiProcess -FilePath $xpeMsi -Action Install }
            else { Write-ADTLogEntry 'Desktop Print Experience download failed.' -Severity 3 }
        }
        else {
            Write-ADTLogEntry 'PrinterExtensionUrl not present; cannot install Desktop Print Experience, so Xerox queue options / accounting will be unavailable.' -Severity 3
        }
    }

    # 8) Write the complete queue configuration. The Desktop Print Experience does NOT reliably create
    #    XeroxQueueProperties for the 2nd+ queue, so we never poll/wait for it -- we write the full
    #    known-good value ourselves (device settings + accounting), every time. A no-code building (see
    #    $XeroxNoCodeBuildings) has no code, so it gets the device settings with accounting turned off.
    Show-ADTInstallationProgress -StatusMessage "Configuring the $Building Xerox Printer..." -WindowLocation BottomRight -Subtitle $DialogSubtitle -StatusMessageDetail 'Please be patient. This may take a while.' -Title 'Xerox Printer Install'
    $regKey = "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Print\Printers\$QueueName\QueueProperties"
    $existingQP = Get-ADTRegistryKey -Path $regKey -Name 'XeroxQueueProperties'
    $codeToWrite = if ($InputXeroxCode -and $InputXeroxCode.Text -match '^\d{4}$') { $InputXeroxCode.Text } else { $null }
    $full = New-XeroxQueuePropertiesValue -Existing $existingQP -HostName $XeroxHostName -IpAddress $XeroxIPAddress -Code $codeToWrite -PortName $PortName -SeriesDigit $SeriesDigit
    Write-ADTLogEntry "Writing XeroxQueueProperties ($($full.Length) chars) for [$QueueName] (accounting: $(if ($codeToWrite) { 'on' } else { 'off' }))"
    Set-ADTRegistryKey -Key $regKey -Name 'XeroxQueueProperties' -Type String -Value $full

    # 9) Apply the QueueProperties into the queue's live DevMode. Writing the registry value alone is
    #    NOT enough: the QPB -> DevMode apply normally only runs during the Desktop Print Experience MSI
    #    install, so only the FIRST printer on a machine gets it (subsequent printers showed accounting
    #    disabled despite a correct registry). XeroxPrinterConfigurationWriter.exe performs that apply,
    #    so every printer (1st or Nth) ends up with accounting actually enabled and the tabs locked down.
    $xpeWriter = Join-Path (Split-Path $xpeExe -Parent) 'XeroxPrinterConfigurationWriter.Exe'
    if (Test-Path $xpeWriter) {
        Write-ADTLogEntry 'Applying queue configuration to the live DevMode via XeroxPrinterConfigurationWriter.exe'
        Start-ADTProcess -FilePath $xpeWriter -CreateNoWindow -IgnoreExitCodes '*'
    }
    else {
        Write-ADTLogEntry 'XeroxPrinterConfigurationWriter.exe not found; queue settings may not apply to the live queue.' -Severity 2
    }

    Close-ADTInstallationProgress
    Show-ADTInstallationPrompt -Message "You're all set! The $Building Xerox Printer is now ready for use!" -ButtonRightText 'OK' -NoWait -Subtitle $DialogSubtitle -Title 'Xerox Printer Install'

    ##================================================
    ## MARK: Post-Install
    ##================================================
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"

    # Detection marker consumed (and cleared) by Xerox-Detection.ps1 so the app stays re-runnable from
    # Company Portal. Deploy as Available (NOT Required) -- the self-clearing marker would otherwise
    # cause Required deployments to reinstall every detection cycle.
    Set-ADTRegistryKey -Key 'HKLM:\SOFTWARE\IntunePrinters' -Name 'XeroxPrinter' -Value 'Installed' -Type String
}

function Uninstall-ADTDeployment {
    [CmdletBinding()]
    param
    (
    )

    ##================================================
    ## MARK: Pre-Uninstall
    ##================================================
    $adtSession.InstallPhase = "Pre-$($adtSession.DeploymentType)"

    ## If there are processes to close, show Welcome Message with a 60 second countdown before automatically closing.
    if ($adtSession.AppProcessesToClose.Count -gt 0) {
        Show-ADTInstallationWelcome -CloseProcesses $adtSession.AppProcessesToClose -CloseProcessesCountdown 60
    }

    ## Show Progress Message (with the default message).
    Show-ADTInstallationProgress

    ## <Perform Pre-Uninstallation tasks here>


    ##================================================
    ## MARK: Uninstall
    ##================================================
    $adtSession.InstallPhase = $adtSession.DeploymentType

    ## Handle Zero-Config MSI uninstallations.
    if ($adtSession.UseDefaultMsi) {
        $ExecuteDefaultMSISplat = @{ Action = $adtSession.DeploymentType; FilePath = $adtSession.DefaultMsiFile }
        if ($adtSession.DefaultMstFile) {
            $ExecuteDefaultMSISplat.Add('Transform', $adtSession.DefaultMstFile)
        }
        Start-ADTMsiProcess @ExecuteDefaultMSISplat
    }

    ## <Perform Uninstallation tasks here>


    ##================================================
    ## MARK: Post-Uninstallation
    ##================================================
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"

    ## <Perform Post-Uninstallation tasks here>
}

function Repair-ADTDeployment {
    [CmdletBinding()]
    param
    (
    )

    ##================================================
    ## MARK: Pre-Repair
    ##================================================
    $adtSession.InstallPhase = "Pre-$($adtSession.DeploymentType)"

    ## If there are processes to close, show Welcome Message with a 60 second countdown before automatically closing.
    if ($adtSession.AppProcessesToClose.Count -gt 0) {
        Show-ADTInstallationWelcome -CloseProcesses $adtSession.AppProcessesToClose -CloseProcessesCountdown 60
    }

    ## Show Progress Message (with the default message).
    Show-ADTInstallationProgress

    ## <Perform Pre-Repair tasks here>


    ##================================================
    ## MARK: Repair
    ##================================================
    $adtSession.InstallPhase = $adtSession.DeploymentType

    ## Handle Zero-Config MSI repairs.
    if ($adtSession.UseDefaultMsi) {
        $ExecuteDefaultMSISplat = @{ Action = $adtSession.DeploymentType; FilePath = $adtSession.DefaultMsiFile }
        if ($adtSession.DefaultMstFile) {
            $ExecuteDefaultMSISplat.Add('Transform', $adtSession.DefaultMstFile)
        }
        Start-ADTMsiProcess @ExecuteDefaultMSISplat
    }

    ## <Perform Repair tasks here>


    ##================================================
    ## MARK: Post-Repair
    ##================================================
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"

    ## <Perform Post-Repair tasks here>
}


##================================================
## MARK: Initialization
##================================================

# Set strict error handling across entire operation.
$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
$ProgressPreference = [System.Management.Automation.ActionPreference]::SilentlyContinue
Set-StrictMode -Version 1

# Import the module and instantiate a new session.
try {
    # Import the module locally if available, otherwise try to find it from PSModulePath.
    if (Test-Path -LiteralPath "$PSScriptRoot\PSAppDeployToolkit\PSAppDeployToolkit.psd1" -PathType Leaf) {
        Get-ChildItem -LiteralPath $PSScriptRoot\PSAppDeployToolkit -Recurse -File | Unblock-File -ErrorAction Ignore
        Import-Module -FullyQualifiedName @{ ModuleName = "$PSScriptRoot\PSAppDeployToolkit\PSAppDeployToolkit.psd1"; Guid = '8c3c366b-8606-4576-9f2d-4051144f7ca2'; ModuleVersion = '4.1.0' } -Force
    }
    else {
        Import-Module -FullyQualifiedName @{ ModuleName = 'PSAppDeployToolkit'; Guid = '8c3c366b-8606-4576-9f2d-4051144f7ca2'; ModuleVersion = '4.1.0' } -Force
    }

    # Open a new deployment session, replacing $adtSession with a DeploymentSession.
    $iadtParams = Get-ADTBoundParametersAndDefaultValues -Invocation $MyInvocation
    $adtSession = Remove-ADTHashtableNullOrEmptyValues -Hashtable $adtSession
    $adtSession = Open-ADTSession @adtSession @iadtParams -PassThru
}
catch {
    $Host.UI.WriteErrorLine((Out-String -InputObject $_ -Width ([System.Int32]::MaxValue)))
    exit 60008
}


##================================================
## MARK: Invocation
##================================================

# Commence the actual deployment operation.
try {
    # Import any found extensions before proceeding with the deployment.
    Get-ChildItem -LiteralPath $PSScriptRoot -Directory | & {
        process {
            if ($_.Name -match 'PSAppDeployToolkit\..+$') {
                Get-ChildItem -LiteralPath $_.FullName -Recurse -File | Unblock-File -ErrorAction Ignore
                Import-Module -Name $_.FullName -Force
            }
        }
    }

    # Invoke the deployment and close out the session.
    & "$($adtSession.DeploymentType)-ADTDeployment"
    Close-ADTSession
}
catch {
    # An unhandled error has been caught.
    $mainErrorMessage = "An unhandled error within [$($MyInvocation.MyCommand.Name)] has occurred.`n$(Resolve-ADTErrorRecord -ErrorRecord $_)"
    Write-ADTLogEntry -Message $mainErrorMessage -Severity 3

    ## Error details hidden from the user by default. Show a simple dialog with full stack trace:
    # Show-ADTDialogBox -Text $mainErrorMessage -Icon Stop -NoWait

    ## Or, a themed dialog with basic error message:
    # Show-ADTInstallationPrompt -Message "$($adtSession.DeploymentType) failed at line $($_.InvocationInfo.ScriptLineNumber), char $($_.InvocationInfo.OffsetInLine):`n$($_.InvocationInfo.Line.Trim())`n`nMessage:`n$($_.Exception.Message)" -MessageAlignment Left -ButtonRightText OK -Icon Error -NoWait

    Close-ADTSession -ExitCode 60001
}
