# PIMELIM

PIMELIM is a PowerShell tool for unattended scheduling of Azure Entra PIM role activations (for example, `Application Administrator` and `SharePoint Administrator`) using Microsoft Graph.

It is built for your exact flow:
- one-time interactive sign-in bootstrap
- local token cache with refresh
- recurring unattended runs from cron/systemd/Task Scheduler
- pre-scheduling several future 8-hour windows to reduce manual reauth pressure

## How it works

- Reads local settings from `.env` in the same folder as `pimelim.ps1`
- Uses delegated Graph auth via device-code on first run (`-Bootstrap`)
- Stores refresh/access tokens in `.token-cache.json`
- On each run, ensures each configured role has N future activation windows scheduled
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

> Important: strict Conditional Access / MFA policies can still block unattended renewal. PIMELIM mitigates this by pre-scheduling future windows when policy allows it.

## Setup

1. Copy `.env.example` to `.env`
2. Fill in `TENANT_ID`, `CLIENT_ID`, role names, and reasons
3. Bootstrap once interactively:

```bash
pwsh ./pimelim.ps1 -Bootstrap
```

4. Validate without writing requests:

```bash
pwsh ./pimelim.ps1 -DryRun
```

## Run unattended

Example cron entry (every 30 minutes):

```cron
*/30 * * * * cd /path/to/PIMELIM && /usr/bin/pwsh ./pimelim.ps1 >> /path/to/PIMELIM/cron.log 2>&1
```

Example systemd timer strategy (Ubuntu VPS):
- service executes `pwsh /path/to/PIMELIM/pimelim.ps1`
- timer runs every 30m

This cadence keeps future windows topped up and resilient to transient Graph/API failures.

## Configuration

See `.env.example` for full template. Key settings:

- `TENANT_ID`, `CLIENT_ID`
- `PIM_TIMEZONE` (example `UTC+1`)
- `PIM_ACTIVATION_DURATION_HOURS` (typically `8`)
- `PIM_FUTURE_WINDOWS` (how many future windows to keep queued)
- `PIM_LOG_FILE`
- role blocks:
	- `PIM_ROLE_1_NAME`, `PIM_ROLE_1_REASON`
	- `PIM_ROLE_2_NAME`, `PIM_ROLE_2_REASON`
	- and so on

## Notes

- `.token-cache.json` is sensitive; keep permissions tight (`chmod 600`).
- If refresh token becomes invalid/revoked, rerun with `-Bootstrap`.
- This tool only creates `selfActivate` schedule requests; it does not grant role eligibility.
