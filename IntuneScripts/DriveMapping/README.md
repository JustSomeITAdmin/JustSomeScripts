# Intune Drive Mapping

Maps network drives via Intune using a scheduled task. Based on [intune-drive-mapping-generator](https://intunedrivemapping.azurewebsites.net) by [Nicola Suter](https://tech.nicolonsky.ch).

## How It Works

1. When deployed via Intune, the script runs as SYSTEM
2. It saves a copy of itself to `C:\ProgramData\Intune_Scripts\DriveMapping.ps1`
3. Downloads PSInvoker64.exe (with hash verification) to run PowerShell hidden
4. Creates a scheduled task that runs at user logon
5. On each logon, maps drives based on the user's AD group membership

## Configuration

Edit the `$driveMappingJson` variable near the top of `IntuneDriveMapping.ps1`:

```json
[
    {
        "Path": "\\\\server\\share\\$env:username",
        "DriveLetter": "H",
        "Label": "Home Drive",
        "Id": 1,
        "GroupFilter": "Faculty Share Access"
    },
    {
        "Path": "\\\\server\\research",
        "DriveLetter": "R",
        "Label": "Research",
        "Id": 2,
        "GroupFilter": "Research Share Access"
    }
]
```

| Property | Description |
|----------|-------------|
| `Path` | UNC path to the share. Supports `$env:username` for user-specific paths |
| `DriveLetter` | Drive letter to map (without colon) |
| `Label` | Friendly name shown in Explorer |
| `Id` | Unique identifier for the mapping |
| `GroupFilter` | AD security group name. Only users in this group get the drive. Leave empty for all users |

## Optional Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `$searchRoot` | `""` | Override AD domain if `$env:USERDNSDOMAIN` isn't available |
| `$removeStaleDrives` | `$false` | Remove mapped drives not in the config |

## Deployment

1. Upload `IntuneDriveMapping.ps1` to Intune as a proactive remediation script and leave it in as a "Detection" script. If you don't have the license to use a
proactive remation script, then you can use a Platform Script instead. Just know, it only runs once, and retries only 3 times if it fails. 
2. Set "Run this script using the logged on credentials" to **No** (runs as SYSTEM)
3. Assign to your target group

## Logs

- Task creation: `%TEMP%\IntuneDriveMapping.log` (SYSTEM context)
- Drive mapping: `%TEMP%\DriveMapping.log` (user context)

## Credits

Original author: [Nicola Suter](https://tech.nicolonsky.ch)
