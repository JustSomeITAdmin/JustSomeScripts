# OpenDriverUpdater

A [PSAppDeployToolkit](https://psappdeploytoolkit.com/) 4.2 package that gives Windows **OEM driver updates a
predictable monthly cadence** — the thing Windows Update for Business, Autopatch, and Intune's built-in driver
updates don't give you. It pulls drivers from each vendor's own catalog, installs them once a month in the same
week as your quality updates, and reboots **once**, on your schedule — never three surprise reboots a week because
three OEMs shipped drivers on three different days.

Everything organization- and cadence-specific lives in a single **`driverConfig.json`** — change that, not the code.

> **Deploy-agnostic.** This folder is *just the PSADT package*. Wrap it as an Intune Win32 app, push it with
> ConfigMgr, or run it by hand — that part is up to you. The [Deploying](#deploying) section documents the settings.

## Why

Intune's native driver updates and Autopatch apply drivers whenever the vendor publishes them, with their own
reboots, outside your patch window. On a fleet — and especially on test/lab machines — that means unpredictable,
repeated reboots. OpenDriverUpdater instead:

- checks **once a month**, in the week after Patch Tuesday, aligned to the WUfB deferral/deadline model;
- installs from the **OEM's live catalog** (Dell, Lenovo, HP) or **Windows Update** (everything else);
- reboots **at most once** per month, and only when a driver actually requires it;
- lets the user defer politely for a few days, then enforces a countdown so the reboot still lands in the window.

## How it works

- **Per-vendor, catalog-driven** (no vendor agent installed):
  - **Dell** — Dell's SDP catalog (`DellSDPCatalogPC.cab`), evaluated on the device against its real hardware; applicable DUPs installed silently. No Dell Command | Update.
  - **Lenovo** — `Lenovo.Client.Update` (LSUClient) against Lenovo's catalog.
  - **HP** — HP Image Assistant, drivers category only.
  - **Everything else** (Surface, MSI, Acer, custom builds, VMs) — Windows Update, driver class only.
  - **BIOS/firmware is deliberately excluded** — keep those in your existing BIOS tooling.
- **One monthly window.** A daily SYSTEM scheduled task fires, but the cycle runs only on the first day inside the
  window (Patch Tuesday + `daysAfterPatchTuesday`, for `windowDays`), once a month. There is **no "run now" at
  install** — a freshly imaged machine waits for the next window, so it never reboots for drivers during provisioning.
- **Restart handling** (per profile): if a driver needs a reboot, a prompting profile shows a **Restart Now /
  Cancel** dialog once a day; from `promptDeadlineDays` after the window opens it becomes a **24-hour countdown**
  with no Cancel (Minimize until the final hour), so the reboot still lands in the window. Nobody logged on →
  silent restart on session close. Busy (Zoom/Teams call, presenting, focus/DND) → deferred until the deadline.
- **Version-aware detection.** The Intune detection rule checks a `PackageVersion` marker in the registry. Bump
  `packageVersion` in the config and older installs fail detection → Intune reinstalls → the cached worker
  refreshes. That's how you push a package fix to already-installed devices (see [Updating](#updating-the-package)).

## Requirements

- Windows 10/11, 64-bit.
- PSAppDeployToolkit **4.2+** (fetched by `tools/Get-PSADT.ps1`). **Note:** 4.2 is a *release candidate* until
  4.2.0 ships, and this package genuinely needs it — the restart dialog's Cancel/persist/custom-message options and
  `Test-ADTUserIsBusy` are 4.2-only. The fetch script pulls the module's nupkg straight from the PowerShell Gallery
  v2 feed (no PowerShellGet / `Install-Module`, so it works on a stock 5.1 box) and prefers the newest stable ≥ 4.2.0,
  falling back to the newest prerelease — rc1 today, rc2 automatically once published, GA automatically on release.
  Pin one with `.\tools\Get-PSADT.ps1 -Version 4.2.0-rc2`.
- Runs as **SYSTEM** (the scheduled task and the worker do).
- Internet access to the OEM catalogs / PowerShell Gallery / Windows Update.

## Setup

```powershell
git clone https://github.com/JustSomeITAdmin/JustSomeScripts.git
cd JustSomeScripts\OpenDriverUpdater

# 1. Edit driverConfig.json for your organization (see Configuration below), or run setup.ps1 -Interactive to fill
#    the core fields. Optionally drop your logo at Assets\Icon.png and point the Intune app's Logo at it.

# 2. Run setup. It validates the config, fetches PSAppDeployToolkit 4.2 (module + Invoke-AppDeployToolkit.exe, both
#    gitignored), generates one Detection\ script per profile stamped from the config, and syncs the launcher's
#    -CustomParam ValidateSet. Re-run it any time you change the config - it's the thing that keeps everything lined up.
.\setup.ps1
```

`setup.ps1` fails loudly with a checklist if the config is missing a field, and prints the exact per-profile install
command when it's done. Then package/deploy however you like — see [Deploying](#deploying).

> Prefer to do it by hand? `.\tools\Get-PSADT.ps1` fetches PSADT, and each `Detection\` script needs three values at
> the top — `$PackageDir` (= `stateDir\Package`), `$ExpectedProfile`, `$ExpectedVersion` (= `packageVersion`).
> `setup.ps1` just does all of that for you and can't forget a step.

## Configuration — `driverConfig.json`

The single source of truth. Loaded at runtime by the launcher, the extensions module, and the worker. (Strict JSON —
Windows PowerShell 5.1 has no comment support, so documentation lives here, not in the file.)

| Key | Meaning |
|---|---|
| `organization` | Your org name — appears in log headers. |
| `publisher` | Shown as the app vendor. |
| `installTitle` | The header on every restart dialog the user sees. |
| `packageVersion` | Version marker written to the registry; the detection scripts gate on it (see [Updating](#updating-the-package)). |
| `taskName` | Name of the daily scheduled task, e.g. `Contoso-DriverUpdate`. |
| `registryRoot` | Where state is kept, e.g. `HKLM:\SOFTWARE\Contoso\Drivers` (64-bit view). |
| `stateDir` | Where the package + work files live, e.g. `%ProgramData%\Contoso\DriverUpdates`. |
| `schedule.daysAfterPatchTuesday` | Days after Patch Tuesday the window opens (3 = the Friday). |
| `schedule.windowDays` | Window length in days (Close is exclusive). |
| `schedule.promptDeadlineDays` | Days after the window opens before the ask becomes a forced countdown. |
| `restart.countdownHours` / `countdownMinutes` | Forced-countdown length (PSADT caps a countdown at 24 h). |
| `restart.countdownNoHideHours` | Final stretch where Minimize is hidden. |
| `restart.restartWhenNoUser` | Restart on session close when nobody is logged on. |
| `restart.minBatteryPercent` | Skip the cycle (retry next day) below this battery %, on battery. |
| `profiles.<Name>` | One entry per deployable profile (see below). |

### Profiles

Two ship by default; add as many as you like — add the entry here, then run `.\setup.ps1`, which generates the
matching `Detection\` script and adds the profile to the `-CustomParam` ValidateSet in `Invoke-AppDeployToolkit.ps1`.

| Profile | Opens | Behavior |
|---|---|---|
| **Production** | Patch Tuesday + `daysAfterPatchTuesday` (default +3) | Broad ring. Prompts, then forces a countdown at the deadline. |
| **Pilot** | Patch Tuesday itself (`daysAfterPatchTuesday: 0`) | Ring 0 — same monthly cadence, opened a few days early so a bad driver surfaces before the broad ring. |

Per-profile keys: `time` (task time), `deployMode` (`Auto`/`Silent`), `prompt` (show the restart dialog),
`blockOnConsoleUser` (skip the cycle while someone is active at the console), `restartAfterCycle` (restart on its
own, or leave the reboot to the machine's own scheduled maintenance reboot), and optional `daysAfterPatchTuesday`
to shift that profile's window open. A silent lab/kiosk profile is just `prompt: false`, `restartAfterCycle: false`,
`blockOnConsoleUser: true` — no code change needed.

## Deploying

It's a standard PSADT package. As an **Intune Win32 app** (one app per profile):

| Setting | Value |
|---|---|
| Install command | `Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent -CustomParam Production` (or `Pilot`) |
| Uninstall command | `Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode Silent` |
| Install behavior | **System** |
| Return codes | `0` = success, `3010` / `1641` = soft/hard reboot |
| Detection rule | Custom script → `Detection\DriverUpdate-Detection-Production.ps1` (or `-Pilot.ps1`). 64-bit is the Intune default; the script reads the 64-bit registry view explicitly, so it also reports correctly if run as 32-bit |

Install stages the package under `stateDir\Package`, records the profile, and registers the daily task. It runs
**no cycle** — the first cycle waits for the next window. Assign each app to its own device group; keep the groups
mutually exclusive (a device gets exactly one profile) or use exclusions, since each app's detection reports "not
installed" when the registry profile doesn't match, which would otherwise flip-flop a device between profiles.

## Updating the package

The launcher and worker run from a **cached** copy under `stateDir\Package`, refreshed only on (re)install. To push
a fix to already-installed devices:

1. Bump `packageVersion` in `driverConfig.json`.
2. Run `.\setup.ps1` — it restamps `$ExpectedVersion` in every `Detection\` script to match.
3. Re-deploy the package (new content).

Devices on the old version now fail detection → Intune reinstalls → the cached worker refreshes. This is the only
reliable way to update a cached package; `setup.ps1` keeps the config and the detection scripts in sync so you can't
bump one and forget the other.

Why `$ExpectedVersion` lives in the detection script and is **not** read from the JSON: the detection script is what
Intune delivers fresh with each app version, so it's the only thing on an old device that knows the *new* version.
The cached `driverConfig.json` and the registry both only know the *old* version — if detection read the expected
version from the cache they'd always agree, and a version bump would never reinstall. Everything else
(`taskName`, `registryRoot`) *is* read from the cached config, so those never need mirroring.

## Testing

Three levels, fastest first.

**Unit — the scheduling/restart logic** (no admin, nothing installed). `tests/Test-Extensions.ps1` stubs the PSADT
cmdlets and drives the extension module against a throwaway `HKCU` root, asserting the window math, skip reasons,
and restart decisions for both profiles:

```powershell
.\tests\Test-Extensions.ps1
```

**Vendor reachability** (run **elevated**; installs nothing). The worker hardens its state dir to SYSTEM/Administrators
on every run, so it needs an elevated prompt even for these read-only modes. The self-test only checks it can reach every
vendor source; the scan reports what *would* be installed:

```powershell
.\SupportFiles\Invoke-DriverUpdate.ps1 -SelfTest
.\SupportFiles\Invoke-DriverUpdate.ps1 -ScanOnly
```

**End-to-end on a test VM** (run **elevated**). After `.\tools\Get-PSADT.ps1` and editing `driverConfig.json`,
install as a profile. This stages the package, records state, and registers the daily task — but **runs no driver
cycle** (the first cycle waits for the window), so a good install looks quiet:

```powershell
.\Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent -CustomParam Production
```

To exercise a real driver cycle immediately without waiting for the Patch Tuesday window, run a **Repair on demand** —
a manual Repair ignores the window gate (only the scheduled task with `-Scheduled` applies it):

```powershell
.\Invoke-AppDeployToolkit.exe -DeploymentType Repair -DeployMode Auto -CustomParam Production
```

Verify afterward: the task exists (`Get-ScheduledTask <taskName>`), `HKLM\SOFTWARE\<org>\Drivers` has `Profile`
and `PackageVersion`, the package is cached under `stateDir\Package`, and the worker log is at
`C:\Windows\Logs\Software\<taskName>.log` (the vendor installers' own logs — one per Dell DUP, HPIA's folder — are kept
in a `<taskName>\` subfolder beside it, so they don't pile up in `Logs\Software`). Tear it all down with:

```powershell
.\Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode Silent
```

## Security notes

- Everything under `stateDir` is created and run by **SYSTEM**; the package hardens that folder's ACL (SYSTEM +
  Administrators full, Users read-only) before caching anything, because `C:\ProgramData` is user-writable by
  default and the worker runs elevated — this prevents a local-privilege-escalation via a planted script.
- All state is under the 64-bit registry view (`registryRoot`), never `WOW6432Node`.

## Limitations

- BIOS/firmware updates are out of scope by design.
- Driver installs need a reboot to fully apply; this package batches that into one monthly reboot rather than
  applying instantly.
- The OEM paths depend on the vendors' live catalogs and tools (HPIA, LSUClient, Dell DUPs) remaining available.

## License

[MIT](LICENSE).
