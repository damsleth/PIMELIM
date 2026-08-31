# Changelog

All notable changes to PIMELIM are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.1] - 2026-08-31

### Fixed

- `-Status` now includes future nonterminal self-activation requests, which exist
  before Graph exposes their schedule instances, and deduplicates windows visible
  through both APIs during provisioning transitions.
- The planner now clips its final activation window to the coverage horizon instead
  of allowing it to extend by up to almost one role duration past that horizon.
- Stuck-request cleanup now calls Graph's cancel action only for `Granted`
  requests, the only request status for which that action is supported.

## [1.1.0] - 2026-06-03

Hardening release from a full code review of 1.0.0.

### Added

- Stuck pending requests ("zombies": start time passed without provisioning) that
  block an immediate activation are now canceled via the Graph `cancel` action and
  the activation is retried once, instead of being warn-skipped on every run until
  the zombie expires.
- `MINIMUM_WINDOW_MINUTES` config key (default 5, clamped to PIM's 5-minute
  minimum activation duration): smallest free gap worth scheduling.
- A warning is logged when an immediate activation (`NOW=true`) is deferred
  because the free gap before the next pending window is below the minimum — the
  role stays inactive until that pending window starts (bounded wait), which was
  previously silent.

### Changed

- The planner snaps clipped window ends to the whole-minute duration actually
  requested from Graph, so the plan, the logs, and the submitted request agree
  exactly (previously the request could end up to 59 seconds before the planned
  end).
- Clipped-window log lines now show the ISO 8601 duration (`PT7H29M`) instead of
  raw minutes, matching what lands in the Azure audit log.
- The misleading "coverage horizon already filled" log line now states the real
  reason: no schedulable gap of at least the minimum window size remains.
- `CoverForHours=0` short-circuits before any role processing (after token
  acquisition, so `-Bootstrap` still works) instead of logging per-role anchor
  lines it never uses.
- ISO 8601 durations are formatted via `XmlConvert`, keeping the write path
  symmetric with the existing parse path.

### Fixed

- Documentation: `ACTIVATION_TIME_BUFFER` values below 60 are effectively raised
  to the next whole-minute boundary by the minute-granularity rule; the docs
  claimed a literal additive gap (and `.env.example` claimed `0` disables it).

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
  multi-hour coverage holes. (Erratum: when the gap to the next pending window is
  below the minimum window size, the immediate activation is deferred until that
  window starts rather than clipped; 1.1.0 makes this visible in the log.)

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

[1.1.1]: https://github.com/damsleth/PIMELIM/releases/tag/v1.1.1
[1.1.0]: https://github.com/damsleth/PIMELIM/releases/tag/v1.1.0
[1.0.0]: https://github.com/damsleth/PIMELIM/releases/tag/v1.0.0
