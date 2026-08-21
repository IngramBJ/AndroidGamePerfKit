# Changelog

## 1.6.0 — 2026-08-21

- Added one-click batch aggregation for every completed result under `results` without requiring a connected device.
- Added normalized CSV and JSON output with one row per run, covering identity, FPS percentiles, long frames, CPU, UnityMain, memory, thermal, Perfetto, data quality, warnings, and result paths.
- Added a searchable offline batch HTML dashboard and a compact anomalies text report.
- Added conservative `pass`, `warn`, `review`, and `fail` triage for rapid table filling and follow-up selection.
- Added a small sharing ZIP that excludes samples, logcat, dumpsys, Perfetto traces, and other large raw artifacts.
- Added menu item 17 and `-Command batch`, including optional external `-ResultsRoot` scanning.
- Added offline end-to-end tests for row mapping, JSON counts, HTML content, anomaly output, and ZIP privacy.

## 1.5.3 — 2026-08-21

- Added a longrun mode that immediately executes the first calibrated step as the battle-start tap.
- Corrected the automated cycle to support `start battle -> wait battle duration -> settlement/navigation taps -> next battle`.
- Calibration JSON/TXT now records `startWithFirstTap`, and the main launcher imports it automatically.
- Added an explicit runtime confirmation, click-sequence preview, and state-specific start instructions.
- Added per-tap markers and fail-fast ADB error handling so attempted automatic taps can be audited.
- Preserved the legacy mode for sequences that contain only post-battle navigation taps.

## 1.5.2 — 2026-08-21

- Added multi-source foreground-package detection for devices that do not expose `mResumedActivity`.
- Added compatibility with `topResumedActivity`, `mCurrentFocus`, `mFocusedWindow`, `mFocusedApp`, `ComponentInfo`, and `ACTIVITY` output formats.
- Added Activity, Window, `cmd activity get-top-activity`, and top-activity fallback probes.
- Shared the same foreground-package detector between the main launcher and longrun calibrator.

## 1.5.1 — 2026-08-21

- Added an immediately updated `calibration-log.txt` for longrun coordinate and battle-time calibration.
- Each coordinate now records a readable description, a single-step copy value, and the complete current paste sequence.
- Each completed battle immediately records its duration and the current recommended wait time.
- Calibration creates its result folder before capture starts, so completed records survive interruption or errors.

## 1.5.0 — 2026-08-21

- Added a standalone longrun calibration assistant with its own VBS entry.
- Added OEM-probed `getevent` touchscreen discovery and raw-to-display coordinate conversion for rotations 0–3.
- Added automatic phone tap coordinate capture with manual fallback and no files written to the device.
- Added multi-round battle timing using either Enter markers or two phone taps, plus a safe recommended `battleSeconds` value.
- Added local TXT, CSV, JSON, and clipboard exports under `Longrun-Calibrator/calibration-results`.
- Added longrun import and one-line paste modes to the main launcher, including resolution/rotation mismatch warnings.
- Added offline fixtures and regression tests for Huawei-style touch capabilities, touch parsing, rotation mapping, sequence parsing, and battle-time recommendations.

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
