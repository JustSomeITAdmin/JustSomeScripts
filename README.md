# JustSomeScripts

A collection of scripts and tools I use in my day-to-day as an IT admin. These are sanitized versions of production scripts — feel free to use, modify, and share. As always, test, test, test....and then test one more time.

## Repository Structure

| Folder | Description |
|--------|-------------|
| [bin/](bin/) | Standalone executables and utilities used by other scripts |
| [IntuneScripts/](IntuneScripts/) | Scripts for Microsoft Intune device management |

## Quick Links

- [Drive Mapping](IntuneScripts/DriveMapping/) — Map network drives via Intune scheduled task
- [Bitlocker to Go](IntuneScripts/Bitlocker/) — Escrow Bitlocker To Go keys to Entra ID
- [Dell Command Update](IntuneScripts/Dell%20Command%20Update/) — Configure and trigger DCU on install via scheduled task
- [Patch-WinRE](IntuneScripts/Patch-WinRE/) — Inject matched boot-critical drivers into the WinRE WIM via Intune

## bin

| File | Description |
|------|-------------|
| [Invoke-AppDeployToolkit.exe](bin/Invoke-AppDeployToolkit.exe) | PSInvoker — runs PowerShell scripts hidden in 64-bit. Originally from [PSAppDeployToolkit](https://psappdeploytoolkit.com/), redistributed under GPL. |

## License

Scripts in this repo are provided as-is with no warranty. Use at your own risk.

Third-party tools in `bin/` retain their original licenses (GPL where applicable).

## Credits

- [Nicola Suter / nicolonsky tech](https://tech.nicolonsky.ch) — original Intune Drive Mapping script
- [MHimken](https://github.com/MHimken/WinRE-Customization) — WinRE patching script used by Patch-WinRE
- [PSAppDeployToolkit](https://psappdeploytoolkit.com/) — PSInvoker executable
