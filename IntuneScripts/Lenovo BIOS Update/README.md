# Lenovo BIOS Update — Intune Remediation

Stages the latest **Lenovo BIOS/UEFI** update (ThinkPad, ThinkStation, ThinkCentre, …) using
Lenovo's official **`Lenovo.Client.Update` (LCU)** module, **without rebooting** — the reboot
is left to the user or another process. Detection + remediation, run as SYSTEM.

LCU is Lenovo's supported successor to LSUClient (they credit jantari; the module is LSUClient
under the hood). It handles catalog lookup, signature-checked download, and the silent flash —
so these scripts are thin wrappers, not a hand-rolled catalog parser like the Dell one.

## How it works

**Detection** (`Detect-LenovoBiosUpdate.ps1`) — exit `1` triggers remediation:
1. Gate: any **Lenovo** device (ThinkPad, ThinkStation, ThinkCentre, …).
2. Prereq (ThinkPad-only): `WindowsUEFIFirmwareUpdate` and `BIOSUpdateByEndUsers` must be
   **Enabled** *where they exist* (read via `Lenovo_BiosSetting` WMI; both SVP-locked, so we
   only read them). Models without them (e.g. ThinkStation) skip this check; a present-but-
   Disabled setting stops (a flash would just fail).
3. `Get-LnvUpdate` (returns only applicable + not-installed), filtered to `Type = 'BIOS'`.
4. `staged.json` suppresses re-triggering while a flashed BIOS awaits its reboot; `failed.json`
   caps retries on a persistently-failing flash.

**Remediation** (`Remediate-LenovoBiosUpdate.ps1`):
1. Same gates.
2. `Suspend-BitLocker -RebootCount 2` (LCU doesn't do this itself).
3. `Save-LnvUpdate` → `Install-LnvUpdate -SaveBIOSUpdateInfoToRegistry`. **`Install-LnvUpdate`
   never reboots** — it stages the flash and returns `.Success` / `.PendingAction`
   (`REBOOT_MANDATORY` / `SHUTDOWN`). On success writes `staged.json`; the flash applies on the
   next reboot.

**No BIOS password** is needed to flash a Lenovo from within Windows (unlike Dell).

## Why LCU runs in a child process

LCU loads its classes (`MachineCharacteristics`, etc.) via the manifest's `ScriptsToProcess`.
Those PowerShell types only resolve reliably in a **fresh session that imports the module as
its first action** — from inside a script's functions, or a persistent/stepped/ISE session,
`Get-LnvUpdate` throws `Unable to find type [MachineCharacteristics]` (affects both PS 5.1 and
7). So both scripts run every LCU cmdlet in a dedicated child `powershell.exe`
(`Invoke-LcuChild`) that imports the module and returns JSON. Deterministic regardless of how
the parent is launched.

> Debugging tip: don't `Import-Module Lenovo.Client.Update; Get-LnvUpdate` interactively — it
> will hit the type error. Run the child pattern in a fresh window instead.

## Module delivery

Lenovo warns that `Install-Module` is flaky under SYSTEM. Instead these scripts resolve the
latest module version via the Gallery's OData feed (`FindPackagesById()`), download the
versioned `.nupkg` with `Invoke-RestMethod`, and cache it at `C:\ProgramData\Lenovo\Module`
(the child imports it from there). A copy already installed on `PSModulePath`, if present, is
preferred. To pull a newer module version, delete that folder. (The bare `/package/<id>` URL
302-redirects to the versioned blob, which `Start-BitsTransfer` won't follow — hence the OData
lookup.)

## Deployment

**Intune → Devices → Remediations → Create**

| Setting | Value |
|---|---|
| Detection / Remediation | the two scripts |
| Run using logged-on credentials | **No** (SYSTEM) |
| Run in 64-bit PowerShell | **Yes** |

Assign to your **Lenovo** device group, scheduled Daily.

## BitLocker note

Because the reboot is deferred, BitLocker stays **suspended from staging until that reboot**
(then auto-resumes via `-RebootCount`). Pair with a sensible reboot policy.

## Logs & state

- Log (CMTrace): `C:\Windows\Logs\Software\LenovoBIOSUpdate.log`. LCU also logs under
  `C:\ProgramData\Lenovo\Lenovo.Client.Update\`.
- State: `C:\ProgramData\Lenovo\` — `staged.json`, `failed.json`, and `Module\` (cached module).
- BIOS packages download to `%TEMP%\LenovoBiosUpdate` and are cleaned up after.

## Validated

- Module resolves + downloads (versioned `.nupkg` via OData) and imports cleanly; `PackageType`
  enum includes `BIOS`; `Install-LnvUpdate` does not reboot (confirmed in module source).
- Full flow runs under **Windows PowerShell 5.1** (the Intune runtime) via the child-process
  pattern — no `MachineCharacteristics` type error.
- On real hardware: a **ThinkStation** reported up to date (the settings-absent path proceeds
  correctly), and a **ThinkPad** detected → remediation staged the BIOS (e.g. `1.33 → 1.36`,
  `PendingAction=REBOOT_MANDATORY`), no reboot, `staged.json` written.

## To-do / ideas

- Extend to all drivers/firmware once ESP is over: relax the `Type -eq 'BIOS'` filter in the
  child scripts (`$ChildGetBios` / `$ChildInstallBios`) — LCU returns everything applicable.
  Consider excluding or scheduling reboot-forcing packages. Not built yet.
