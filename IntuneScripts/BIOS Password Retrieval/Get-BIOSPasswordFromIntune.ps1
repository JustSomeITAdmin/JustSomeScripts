#Requires -Version 7.0

[CmdletBinding(DefaultParameterSetName = 'HostName')]
param
(
    [Parameter(ParameterSetName = 'HostName')]
    [String]$ComputerName = $env:COMPUTERNAME,
    [Parameter(ParameterSetName = 'ID')]
    [String]$ID,
    [Parameter(ParameterSetName = 'Serial')]
    [String]$SerialNumber
)

# Using  -Scope CurrentUser so Install-Module works without elevation
# Checking to see if modules are installed
Write-Verbose "Checking to see modules are installed..."
$GraphModulesNeeded = @(
    "Microsoft.Graph.Authentication",
    "Microsoft.Graph.DeviceManagement"
)
foreach ($ModuleToCheck in $GraphModulesNeeded) {
    $IsModuleLoaded = Get-Module -ListAvailable -Name $ModuleToCheck
    if ($null -eq $IsModuleLoaded) {
        Write-Verbose "Installing $ModuleToCheck"
        Install-Module $ModuleToCheck -Repository PSGallery -Force -Scope CurrentUser
    }
    Remove-Variable IsModuleLoaded
}

#  Verify the required scope is present in an existing session; reconnect if not - per https://learn.microsoft.com/en-us/mem/intune/protect/hardware-password-management
$RequiredScope = "DeviceManagementManagedDevices.PrivilegedOperations.All"
Write-Verbose "Checking to see session is established..."
$MgContext = Get-MgContext
if ($null -eq $MgContext) {
    Write-Verbose "Session not established. Prompting for credentials"
    Connect-MgGraph -NoWelcome -Scopes $RequiredScope
}
elseif ($RequiredScope -notin $MgContext.Scopes) {
    Write-Warning "Current session is missing the required scope [$RequiredScope]. Reconnecting..."
    Connect-MgGraph -NoWelcome -Scopes $RequiredScope
}

Write-Verbose "Getting device information using the $(($PSCmdlet.ParameterSetName).ToLower())..."
# DefaultParameterSetName guarantees one of the three named cases always matches
switch ($PSCmdlet.ParameterSetName) {
    "HostName" {
        $ComputerName = $ComputerName.ToUpper()
        $DeviceMgmtObj = Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '$ComputerName'"
        $SearchTerm = $ComputerName
    }
    "Serial" {
        $DeviceMgmtObj = Get-MgDeviceManagementManagedDevice -Filter "SerialNumber eq '$SerialNumber'"
        $SearchTerm = $SerialNumber
    }
    "ID" {
        $DeviceMgmtObj = Get-MgDeviceManagementManagedDevice -ManagedDeviceId $ID
        $SearchTerm = $ID
    }
}

if ($DeviceMgmtObj) {
    if ($DeviceMgmtObj.count -ge 2) {
        $DeviceMgmtObj = ($DeviceMgmtObj | Sort-Object LastSyncDateTime -Descending)[0]
    }
    $DeviceMgmtID = $DeviceMgmtObj.Id
    Write-Verbose "Found $($DeviceMgmtObj.DeviceName) [$DeviceMgmtID]"
    try {
        $HardwarePWDetails = Invoke-MgGraphRequest -Method Get "https://graph.microsoft.com/beta/deviceManagement/hardwarePasswordDetails/$DeviceMgmtID"
        if ($HardwarePWDetails) {
            $CurrentPassword = $HardwarePWDetails['currentPassword']
            # previousPasswords is a string array with no timestamps, so sort order is not guaranteed by the API.
            # Index [0] is assumed to be the most recent entry, but this may vary.
            $PreviousPasswords = $HardwarePWDetails['previousPasswords'][0]
            if ($CurrentPassword) {
                Write-Verbose "Displaying the current password."
                Write-Output $CurrentPassword
            }
            elseif ($PreviousPasswords) {
                Write-Verbose "No current password set. Using the most recent previous password."
                Write-Output $PreviousPasswords
            }
            else { Write-Warning "No passwords found for [$SearchTerm]" }
        }
        else {
            Write-Warning "No hardware password information found for [$SearchTerm]"
        }
    }
    catch {
        # Use Write-Error and include the exception so callers always get feedback without needing -Verbose
        Write-Error "Unable to get hardware password details for [$SearchTerm]: $_"
    }
}
else {
    # Use Write-Warning so device-not-found is always visible, not hidden behind -Verbose
    Write-Warning "[$SearchTerm] was not found in Intune. Please verify the value and try again."
}
