# Changelog

## 1.4.6 — 2026-08-20

- Removed the CMD compatibility launcher because Windows always creates a visible console for a double-clicked batch file.
- Kept `Start-AndroidGamePerfKit.vbs` as the only supported one-click entry.
- Added smoke-test checks for the VBS working directory, execution-policy bypass, visible PowerShell window, and non-blocking launch.
- Starting the VBS performs only launcher initialization and read-only device discovery before a test is selected.

## 1.4.5 — 2026-08-20

- Added Esc monitoring to the offline smoke test instead of running it outside the controlled child-process path.
- Clears both buffered console input and the historical GetAsyncKeyState press bit before every new task.
- Prevents an Esc press from one task from cancelling the next preflight, cleanup, or test action.
- Centralized child-process waiting, Esc cancellation, process-tree termination, and key-release handling.

## 1.4.4 — 2026-08-20

- Replaced F12 with Esc as the controlled stop key.
- Detects both a currently held Esc key and a short Esc press between polling intervals.
- Added `Start-AndroidGamePerfKit.vbs` as the recommended no-flash launcher.
- Retained the CMD entry only as a compatibility shim that forwards to the VBS launcher.
- Ctrl+C remains native and closes PowerShell directly.

## 1.4.3 — 2026-08-20

- Rebased the cancellation behavior on the v1.4.0 feature set; v1.4.1 and v1.4.2 are abandoned.
- F12 is now the only controlled hotkey: it terminates the current test, performs cleanup, and returns to the main menu.
- Ctrl+C is intentionally not intercepted and keeps the native PowerShell behavior of closing the tool.
- The CMD wrapper starts an independent PowerShell console and exits, preventing the batch-job termination prompt.

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
