# Changelog

## 1.4.0 — 2026-08-20

- Added an offline `report.html` to every completed test result and ZIP.
- Organized results by game, case, timestamp, and device label.
- Added interactive game display-name capture in the launcher.
- Added a launcher action for opening the latest automatic report.
- Integrated optional Perfetto capture profiles without automatic trace analysis.
- Added AOSP and Huawei/HarmonyOS SurfaceFlinger histogram compatibility.
- Added `Build-CleanRelease.ps1` to create a shareable package without runtime state, test results, traces, device identifiers, or project-specific configuration.
- Kept GamePerf Lite collection as the default path for ordinary and long-running tests.

## Distribution notes

The clean release does not bundle Android Platform Tools. Install `adb` separately and ensure it is available from the Windows command line. No open-source license has been assigned; repository access does not grant redistribution rights beyond the owner's authorization.
