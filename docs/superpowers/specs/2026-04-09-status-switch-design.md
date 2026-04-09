# Design: `-Status` Switch for PIMELIM

**Date:** 2026-04-09  
**Status:** Approved

## Summary

Add a `-Status` switch to `pimelim.ps1` that prints a human-readable console table showing which PIM roles are active or scheduled, in which tenant, and for how long.

## Scope

Single-tenant, read-only. Uses the same `.env` / CLI parameters as normal runs. No writes to Graph.

## Output Format

```
Tenant : Contoso Ltd
Tenant ID: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

Role                           Status     Start (UTC)           End (UTC)             Remaining
-----------------------------  ---------  --------------------  --------------------  ---------
Application Administrator      ACTIVE     2026-04-09 08:00:00   2026-04-09 16:00:00   4h 32m
Application Administrator      SCHEDULED  2026-04-09 16:01:00   2026-04-10 00:01:00   in 4h 33m
SharePoint Administrator       SCHEDULED  2026-04-09 09:00:00   2026-04-09 17:00:00   in 36m
Global Reader                  INACTIVE   -                     -                     -
```

- Header: tenant display name + tenant ID
- One row per scheduled/active instance per role
- Roles with no instances get a single `INACTIVE` row with dashes
- Remaining column: `Xh Ym` for ACTIVE (time until end), `in Xh Ym` for SCHEDULED (time until start), `-` for INACTIVE
- Columns aligned with fixed-width padding

## Data Source

Query `roleManagement/directory/roleAssignmentScheduleInstances` filtered by `principalId` and `roleDefinitionId`. This endpoint returns computed instances (authoritative), not raw requests. Active vs scheduled is determined by comparing `startDateTime`/`endDateTime` against current UTC time.

Rationale for choosing instances over requests: instances represent what will actually be active, filtered of pending/failed state. No status filtering required beyond timestamp comparison.

## New Components

### Parameter

```powershell
[switch]$Status
```

Added to `param()` block alongside existing switches.

### `Get-TenantDisplayName` function

- `GET /organization?$select=displayName,id`
- Returns `[PSCustomObject]@{ DisplayName; Id }`
- Falls back to tenant ID if display name is unavailable

### `Get-AllRoleScheduleInstances` function

- Parameters: `$PrincipalId`, `$RoleDefinitionId`, `$AccessToken`
- Queries `roleAssignmentScheduleInstances?$filter=principalId eq '...' and roleDefinitionId eq '...'`
- Handles `@odata.nextLink` pagination (reuses `Get-GraphNextLink`)
- Returns array of `[PSCustomObject]@{ StartUtc; EndUtc }` for all non-expired instances (EndUtc > now)

### `Format-StatusTable` function

- Accepts rows array: `[PSCustomObject]@{ Role; Status; StartUtc; EndUtc }`
- Computes `Remaining` string from current UTC at render time
- Prints tenant header, then column headers, then rows
- Fixed-width columns: Role (30), Status (9), Start (20), End (20), Remaining (variable)

### `Show-PimelimStatus` function

1. Reads `.env` / resolves `TenantId`, `ClientId`, roles (same as `Invoke-Pimelim`)
2. Sets up log file path and token cache path
3. Calls `Get-AccessToken` (read-only, no `-AllowInteractive` - requires existing token)
4. Calls `Get-TenantDisplayName`
5. Calls `GET /me` for principal ID
6. For each configured role:
   - `Get-RoleDefinitionByName` (existing)
   - `Get-AllRoleScheduleInstances`
   - Builds rows: ACTIVE (start <= now < end), SCHEDULED (start > now), or one INACTIVE row
7. Calls `Format-StatusTable` with all rows

## Dispatch

In the top-level `try` block, add before `Invoke-Pimelim`:

```powershell
if ($Status) {
    Show-PimelimStatus
    exit 0
}
```

## Help Text

Add `-Status` entry to `Show-PimelimHelp` output:

```
-Status
  Print a table of currently active and scheduled PIM role activations.
  Requires an existing token cache (run -Bootstrap first if needed).
```

## Error Handling

- If no token cache exists: throw with message directing user to run `-Bootstrap` (same as normal unattended runs)
- If a role definition is not found: log WARN and emit an INACTIVE row for that role rather than throwing
- Graph pagination handled via existing `Get-GraphNextLink`

## Out of Scope

- Multi-tenant support
- JSON/machine-readable output format
- `-Status` + `-DryRun` combination
