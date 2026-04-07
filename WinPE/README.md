# WinPE / OS Deployment Scripts

Scripts for injecting drivers during OS deployment via ConfigMgr task sequences. These run in WinPE before the first reboot, ensuring the OS comes up with working storage and network drivers.

## Categories

| Folder | Description |
|--------|-------------|
| [OSDCloud/](OSDCloud/) | Download and inject vendor driver packs using a modified OSDCloud function |
| [Export Drivers from WinPE/](Export%20Drivers%20from%20WinPE/) | Export running WinPE drivers and inject them into the OS; useful for new hardware without a driver pack |

## General Notes

- These scripts run during WinPE inside a ConfigMgr task sequence
- The OSDCloud method is best when a vendor driver pack exists for your model; can use high bandwidth; should replace cached driver repositories
- The export method is a fallback for custom builds or brand-new hardware; should be paired with Windows Update drivers updated, or OEM driver tools