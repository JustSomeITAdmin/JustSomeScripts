# Power Seed — Intune Platform Script

One-shot script that seeds sensible Windows power defaults per device — different values on laptops vs desktops, different values on Modern Standby vs traditional-sleep hardware — and disables fast startup so shutdowns actually shut down. Deployed as an Intune **Platform Script** (SYSTEM, 64-bit, once per device). Cross-vendor: Dell, HP, Lenovo, Surface.

**Every setting stays user-changeable.** This seeds; it does not enforce.

## Why a script instead of a Settings Catalog profile

Power settings in the Settings Catalog are ADMX-backed and only have two states:

- **Enabled** — value enforced, control greyed out in Settings > System > Power
- **Not configured** — user has control, but Windows applies no value of its own

There is no third state that supplies a default the user can then change. Writing to the active power scheme with `powercfg` is the only way to seed a value that stays adjustable.

Same reason `powercfg /import` isn't used: it mints a new scheme GUID per device (sampled four devices, got four different GUIDs for the same named plan), and imported schemes get dropped by Windows reset and by "Restore default settings for this plan." Writing to `SCHEME_CURRENT` follows whatever plan is active and survives resets.

## How It Works

1. Detects chassis (**Laptop** vs **Desktop**) using battery presence first, SMBIOS chassis type second, VM detection third. VMs classify as Desktop (they shouldn't sleep).
2. Detects power model by parsing `powercfg /a` — carefully splitting the **available** section from the **not available** section, because a naive match against the whole output flags Modern Standby on machines that don't actually have it.
3. Retires any legacy custom power scheme by NAME (opt-in — see Configuration). Switches to Balanced first if the legacy scheme is active, since the active scheme can't be deleted.
4. Unhides `UnattendedSleepTimeout` and `ConsoleLockDisplayOff` in Advanced Power Settings so users can see the values that were seeded.
5. Applies the profile to `SCHEME_CURRENT`. Per-setting per-rail failures are logged and skipped — expected on hardware without a lid, without a battery rail, or without hibernate support.
6. Disables fast startup by setting `HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power\HiberbootEnabled = 0`. **Not** `powercfg /h off` — that disables hibernation entirely, and Modern Standby devices rely on adaptive hibernate to preserve battery.
7. Records a `state.json` marker so the next run exits early. Bump `$SeedVersion` in the script to re-seed after a change.

### Modern Standby adjustments

On Modern Standby platforms, the seed is adjusted automatically:

- `HibernateAfter` is **removed** from the profile. Setting it to `0` on Modern Standby means "hibernate at the adaptive threshold," not "never." Sampled laptops ship a max-int sentinel that IS a true never — seeding `0` would silently downgrade that.
- `DisplayOff` is **lengthened** (1200 AC / 600 DC). On Modern Standby, display-off is the entry point into connected standby where the Desktop Activity Moderator throttles Win32 apps — so the display timer, not the sleep timer, is what stalls unattended installs.

## Configuration

At the top of `PowerSeed.ps1`:

```powershell
# Bump to re-seed the fleet on the next script run.
$SeedVersion = '2.1'

# Optionally retire a previously-deployed custom power scheme by NAME.
# Off by default. The script REFUSES to run legacy cleanup with an empty
# match string (would otherwise match every scheme).
$RemoveLegacyScheme = $false
$LegacySchemeMatch  = ''     # e.g. 'MyOrg Power'

# Surface hidden settings in Advanced Power Settings.
$UnhideHiddenSettings = $true

# See the "Why not `powercfg /h off`" note above.
$DisableFastStartup = $true

# Wake timer normalisation is off by default. Sampled hardware was inconsistent
# (AC-Enable/DC-Disable, both-Enable, both-Disable). Enable to normalise.
$NormalizeWakeTimers = $false
```

The `$DesktopProfile`, `$LaptopProfile`, and `$ModernStandbyAdjustments` hashtables below the flags define what gets seeded. A `$null` rail is skipped, leaving the existing value untouched. The one **judgment call** is `LidClose AC = 0 (Do nothing)` — suits users who dock lid-closed at the cost of an unplugged closed laptop that keeps running in a bag. Set to `1 (Sleep)` if lid-closed docking is uncommon in your population.

## Deployment

1. Set `$SeedVersion` / cleanup / lid behaviour to fit your fleet, then upload `PowerSeed.ps1` to Intune as a **Platform Script**
2. **Run this script using the logged on credentials → No** (must run as SYSTEM)
3. **Run script in 64-bit PowerShell Host → Yes**
4. Assign to your device group. **No vendor filter needed** — chassis / OS / Modern Standby detection is entirely in the script.

Autopilot **device preparation** (new) runs Platform Scripts during OOBE — assign to the device group AND add to the device preparation policy. Classic Autopilot ESP does not track or block on Platform Scripts, so they run once IME lands after ESP completes.

## Logs and state

- `C:\ProgramData\PowerSeed\seed.log` — CMTrace-format log (open in CMTrace, or `Get-Content`)
- `C:\ProgramData\PowerSeed\state.json` — machine-readable outcome for fleet audit. Includes chassis, power model, applied/skipped counts, legacy schemes removed, fast-startup result

State directory ACL is locked down at creation: SYSTEM + Administrators FullControl, Users ReadAndExecute. A standard user with write here could delete the marker to force a re-seed or plant a junction to redirect the log write.

## Parameters

- `-WhatIfOnly` — reports detected hardware and planned values, then exits. State file is not written. Use on the first devices before mass-deploying.
- `-Force` — apply regardless of the existing state marker. Overwrites user changes.

## Rollback

```powershell
powercfg /restoredefaultschemes
```

Deletes custom schemes and restores built-ins to factory values. **Also removes OEM-supplied schemes**, so test on one device before fleet use.

Fast startup rollback:
```powershell
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -Value 1
```
Takes effect at next shutdown.

## Gotchas

- **Locking and sleeping are unrelated.** `InteractiveLogon_MachineInactivityLimit` runs the screen saver (which locks). Any process holding `ES_DISPLAY_REQUIRED` (media players, conferencing clients, browsers playing video, even the Windows Clock app running a timer) suppresses screen saver activation and therefore the lock. Diagnose with `powercfg /requests`.
- **Power CSP overrides beat this script.** Anything under `HKLM\SOFTWARE\Policies\Microsoft\Power\PowerSettings` overrides every power scheme, including a value seeded by this script. The script logs a warning if it finds any.
- **`UnattendedSleepTimeout` semantics** — applies only after wake from sleep triggered by a non-human event (wake timer, WoL, wake-to-run scheduled task). Does not govern a machine powered on manually and left alone; that's `StandbyTimeout`.
- **Autopilot lab builds are cold boots** — governed by `StandbyTimeout`, not `UnattendedSleep`.
- **All sampled Dell desktops report zero reachable standby states** (Device Guard/VBS cited on one). Their sleep values are written as insurance against a firmware or VBS change, but are inert today. Any energy reporting that assumes desktops sleep overnight is measuring something that doesn't happen.
