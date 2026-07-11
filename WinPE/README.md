# WinPE / OS Deployment Scripts

Scripts for injecting drivers during OS deployment via ConfigMgr task sequences. These run in WinPE before the first reboot, ensuring the OS comes up with working storage and network drivers.

Browse the subfolders above for each script — every one has its own README. The root [README](../README.md) has a one-line description of each.

## General Notes

- These scripts run during WinPE inside a ConfigMgr task sequence
- The OSDCloud method is best when a vendor driver pack exists for your model; can use high bandwidth; should replace cached driver repositories
- The export method is a fallback for custom builds or brand-new hardware; should be paired with Windows Update drivers updated, or OEM driver tools