# BIOS Password Retrieval — Graph API

Retrieves the BIOS password for an Intune-managed device via the Microsoft Graph API. Accepts a computer name (default: current machine), serial number, or Intune device ID. If no current password is stored, it falls back to the most recent entry in the previous passwords array.

## Requirements

- PowerShell 7.0+
- Graph modules (auto-installed if missing):
  - `Microsoft.Graph.Authentication`
  - `Microsoft.Graph.DeviceManagement`
- The authenticated account or app registration must have the **`DeviceManagementManagedDevices.PrivilegedOperations.All`** permission

## Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `-ComputerName` | Look up by device hostname | Current machine (`$env:COMPUTERNAME`) |
| `-SerialNumber` | Look up by hardware serial number | — |
| `-ID` | Look up by Intune managed device ID | — |

The three parameters are mutually exclusive — use only one per run. If no parameter is specified, the script defaults to the local machine's hostname.

## Usage

```powershell
# Current machine (no parameters needed)
.\Get-BIOSPasswordFromIntune.ps1

# By computer name
.\Get-BIOSPasswordFromIntune.ps1 -ComputerName DESKTOP-ABC123

# By serial number
.\Get-BIOSPasswordFromIntune.ps1 -SerialNumber 1A2B3C4D

# By Intune device ID
.\Get-BIOSPasswordFromIntune.ps1 -ID "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

# With verbose output
.\Get-BIOSPasswordFromIntune.ps1 -ComputerName DESKTOP-ABC123 -Verbose
```

## How It Works

1. Checks that the required Graph modules are installed; installs any that are missing
2. Checks for an existing `Connect-MgGraph` session; prompts for credentials if none exists
3. Queries `Get-MgDeviceManagementManagedDevice` using the supplied identifier
4. If multiple records are returned (e.g. duplicate hostnames), selects the most recently synced device
5. Calls `GET /beta/deviceManagement/hardwarePasswordDetails/{id}` to retrieve password details
6. Returns the **current password** if one exists; otherwise returns the **most recent previous password**
7. Uses `-Verbose` throughout — pass `-Verbose` to see step-by-step details including which device was matched and which password source was used

## Notes

- The script targets the **beta** Graph endpoint (`/beta/deviceManagement/hardwarePasswordDetails`), as hardware password details are not yet available in the v1.0 endpoint
- BIOS passwords are only escrowed to Intune if the device is enrolled and the OEM supports the [Windows hardware password management](https://learn.microsoft.com/en-us/mem/intune/protect/hardware-password-management) feature
- If no password is found at all, the script exits silently (no output); add `-Verbose` to see the reason
