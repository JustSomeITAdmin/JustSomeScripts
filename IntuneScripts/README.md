# Intune Scripts

PowerShell scripts designed for deployment via Microsoft Intune. Each subfolder contains related scripts and documentation.

Browse the subfolders above for each script — every one has its own README. The root [README](../README.md) has a one-line description of each.

## General Notes

- Most scripts run as SYSTEM initially and create scheduled tasks for user-context execution
- Logs are typically written to `C:\ProgramData\Intune_Scripts\`
- Scripts download dependencies (like PSInvoker) with hash verification for security
