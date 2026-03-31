# JustSomeScripts

A collection of scripts and tools I use in my day-to-day as an IT admin. These are sanitized versions of production scripts — feel free to use, modify, and share.

## Repository Structure

| Folder | Description |
|--------|-------------|
| [bin/](bin/) | Standalone executables and utilities used by other scripts |
| [Intune/](Intune/) | Scripts for Microsoft Intune device management |
| [WinPE/](WinPE/) | Scripts for Windows Preinstallation Environment |

## Scripts

### Intune

| Script | Description |
|--------|-------------|
| [IntuneDriveMapping.ps1](Intune/IntuneDriveMapping.ps1) | Maps network drives via Intune using a scheduled task. Based on [intune-drive-mapping-generator](https://intunedrivemapping.azurewebsites.net) by [Nicola Suter](https://tech.nicolonsky.ch). |

### bin

| File | Description |
|------|-------------|
| [Invoke-AppDeployToolkit.exe](bin/Invoke-AppDeployToolkit.exe) | PSInvoker — runs PowerShell scripts hidden in 64-bit. Originally from [PSAppDeployToolkit](https://psappdeploytoolkit.com/), redistributed under GPL. |

## Usage

Most scripts include comments explaining configuration. 

For the Intune driver mapping, look for JSON blocks or variables near the top of each script and update them to match your environment.

Example — update the drive mapping JSON in `IntuneDriveMapping.ps1`:

```json
{
    "Path": "\\\\yourserver\\yourshare\\$env:username",
    "DriveLetter": "H",
    "Label": "Home Drive",
    "Id": 1,
    "GroupFilter": "Your AD Group Name"
}
```

## License

Scripts in this repo are provided as-is with no warranty. Use at your own risk.

Third-party tools in `bin/` retain their original licenses (GPL where applicable).

## Credits

- [Nicola Suter / nicolonsky tech](https://tech.nicolonsky.ch) — original Intune Drive Mapping script
- [PSAppDeployToolkit](https://psappdeploytoolkit.com/) — PSInvoker executable