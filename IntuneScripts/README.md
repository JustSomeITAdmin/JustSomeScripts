# Intune Scripts

PowerShell scripts designed for deployment via Microsoft Intune. Each subfolder contains related scripts and documentation.

## Categories

| Folder | Description |
|--------|-------------|
| [Bitlocker/](Bitlocker/) | Escrow Bitlocker To Go recovery keys to Entra ID |
| [Dell Command Update/](Dell%20Command%20Update/) | Configure and trigger Dell Command Update on install |
| [DriveMapping/](DriveMapping/) | Map network drives based on AD group membership |

## General Notes

- Most scripts run as SYSTEM initially and create scheduled tasks for user-context execution
- Logs are typically written to `C:\ProgramData\Intune_Scripts\`
- Scripts download dependencies (like PSInvoker) with hash verification for security
