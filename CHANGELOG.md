# Changelog

All notable changes to PIMELIM are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-06-03

First tagged release. PIMELIM keeps Azure Entra PIM role activations scheduled
ahead of time so configured eligible roles stay continuously active across a
rolling coverage horizon, unattended after a one-time device-code bootstrap.

### Added

- Gap-aware activation planner: existing pending activation requests are fetched
  first and new windows are planned only into the uncovered gaps up to
  `COVER_FOR_HOURS`, so requests that PIM would reject as overlapping are never
  submitted.
- `-Version` switch and semver versioning (version is also printed in `-Help`
  and in the startup log line).
- This changelog.

### Fixed

- Eliminated recurring `OverlapsPendingRoleAssignmentRequests` audit failures
  (158 in the past month): PIM validates pending request windows at minute
  granularity with inclusive bounds, so two windows whose boundaries land in the
  same wall-clock minute are rejected as overlapping even with a real gap of up
  to 59 seconds. Planned windows now keep both `ACTIVATION_TIME_BUFFER` and a
  full minute boundary clear of existing pending windows.
- Eliminated the `RoleAssignmentExists` provisioning-failure cascade: immediate
  activations are now clipped to end before the next pending scheduled window
  instead of trampling it, which previously burned the scheduled window and left
  multi-hour coverage holes.

### Changed

- Activation durations can now be shorter than `ACTIVATION_DURATION_HOURS` when
  a window is clipped to clear an upcoming pending window (minimum 5 minutes);
  the Graph request uses `PT<n>M` durations in that case.
- Covered time slots no longer produce per-window `Skipped overlap` log lines;
  a fully covered horizon logs a single summary line instead.

### Prior history

Notable functionality built up before versioning was introduced (see git
history for details):

- Self-activation scheduling for multiple PIM roles from `.env` or CLI
  parameters, with rolling now-based coverage (`COVER_FOR_HOURS`,
  `ACTIVATION_DURATION_HOURS`, `NOW`).
- Device-code bootstrap auth with refresh-token cache for unattended runs.
- `-Setup` interactive first-run wizard, `-Status` table of active/scheduled
  activations, `-DryRun`, structured `-Help`.
- launchd/systemd scheduler templates and a `pimelim.zsh` PATH wrapper.
- macOS Notification Center alert on unattended auth refresh failure.
- Zombie-request handling: past-started pending requests from failed runs do not
  block new scheduling; Graph remains the final arbiter for immediate
  activations.

[1.0.0]: https://github.com/damsleth/PIMELIM/releases/tag/v1.0.0
