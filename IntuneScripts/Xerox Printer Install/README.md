# Xerox Printer Install — Intune Win32 (PSADT v4.2)

Self-service Xerox AltaLink printer installer for Intune. The user picks a printer and types their
4-digit code; the package **auto-detects the model over SNMP**, pulls the matching **V4 PostScript
driver** from Xerox at runtime, creates the queue, and turns on **Xerox Standard Accounting** (per-user
quota). One package covers the whole AltaLink C8xxx line (C8170 / C8270 / a future C8370) with **no
per-model repackaging**.

It replaces the old "extract Xerox Smart Start and call its hidden `XeroxSmartStart.Console.exe`" trick,
which broke when Xerox made Smart Start non-extractable. Smart Start really only did two things —
discover the model and fetch the right driver — and this does both itself.

## How It Works

The install (`Install-ADTDeployment`) runs as SYSTEM and:

1. **Prompts** the user for a printer (dropdown) and their 4-digit accounting code (skipped for no-code printers).
2. **Discovers** the model over SNMP (`sysDescr`, raw UDP — no module to bundle) and derives the series (`C81xx`, `C82xx`, …).
3. **Resolves + downloads** the current V4 PS x64 driver ZIP for that series by scraping `support.xerox.com` (always the latest build — no hard-coded version), then stages it with `pnputil`.
4. **Creates** the TCP/IP port and print queue (idempotent).
5. **Installs** the Xerox Desktop Print Experience (the V4 companion app) once per machine, from the `PrinterExtensionUrl` the driver registers.
6. **Writes** the full `XeroxQueueProperties` value (device settings + accounting) straight to the queue — we don't wait for the driver to materialize it (it only does that for the *first* printer).
7. **Applies** it to the live DevMode via `XeroxPrinterConfigurationWriter.exe`, so accounting actually shows enabled and the config tabs lock.
8. **Drops a self-clearing detection marker** so the app stays re-runnable from Company Portal.

## Files

| File | Purpose |
|------|---------|
| `Invoke-AppDeployToolkit.ps1` | PSADT deployment script — the install flow + the config block you edit |
| `PSAppDeployToolkit.Extensions.psm1` | Custom helpers: SNMP discovery, driver-URL resolution, INF parsing, the `XeroxQueueProperties` builder |
| `Xerox-Detection.ps1` | Intune custom detection script (self-clearing, keeps it re-runnable) |

## Configuration

Everything you normally touch is at the top of `Invoke-AppDeployToolkit.ps1`:

```powershell
# 'Display name shown in the picker' = '<hostname>;<ip>[;<fallback model>]'
$XeroxHostNameHashTable = @{
    'Library'      = 'xerox-library.printers.example.com;192.0.2.10'
    'Lab 1'        = 'xerox-lab1.printers.example.com;192.0.2.11;C8170'   # 3rd field optional
    'Front Office' = 'xerox-frontoffice.printers.example.com;192.0.2.12'
    'Lobby'        = 'xerox-lobby.printers.example.com;192.0.2.13'
}
$XeroxNoCodeBuildings = @('Lobby')      # printers that skip the 4-digit code prompt
$DialogSubtitle       = 'IT Department' # shown on every dialog
```

- **Hostname** is used for the print port and SNMP discovery; **IP** goes into the accounting XML and is a SNMP fallback target.
- The optional **3rd field** (e.g. `C8170`) is only used if SNMP can't reach the printer at install time, so an offline device still installs.
- The detection marker key (`HKLM:\SOFTWARE\IntunePrinters` / `XeroxPrinter`) is set in `Invoke-AppDeployToolkit.ps1` (Post-Install) and read in `Xerox-Detection.ps1` — **if you change it, change it in both.**

**Tuning the device settings / accounting:** the "golden" `XeroxQueueProperties` (accounting on, masked
code, Acquire Device Status = Never, diagnostics off, etc.) is baked into `New-XeroxQueuePropertiesValue`
in the extension module, captured from a correctly-configured queue. The per-series identity lives in
`$idMap` there (`C81xx` = Corvo, `C82xx` = Corrib) — add an entry for a new series when you get one. To
retune to your taste: configure one queue exactly how you want it via the driver UI, export
`HKLM\...\Print\Printers\<queue>\QueueProperties\XeroxQueueProperties`, and adapt the template.

## Build the package

This is a [PSADT](https://psappdeploytoolkit.com/) v4.2 package. To assemble it:

1. `New-ADTTemplate -Destination C:\Temp -Name 'Xerox Printer Install'` (PSADT 4.2+).
2. Replace the generated `Invoke-AppDeployToolkit.ps1` with the one here, and drop
   `PSAppDeployToolkit.Extensions.psm1` into the package's `PSAppDeployToolkit.Extensions\` folder.
3. Edit the config block above.
4. Package it:
   ```
   IntuneWinAppUtil.exe -c <packageFolder> -s Invoke-AppDeployToolkit.exe -o <outputFolder> -q
   ```
   (The `Invoke-AppDeployToolkit.exe` launcher is in this repo's [bin/](../../bin/).)

## Deploy in Intune

Apps → Windows → **Add → Windows app (Win32)**:

| Setting | Value |
|---------|-------|
| Install command | `Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Interactive` |
| Uninstall command | `Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode Interactive` *(stub — see To-do)* |
| Install behavior | **System** |
| Detection | Custom script → `Xerox-Detection.ps1`, **run as 32-bit = No** |
| Assignment | **Available** (not Required — see gotchas) |

## Logs

PSADT session log: `C:\Windows\Logs\Software\Xerox_PrinterInstall_*.log`. Useful lines to grep:
`SNMP discovered model`, `Resolved driver URL`, `Created queue`, `Writing XeroxQueueProperties`,
`Applying queue configuration`.

## Gotchas

- **Deploy as Available, never Required.** The detection marker self-clears so the app is always offered
  again (great for users with printers in multiple rooms). A Required assignment would reinstall every
  detection cycle. Side effect: it always shows as installable in Company Portal, never "Installed" — by design.
- **It runs as SYSTEM, and that matters.** SYSTEM has implicit full control over printers, so it can write
  the printer's default config without granting users *"Manage this printer."* Doing the same config by
  hand as a standard user is greyed out until you grant that ACL — SYSTEM sidesteps it.
- **Endpoints need outbound HTTPS to `download.support.xerox.com`** (the driver ZIP and the Desktop Print
  Experience MSI), **as SYSTEM** — test behind your proxy/egress, a VM on open network won't exercise it.
- **The first Xerox printer on a machine wants one reboot** for the driver's config tabs to grey/lock.
  Accounting is functional immediately regardless; the grey is cosmetic.
- **The driver-URL scrape** (`Resolve-XeroxDriverUrl`) depends on Xerox's downloads-page layout. If they
  redesign it, that one function needs a tweak — far more stable than the old extraction, but know it's there.
- **Windows PIN-Protected Printing and Share Diagnostic Data** live in a separate store the
  QueueProperties→DevMode apply doesn't touch, so they keep the driver defaults.

## To-do

- `Uninstall-ADTDeployment` is an empty stub (Company Portal uninstall removes nothing). Add queue/port removal if you need it.
- Hard-fail if the Desktop Print Experience can't install — today it logs and continues, which can leave a "successful" install with non-functional accounting.

## Credits

- [PSAppDeployToolkit](https://psappdeploytoolkit.com/) — packaging framework + the `Invoke-AppDeployToolkit.exe` launcher (GPL).
- Xerox AltaLink V4 PostScript drivers and the Desktop Print Experience are downloaded from Xerox at runtime — nothing Xerox is redistributed in this repo.
