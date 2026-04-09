# PIMELIM
**Privileged Identity Management Easy Login Interval Maintainer**.

PIM activation in Azure is a pain.  
You have to remember to activate your eligible roles before you need them, and if you want to keep a future activation window scheduled, you have to manually create a new schedule request every time one expires.  

PIMELIM is a PowerShell tool for unattended scheduling of Azure Entra PIM role activations (for example, `Application Administrator` and `SharePoint Administrator`) using Microsoft Graph.

Quick start:

```bash
pwsh ./pimelim.ps1 -Setup
```

It is built for your exact flow:
- one-time interactive sign-in bootstrap
- local token cache with refresh
- recurring unattended runs from cron/systemd/Task Scheduler
- optional immediate activation + configurable coverage horizon in hours

## How it works

- Reads local settings from `.env` in the same folder as `pimelim.ps1`
- CLI parameters override `.env` values when provided
- Uses delegated Graph auth via device-code on first run (`-Bootstrap`)
- Stores refresh/access tokens in `.token-cache.json`
- On each run, schedules per role using `Now` + `COVER_FOR_HOURS` (or CLI `-CoverForHours`):
	- active role: starts from current active end-time
	- inactive role + `Now=true`: schedules starting immediately
	- inactive role + `Now=false`: schedules future-only starting at now + duration
- Number of windows is calculated as `ceil(CoverForHours / RoleDurationHours)`
- Overlapping windows are skipped. If Graph still returns an overlap on create, it is logged and treated as skipped.
- Logs to console + local log file

## Prerequisites

- PowerShell 7+ (`pwsh`)
- Entra app registration (public client) with delegated Microsoft Graph permissions:
	- `RoleManagement.ReadWrite.Directory`
	- `offline_access`
	- `openid`
	- `profile`
- Admin consent granted for required delegated permissions
- Eligible PIM assignment for each role you want to activate

> Important: strict Conditional Access / MFA policies can still block unattended renewal. PIMELIM mitigates this by pre-scheduling enough windows to cover the configured horizon when policy allows it.

## Setup

Recommended first run (interactive wizard):

```bash
pwsh ./pimelim.ps1 -Setup
```

`-Setup` will:
- create `.env` from `.env.example` if needed
- prompt for required values (`TENANT_ID`, `CLIENT_ID`, and at least one `ROLE_<N>_NAME` + `ROLE_<N>_REASON` block)
- run bootstrap device login

If you run `pwsh ./pimelim.ps1` with no parameters and no `.env` present, PIMELIM prints `-Help` output.

1. Copy `.env.example` to `.env`
2. Fill in `TENANT_ID`, `CLIENT_ID`, role names, and reasons
3. First run will auto-bootstrap interactively if no token cache exists (or run explicitly with `-Bootstrap`):

```bash
pwsh ./pimelim.ps1 -Bootstrap
```

Or bootstrap with explicit CLI parameters:

```bash
pwsh ./pimelim.ps1 -Bootstrap -Now $true -CoverForHours 36 -RoleDurationHours 8 -Roles @(@{name="Application Administrator";reason="apps are great"},@{name="SharePoint Administrator"})
```

4. Validate without writing requests:

```bash
pwsh ./pimelim.ps1 -DryRun
```

## Usage Examples

Use `.env` values only:

```bash
pwsh ./pimelim.ps1
```

Dry-run with `.env` values:

```bash
pwsh ./pimelim.ps1 -DryRun
```

PowerShell hashtable roles (recommended):

```bash
pwsh -NoProfile -Command '& ./pimelim.ps1 -Now true -CoverForHours 36 -RoleDurationHours 8 -Roles @(@{name="Application Administrator";reason="apps are great"},@{name="SharePoint Administrator"})'
```

JSON roles input:

```bash
pwsh -NoProfile -Command '& ./pimelim.ps1 -Now true -CoverForHours 36 -RoleDurationHours 8 -Roles ''[{"name":"Application Administrator","reason":"apps are great"},{"name":"SharePoint Administrator"}]''' 
```

Future-only scheduling (no immediate activation for inactive roles):

```bash
pwsh ./pimelim.ps1 -Now false -CoverForHours 36
```

## Run unattended

Example cron entry (every 30 minutes):

```cron
*/30 * * * * cd /path/to/PIMELIM && /usr/bin/pwsh ./pimelim.ps1 >> /path/to/PIMELIM/cron.log 2>&1
```

Example systemd timer strategy (Ubuntu VPS):
- service executes `pwsh /path/to/PIMELIM/pimelim.ps1`
- timer runs every 30m

This cadence keeps coverage topped up and resilient to transient Graph/API failures.

## Scheduler templates

Ready-to-edit scheduler templates are included in:
- `schedulers/systemd/pimelim.service`
- `schedulers/systemd/pimelim.timer`
- `schedulers/launchd/com.pimelim.runner.plist`

See `schedulers/README.md` for setup steps.

## Configuration

See `.env.example` for full template. Key settings:

- Required keys:
	- `TENANT_ID`, `CLIENT_ID`
- Required role blocks:
	- `ROLE_1_NAME`, `ROLE_1_REASON`
	- `ROLE_2_NAME`, `ROLE_2_REASON`
	- and so on
- Optional keys:
	- `NOW` (default `true`)
	- `COVER_FOR_HOURS` (default `36`)
	- `ACTIVATION_DURATION_HOURS` (default `8`)
	- `ACTIVATION_TIME_BUFFER` (default `60`) — seconds added between consecutive scheduled windows to prevent Graph overlap errors
	- `LOG_FILE` (default `./pimelim.log`)

## CLI Parameters

- `-TenantId <string>`
- `-ClientId <string>`
- `-Now <bool>`
- `-Roles <object[]>` (hashtable array or JSON string)
- `-CoverForHours <int>`
- `-RoleDurationHours <int>`
- `-Bootstrap`
- `-DryRun`
- `-Status`
- `-Help`

`-Status` prints a console table of currently active and upcoming scheduled PIM role activations, including start/end times and remaining duration per window.

`-Help` prints a structured guide intended for both human and AI-agent readability.

## Notes

- `.token-cache.json` is sensitive; keep permissions tight (`chmod 600`).
- If refresh token becomes invalid/revoked, rerun with `-Bootstrap`.
- On macOS, unattended auth refresh failure triggers a local Notification Center alert via `osascript` when available.
- This tool only creates `selfActivate` schedule requests; it does not grant role eligibility.
