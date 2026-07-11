# HP BIOS Update — Intune Remediation

Stages the latest HP BIOS using HP's **Client Management Script Library (CMSL)**, **without
rebooting** — the reboot is left to the user or another process. Detection + remediation, run
as SYSTEM.

## Why CMSL instead of HPIA

HP Image Assistant is a monolithic GUI tool run headless (`Analyze /Category:All
/Action:Install`) — it does everything at once, its results are opaque, and BIOS tends to just
stage with mushy reporting. CMSL is a real scriptable API:

- **Detection is one call:** `Get-HPBIOSUpdates -Check` returns `$true` (up to date) / `$false`
  (update available), comparing the running BIOS to HP's public catalog
  (`ftp.hp.com/pub/pcbios/<platform>`).
- **Flash is one call:** `Get-HPBIOSUpdates -Flash -Yes -BitLocker Suspend` — SHA384-verified
  download, BitLocker suspended by CMSL itself, and the update is **staged** (HP: "a reboot
  will be required for the operation to complete" — CMSL does not reboot).

Same Detect + Remediate / staged.json / no-reboot shape as the Dell and Lenovo scripts.

## How it works

**Detection** (`Detect-HPBiosUpdate.ps1`) — exit `1` triggers remediation:
1. Gate: HP device (manufacturer).
2. `Get-HPBIOSUpdates -Check`. `$true` → compliant. `$false` → update available.
3. `staged.json` (keyed on the BIOS version we flashed *from*) suppresses re-triggering while a
   staged BIOS awaits its reboot; `failed.json` caps retries.

**Remediation** (`Remediate-HPBiosUpdate.ps1`):
1. Same gate + module load.
2. Flash, with **adaptive authentication** (fleet is mixed):
   - Try `Get-HPBIOSUpdates -Flash -Yes -BitLocker Suspend -Quiet` (no password).
   - If HP reports a **Setup password** is required → retry with the AES-decrypted password.
   - If **HP Sure Admin** is enabled → stop and log (Sure Admin needs a *signed payload* via
     `New-HPSureAdminFirmwareUpdatePayload` + `Update-HPFirmware`; not handled here).
3. On success writes `staged.json`; the flash applies on the next reboot.

## Password

CMSL's `-Password` takes the **plaintext** BIOS Setup password — *not* the `.bin` file you use
with HPIA. So it's stored AES-encrypted in the remediation script (run
`New-EncryptedBiosPassword.ps1`, paste the two output lines) and decrypted in memory. Leave
`$BiosPasswordBlob` empty if no Setup password is set — the adaptive flow flashes without one.

> Obfuscation, not secrecy: the AES key lives in the script, so restrict who can view/edit the
> Remediation in Intune and rotate the BIOS password periodically. The plaintext is passed to
> `-Password` (visible briefly in the flash process), same caveat as the Dell script.

## Module delivery

`HPCMSL` is a 14-module meta-package; BIOS only needs four: **HP.Private, HP.Utility,
HP.ClientManagement, HP.Firmware**. The scripts cache just those (downloaded from the gallery at
the current HPCMSL version) under `C:\ProgramData\HP\Module` and import them. A co-located
`Module\` next to the script wins (local testing); a system-installed HPCMSL is used if present.
Delete the cache folder to pull a newer version. No child process is needed (CMSL types load via
`Add-Type`, so there's no ScriptsToProcess class-scope trap like Lenovo).

## Deployment

**Intune → Devices → Remediations → Create**

| Setting | Value |
|---|---|
| Detection / Remediation | the two scripts |
| Run using logged-on credentials | **No** (SYSTEM) |
| Run in 64-bit PowerShell | **Yes** |

Assign to your **HP** device group, scheduled Daily.

## BitLocker note

CMSL's `-BitLocker Suspend` suspends BitLocker for **one reboot** (`-RebootCount 1`). Because
the reboot is deferred, BitLocker stays suspended until then; pair with a sensible reboot
policy. (If the user postpones the flash at pre-boot, BitLocker re-enables and you may hit a
recovery prompt — reboot soon after remediation.)

## Requirements & limits

- HP business PCs (~2016 or newer), booted in **UEFI** (CMSL doesn't support legacy BIOS).
- **HP Sure Admin** fleets are not flashed by these scripts (needs a signed payload) — they're
  detected and logged so you can handle them separately.

## Logs & state

- Log (CMTrace): `C:\Windows\Logs\Software\HPBIOSUpdate.log`.
- State: `C:\ProgramData\HP\` — `staged.json`, `failed.json`, and `Module\` (cached CMSL modules).

## Validated

- All scripts parse; the 4-module cache downloads/imports cleanly and the BIOS cmdlets are
  callable end-to-end under **Windows PowerShell 5.1** (the Intune runtime); `Get-HPBIOSVersion`
  works; direct import from function scope is fine (no class trap).
- **Needs real HP hardware to test:** `Get-HPBIOSUpdates -Check`/`-Flash` (they require a valid
  HP platform ID and HP's catalog), the adaptive password path, and the staged flash. (Can't run
  these on non-HP hardware.)

## To-do / ideas

- Extend to drivers/firmware once ESP is over — CMSL has `Get-HPDeviceDetails` / SoftPaq
  cmdlets, or keep HPIA for full driver runs and use this only for BIOS. Not built yet.
