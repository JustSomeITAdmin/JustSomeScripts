# JustSomeScripts

A collection of scripts and tools I use in my day-to-day as an IT admin. These are sanitized versions of production scripts — feel free to use, modify, and share. As always, test, test, test....and then test one more time.

## Repository Structure

| Folder | Description |
|--------|-------------|
| [bin/](bin/) | Standalone executables and utilities used by other scripts |
| [IntuneScripts/](IntuneScripts/) | Scripts for Microsoft Intune device management |
| [WinPE/](WinPE/) | Scripts for driver injection during OS deployment (WinPE / ConfigMgr) |
| [IntuneAnalyzer/](IntuneAnalyzer/) | Local-first root-cause analysis for Intune "Collect diagnostics" ZIPs — parse, correlate, rank findings with evidence (Python + PowerShell + SQLite, optional local LLM) |

## Quick Links

### Intune
- [Power Settings](IntuneScripts/Power%20Settings/) - Seed sensible power defaults (chassis + Modern Standby aware) and disable fast startup; cross-vendor, values stay user-changeable
- [Drive Mapping](IntuneScripts/DriveMapping/) - Map network drives via Intune scheduled task
- [Bitlocker to Go](IntuneScripts/Bitlocker/) - Escrow Bitlocker To Go keys to Entra ID
- [Dell Command Update](IntuneScripts/Dell%20Command%20Update/) - Configure and trigger DCU on install via scheduled task
- [Dell BIOS Update](IntuneScripts/Dell%20BIOS%20Update/) - Query Dell's current SDP catalog for the latest BIOS, stage the flash without rebooting (Remediation)
- [Lenovo BIOS Update](IntuneScripts/Lenovo%20BIOS%20Update/) - Stage the latest BIOS via Lenovo's official LCU module, no reboot (Remediation; ThinkPad/ThinkStation)
- [HP BIOS Update](IntuneScripts/HP%20BIOS%20Update/) - Stage the latest BIOS via HP CMSL (Get-HPBIOSUpdates), adaptive auth, no reboot (Remediation)
- [Patch-WinRE](IntuneScripts/Patch-WinRE/) - Inject matched boot-critical drivers into the WinRE WIM via Intune
- [Upgrade Windows Home To Pro](IntuneScripts/Upgrade%20Windows%20Home%20To%20Pro/) - Upgrade systems with Windows Home to Pro using a MAK key
- [BIOS Password Retrieval](IntuneScripts/BIOS%20Password%20Retrieval/) - Retrieve the Intune-escrowed BIOS password for a device via Graph API
- [Xerox Printer Install](IntuneScripts/Xerox%20Printer%20Install/) - Self-service Xerox AltaLink printer install: SNMP model detection, runtime V4 driver download, and Standard Accounting (PSADT v4.2) [only for AltraLink Cxxx models]

### Intune Analyzer
- [IntuneAnalyzer](IntuneAnalyzer/) - Drop in a `DiagLogs-*.zip`, get ranked evidence-cited findings: Win32 app failures, ESP wedges, BitLocker recovery triggers (Secure Boot CA / boot-manager swap / firmware), LocalUsersAndGroups replace bugs, unattended BIOS flashes, WHfB tombstones, WU/restart collisions. Web UI + CLI; drop-in Python rules; runs entirely on your machine (`install.ps1`)

### WinPE / OS Deployment
- [OSDCloud Driver Injection](WinPE/Driver%20Injection%20using%20OSD%20Cloud/) - Download and inject vendor driver packs during WinPE using a modified OSDCloud function
- [Export Drivers from WinPE](WinPE/Export%20Drivers%20from%20WinPE/) - Export running WinPE drivers and inject them into the OS for hardware without a driver pack

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
- [OSDeploy / David Segura](https://github.com/OSDeploy/OSD) — OSD PowerShell module and OSDCloud