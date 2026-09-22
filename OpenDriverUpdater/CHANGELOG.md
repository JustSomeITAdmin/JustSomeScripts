# Changelog

All notable changes to OpenDriverUpdater are documented here.

## 1.0.0 - 2026-09-22

Initial public release.

- PSAppDeployToolkit 4.2 package: Install stages the package and registers a daily SYSTEM task; Repair runs one driver cycle gated to the monthly Patch Tuesday window; Uninstall removes the task, cache and registry key.
- Vendor paths: Dell (SDP catalog + DUPs), Lenovo (Lenovo.Client.Update), HP (HP Image Assistant), everything else (Windows Update, driver class).
- Two profiles by default, Production (window opens Patch Tuesday + 3) and Pilot (opens on Patch Tuesday); more via driverConfig.json.
- Restart handling: cancellable daily ask, then a forced countdown at the deadline; silent when nobody is logged on; deferred while the user is busy.
- setup.ps1 validates driverConfig.json, fetches PSADT, generates the per-profile Intune detection scripts and syncs the launcher ValidateSet.
- Version-aware detection (registry PackageVersion marker) so a bumped packageVersion re-deploys the cached package.
