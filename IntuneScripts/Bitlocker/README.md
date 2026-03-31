# Bitlocker To Go — Escrow to Entra ID

Automatically backs up Bitlocker To Go (USB drive) recovery keys to Entra ID when a user encrypts a removable drive.

## Files

| File | Description |
|------|-------------|
| `BitlockerAAD-Install.ps1` | Installation script — downloads PSInvoker64, copies files, registers scheduled task |
| `BL2GoToAAD.ps1` | Main script — scans USB drives and escrows keys to Entra ID |
| `BL2GOEscrowtoAAD.xml` | Scheduled task definition (triggered on Bitlocker events) |
| `Detection.ps1` | Intune detection script to verify successful deployment |

## How It Works

1. Installation script creates `C:\ProgramData\Intune_Scripts\` directory
2. Downloads PSInvoker64.exe from GitHub (with SHA256 hash verification)
3. Copies `BL2GoToAAD.ps1` to the scripts directory
4. Registers a scheduled task from the XML definition
5. When Windows detects a new Bitlocker To Go encryption event (Event ID 768), the task triggers
6. PSInvoker64.exe runs the script hidden in 64-bit mode — no visible PowerShell window

## Why PSInvoker64?

Using `PSInvoker64.exe` instead of `powershell.exe` provides:

- **Hidden execution** — No visible console window for the user
- **64-bit guaranteed** — Always runs in 64-bit PowerShell, avoiding WoW64 issues
- **Better error handling** — From PSAppDeployToolkit

## Deployment

### As an Intune Win32 App

1. Package the folder contents into an `.intunewin` file
2. Install command: `powershell.exe -ExecutionPolicy Bypass -File BitlockerAAD-Install.ps1`
3. Detection: Use `Detection.ps1` as a custom detection script

### Detection Script

The detection script verifies:
- The scheduled task `BL2GOEscrowtoAAD` exists
- The task runs as SYSTEM
- The task state is "Ready"
- The script file exists at the expected path

## Logs

- `C:\ProgramData\Intune_Scripts\Bitlocker2Go.log`

## Requirements

- Windows 10/11 with Bitlocker capability
- Device must be Entra ID joined (for key escrow)
- Runs as SYSTEM
- Internet access during install (to download PSInvoker64.exe)
