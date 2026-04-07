# Upgrade Windows Home To Pro — Intune Win32 App

Upgrades a Windows Home OEM device to Windows Pro by installing a MAK key via CIM. Intended for devices where Windows Pro (or Enterprise) is installed but the embedded OEM license is a Home key — common when a device ships with Home but your org needs Pro.

## Files

| File | Description |
|------|-------------|
| `Requirement.ps1` | Intune requirement script — validates the device is eligible before install runs |
| `Install-ProKey.ps1` | Install script — applies the MAK key and writes a registry marker |
| `Detection.ps1` | Intune detection script — verifies the key is installed and active |

## How It Works

1. Intune runs `Requirement.ps1` before attempting the install
2. Requirement checks exit with **0** only if all conditions are met (see below)
3. If eligible, Intune runs `Install-ProKey.ps1` as SYSTEM
4. The script installs the MAK key via `SoftwareLicensingService`, triggers a license refresh, and writes a registry marker under `HKLM:\SOFTWARE\Intune_Scripts`
5. `Detection.ps1` queries the registry marker and confirms the partial product key is recognized by the Software Licensing service

## Requirement Checks

| Exit Code | Meaning |
|-----------|---------|
| `0` | Device is eligible — OEM key is Home, not activated, not domain-joined |
| `2` | Device is already activated — no action needed |
| `3` | Device is AD domain-joined — activation should come from AD/KMS |
| `4` | OEM key is not Home (e.g. Pro, Education) — upgrade not applicable |
| `5` | Could not read OEM key description — check WMI/SoftwareLicensingService |

## Configuration

In `Install-ProKey.ps1`, replace the placeholder with your MAK key and bump `$InstallVersion` if you redeploy with a new key:

```powershell
$ProductKey = 'XXXXX-XXXXX-XXXXX-XXXXX-XXXXX' # replace with your MAK key
$InstallVersion = 'v1'
```

Changing `$InstallVersion` will cause Detection to return undetected on existing devices, forcing a reinstall with the new key.

## Deployment

### As an Intune Win32 App

1. Package the folder contents into an `.intunewin` file
2. Set the **Install command** to:
   ```
   %SystemRoot%\sysnative\WindowsPowerShell\v1.0\powershell.exe -file Install-ProKey.ps1
   ```
3. Set **Install behavior** to **System**
4. Set **Run script in 64-bit PowerShell Host** to **Yes**
5. Under **Requirements**, add `Requirement.ps1` as a custom requirement script — set **Exit code** to `0` for sucess.
    >Also set the *Select output data type* to `String` and have it equal `Home`
6. Under **Detection rules**, use `Detection.ps1` as a custom detection script and make sure to ran it as 64-bit

## Requirements

- Windows 10/11 with a Home OEM (UEFI/OA3) embedded key
- Device must **not** be AD domain-joined (Entra ID / cloud-native only)
- Device must **not** already be activated
- A valid MAK key with available activations
- Runs as SYSTEM
