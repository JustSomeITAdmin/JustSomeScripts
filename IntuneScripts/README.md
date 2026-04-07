# Intune Scripts

PowerShell scripts designed for deployment via Microsoft Intune. Each subfolder contains related scripts and documentation.

## Categories

| Folder | Description |
|--------|-------------|
| [Bitlocker/](Bitlocker/) | Escrow Bitlocker To Go recovery keys to Entra ID |
| [Dell Command Update/](Dell%20Command%20Update/) | Configure and trigger Dell Command Update on install |
| [DriveMapping/](DriveMapping/) | Map network drives based on AD group membership |
| [Patch-WinRE/](Patch-WinRE/) | Inject boot-critical drivers into the WinRE WIM |
| [Upgrade Windows Home To Pro/](Upgrade%20Windows%20Home%20To%20Pro/) | Upgrade systems with Windows Home to Pro using a MAK key

## General Notes

- Most scripts run as SYSTEM initially and create scheduled tasks for user-context execution
- Logs are typically written to `C:\ProgramData\Intune_Scripts\`
- Scripts download dependencies (like PSInvoker) with hash verification for security
