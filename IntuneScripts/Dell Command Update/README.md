# Dell Command Update — Intune Platform Script

Configures and runs Dell Command Update (Universal) automatically when it is installed on a device. Deployed as an Intune **Platform Script** (runs as SYSTEM, one-time). Very useful to stage the task during ESP, and once ESP is over, and DCU is instlaled, the task is triggered after ESP.

NOTE: This will only work for Dell Command Update Univerisal. If you install the classic version, it will not detect it. 

## How It Works

1. Script checks that the device is a Dell/Alienware — exits cleanly on non-Dell hardware
2. Builds a self-contained PowerShell script (`InvokeDCU.ps1`) and writes it to `C:\Windows\Tasks\`. I pick this folder because it is highly protected, unless you have administrator access. Even though, becuase it is owned by the SYSTEM account, it read access is restricted.
3. Registers a scheduled task that fires when Windows logs **Event ID 1033** from `MsiInstaller` for `Dell Command | Update for Windows Universal`
4. When DCU is installed and the event fires, the task runs `InvokeDCU.ps1` as SYSTEM, which:
   - Waits for `dcu-cli.exe` to be present, then waits an additional 30 seconds to let the install settle
   - **Phase 1 — Configure:** Sets auto BitLocker suspend, manual schedule, disables update notifications, enables advanced driver restore. Optionally sets a BIOS password. Retries up to 20 times if DCU is still busy.
   - **Phase 2 — Lock Settings:** Locks the DCU configuration so end users cannot change it. Retries up to 20 times.
   - **Phase 3 — Apply Updates:** Runs `applyUpdates` for BIOS, firmware, and drivers with reboot disabled. Retries up to 20 times.

## Configuration

At the top of `Invoke-DCU.ps1`, set the BIOS password if your environment requires one:

```powershell
# Set your BIOS password here. Leave as empty string to skip the -BiosPassword flag entirely.
$BiosPassword = ""
```

Leave it as `""` and the `-BiosPassword` flag is omitted from the DCU configure call entirely.

## Deployment

1. Set `$BiosPassword` if needed, then upload `Invoke-DCU.ps1` to Intune as a **Platform Script**
2. Set **Run this script using the logged on credentials** to **No** (must run as SYSTEM)
3. Set **Run script in 64-bit PowerShell Host** to **Yes**
4. Assign to your Dell device group

> **Note:** Platform scripts run once and retry up to 3 times on failure. The scheduled task it creates persists on the device and will trigger on any future DCU reinstall.

## Logs

- `C:\ProgramData\Dell\InvokeDCU-debug.log` — phase-by-phase log with timestamps and exit codes
- `C:\ProgramData\Dell\DellCommandUpdate.log` — DCU's own update log from `applyUpdates`

## To-do list
- Remove file from C:\Windows\Tasks after task is completed. This is tricky because I want to make sure I am not deleting it too early.
