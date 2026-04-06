# Patch-WinRE

Injects boot-critical drivers into the WinRE (Windows Recovery Environment) WIM via Microsoft Intune. The driver injection logic is based on [MHimken's WinRE customization script](https://github.com/MHimken/WinRE-Customization).

## How It Works

1. **Driver matching** — `Install.ps1` queries the driver store for all non-inbox, boot-critical drivers and compares them to currently running drivers. A SHA256 hash comparison is used to confirm the driver store copy matches the loaded driver, avoiding false positives.
2. **Driver export** — Matched drivers are exported to a temp folder via `pnputil.exe`.
3. **WIM injection** — `Patch-WinRE.ps1` is called to mount the WinRE WIM, inject the exported drivers, resize the recovery partition if needed, and commit the changes.
4. **Detection stamp** — On a successful run (exit code 0 from `Patch-WinRE.ps1`), a registry value is written to mark the device as patched.

## Files

| File | Role | Notes |
|------|------|-------|
| `Install.ps1` | Main script | Run as the Intune app install command |
| `Patch-WinRE.ps1` | WinRE patching engine | Called by `Install.ps1`; credit to MHimken |
| `Requirement.ps1` | Intune requirement script | Exits 0 if matching drivers found, 1 otherwise |

## Intune Deployment

### App Type
Win32 app (`.intunewin` wrapping the three files).

### Install 
Currently the `64-bit` option in the `PowerShell script` feature currently isn't working. We need to rely on the **sysnative** folder to call the script.

~~Use the `PowerShell script` installer type with the file `Install.ps1`.~~

Upload the .intunewin file, and then use the the following Install command:
`%SystemRoot%\sysnative\WindowsPowerShell\v1.0\powershell.exe -file Install.ps1`


### Requirement Rule
Use `Requirement.ps1` as a custom PowerShell requirement script. Use the below table on setting up the rule. This ensures the app only targets devices where a matching boot-critical driver is present, preventing unnecessary runs and avoiding errors on devices that don't need the patch. Set all PowerShell options (i.e. run in logged in user, enforce signature chat, run in 32-bit) to `No`.

| Setting | Value |
|---------|-------|
| Output Data Type | String |
| Operator | Equals |
| Value | `Matched drivers found` |

### Detection Rule
| Setting | Value |
|---------|-------|
| Type | Registry |
| Key path | `HKLM:\SOFTWARE\WinRE` |
| Value name | `WinRE-All-Inject` |
| Detection method | String comparison |
| Value | `Installed` |

## Notes

- The script runs as **SYSTEM** and requires elevation; ensure the Intune app is configured to run in system context.
- Logs are written to `%TEMP%\Winre.log` and `%TEMP%\WinRE-Stuff\Logs\`.
- The recovery partition is automatically resized to at least 2 GB if needed (controlled by `-RecoveryDriveSizeInGB 2GB` in `Install.ps1`).
- Matched drivers are exported to `%TEMP%\DrvTemp\` and left in place after the run.
