# Export Drivers from WinPE

Exports running WinPE drivers and injects them into the offline OS image using DISM. This is a fallback for situations where a vendor driver pack isn't available or doesn't work — brand-new hardware, custom builds, or cases where your Windows image is behind your WinPE boot image and the inbox drivers cause BSODs or missing storage/network.

The logic is simple: if your hardware can boot into WinPE with working storage and network drivers, those same drivers can be injected into the OS before the first reboot.

## When to Use This

- A vendor driver pack doesn't exist yet for your model (new hardware)
- The OSDCloud/driver pack method fails or causes issues
- Your OS image's inbox drivers don't support the hardware (BSOD, no NIC, no storage)
- Custom or niche hardware builds

This is **not a replacement for full driver management**. It gets you through deployment so the machine can boot and reach the network. You'll still want a proper driver installation mechanism (Windows Update, DCU, etc.) to pick up the rest.

## How It Works

1. Enumerates all imported drivers in WinPE (`Get-WindowsDriver -Online`) and all currently running drivers (`Win32_SystemDriver`)
2. Matches running drivers to their driver store packages using SHA256 hash comparison — this avoids false positives when multiple versions of the same driver are imported
3. Exports the matched driver folders from the driver store to `X:\ExportedDrivers`
4. Injects all exported drivers into the offline OS image using `dism.exe /Add-Driver /Recurse`

## Task Sequence Placement

Run this as a "Run PowerShell Script" step **after the OS image is applied** but **before the first reboot**. It works alongside or as an alternative to the OSDCloud method. You could run both if you set up the proper conditions.

The script automatically detects whether it's running inside a ConfigMgr task sequence. If it is, it reads `OSDTargetSystemDrive` for the OS partition and logs to the task sequence log path. If not, it falls back to `C:\` and logs locally.

## Files

| File | Description |
|------|-------------|
| `Export-WinPEDrivers.ps1` | Main script — export and inject running WinPE drivers into the OS |

## Logs

- **In a task sequence:** `%_SMSTSLogPath%\WinPE-Export-Drivers.log` (CMTrace-compatible format)
- **Standalone:** `X:\WinPELogs\WinPE-Export-Drivers.log`

The log includes every matched driver, skipped candidates, hash comparison results, and DISM output.