# Intune Scripts

PowerShell scripts designed for deployment via Microsoft Intune. Each subfolder contains related scripts and documentation.

## Categories

| Folder | Description |
|--------|-------------|
| [Bitlocker/](Bitlocker/) | Escrow Bitlocker To Go recovery keys to Entra ID |
| [Dell Command Update/](Dell%20Command%20Update/) | Configure and trigger Dell Command Update on install |
| [DriveMapping/](DriveMapping/) | Map network drives based on AD group membership |
| [Patch-WinRE/](Patch-WinRE/) | Inject boot-critical drivers into the WinRE WIM |
| [Upgrade Windows Home To Pro/](Upgrade%20Windows%20Home%20To%20Pro/) | Upgrade systems with Windows Home to Pro using a MAK key |
| [BIOS Password Retrieval/](BIOS%20Password%20Retrieval/) | Retrieve the Intune-escrowed BIOS password for a device via Graph API |
| [Xerox Printer Install](IntuneScripts/Xerox%20Printer%20Install/) | Self-service Xerox AltaLink printer install: SNMP model detection, runtime V4 driver download, and Standard Accounting (PSADT v4.2) [only for AltraLink Cxxx models] |

## General Notes

- Most scripts run as SYSTEM initially and create scheduled tasks for user-context execution
- Logs are typically written to `C:\ProgramData\Intune_Scripts\`
- Scripts download dependencies (like PSInvoker) with hash verification for security
