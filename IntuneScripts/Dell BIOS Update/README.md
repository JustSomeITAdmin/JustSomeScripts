# Dell BIOS Update — Intune Remediation

Finds the latest Dell **System BIOS** for *this exact device* from Dell's current enterprise
catalog, downloads only that one BIOS `.exe` (~30–110 MB, not the multi-GB driver pack),
verifies it, suspends BitLocker, and **stages the flash without rebooting** — the reboot is
left to the user or another process. Deployed as an Intune **Remediation** (detection +
remediation), running as SYSTEM.

Built for the case where Windows Update is inconsistent and Dell Command Update misbehaves,
but you still need the newest BIOS (e.g. the Secure Boot certificate updates) on a schedule.

## Why the SDP catalog

Dell **retired `CatalogPC.cab` in December 2025** — it's now months stale, which is exactly
the "my latest BIOS is old" symptom. This uses **`DellSDPCatalogPC.cab`**, which Dell keeps
current. The catalog is ~10 MB (the *driver packs* are the gigabytes, not the catalog), so
parsing it on the device is cheap. No Dell agent required — the device is matched to its BIOS
by `Win32_ComputerSystem.SystemSKUNumber` (hex System ID → decimal `SystemTypeID`) **plus**
an exact model-name match from the package title.

## How It Works

**Detection** (`Detect-DellBiosUpdate.ps1`) — exit `1` triggers remediation:
1. Identifies the Dell model + installed BIOS version.
2. Downloads the SDP catalog via BITS **only when Dell publishes a new one** (cached on the
   catalog's `Last-Modified`), then stream-parses it for the newest applicable BIOS.
3. Compares versions — handles both numeric (`x.x.x`) and legacy `Axx` formats.
4. Newer available → writes `pending.json`, exit `1`. Up to date / already staged → exit `0`.

**Remediation** (`Remediate-DellBiosUpdate.ps1`):
1. Downloads the BIOS `.exe` via BITS direct from `downloads.dell.com`.
2. Verifies **size + SHA1** against the catalog digest.
3. `Suspend-BitLocker -RebootCount 2`, then runs `BIOS.exe /s /p="<pwd>" /l="<log>"` — **no
   `/r`**, so it stages and does not reboot.
4. On success writes `staged.json` (so detection won't re-flash while awaiting reboot). Flash
   failures are counted and capped (`$MaxFailedAttempts` in the detection script).

The staged firmware applies on the **next reboot**; BitLocker auto-resumes after it.

## Configuration

**BIOS admin password** (if your fleet has one): run the helper locally on an admin box,
then paste the two output lines over the placeholders near the top of the remediation script:

```powershell
.\New-EncryptedBiosPassword.ps1
```

Leave `$BiosPasswordKey`/`$BiosPasswordBlob` empty if no BIOS password is set. `$RebootCount`
and `$MaxFailedAttempts` are tunable at the top of the scripts. **`$StateDir` must be
identical in both scripts** — they hand off through JSON files in that folder.

## Deployment

**Intune → Devices → Remediations → Create**

1. Detection = `Detect-DellBiosUpdate.ps1`, Remediation = `Remediate-DellBiosUpdate.ps1`
2. **Run using logged-on credentials → No** (must be SYSTEM)
3. **Run in 64-bit PowerShell → Yes**
4. Assign to a Dell device group, scheduled Daily (the heavy download/parse only happens when
   Dell ships a new catalog; otherwise detection is a tiny HEAD request).

## BitLocker note

Because the reboot is deferred, BitLocker is **suspended from staging until that reboot**
(then auto-resumes via `-RebootCount`). That's an at-rest exposure window for as long as the
user delays rebooting — pair this with a sensible reboot policy.

## Security note (BIOS password)

The AES key lives in the remediation script, so this is **obfuscation, not secrecy** — anyone
who can read the script in Intune can decrypt it. Restrict who can view/edit the Remediation,
and rotate the BIOS password periodically. The plaintext exists only briefly in memory and is
redacted from logs (but is visible in the flash process command line for the few seconds it
runs).

## Logs & state

- Logs (CMTrace): `C:\Windows\Logs\Software\DellBIOSUpdate.log` and the flasher's own
  `DellFlashBIOS.log`.
- State: `C:\ProgramData\Dell\` — `modelcache.json`, `pending.json`, `staged.json`,
  `failed.json`. Big temp files (catalog `.cab`/`.xml`, BIOS `.exe`) go to `%TEMP%` and are
  deleted after use.

## To-do / ideas

- Extend beyond BIOS to full driver/firmware updates from the same SDP catalog (the catalog
  already carries them; matching + apply logic would need to generalize). Not built yet.
