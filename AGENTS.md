# AGENTS.md

## Purpose
PIMELIM automatically keeps future Azure Entra PIM role activations scheduled for configured eligible roles.

## Scope
- Runtime: PowerShell 7 script (`pimelim.ps1`)
- Configuration source: local `.env` in repo root
- Scheduling templates: `schedulers/` (systemd + launchd)

## Non-negotiable requirements
- Runs unattended after one-time bootstrap sign-in
- Uses least-change edits; do not redesign architecture without explicit request
- Keep compatibility with macOS and Ubuntu
- Never hardcode tenant-specific secrets in tracked files

## Configuration contract
- Required keys: `TENANT_ID`, `CLIENT_ID`
- Required role blocks: `ROLE_<N>_NAME`, `ROLE_<N>_REASON` (at least one)
- Optional keys:
	- `NOW` (default `true`)
	- `COVER_FOR_HOURS` (default `36`)
	- `ACTIVATION_DURATION_HOURS` (default `8`)
	- `LOG_FILE` (default `./pimelim.log`)

## Parameter contract
- Supported CLI parameters:
	- `-Setup`
	- `-TenantId`, `-ClientId`
	- `-Now`
	- `-Roles` (hashtable array and JSON string forms)
	- `-CoverForHours`
	- `-RoleDurationHours`
	- `-Bootstrap`, `-DryRun`, `-Help`
- Precedence: CLI parameters override `.env` values.
- Role reason fallback: if role reason is missing, default reason to role name.
- If no params are provided and `.env` is missing, print `-Help` and exit.

## Help contract
- `-Help` must print a structured, SKILL.md-like guide suitable for both humans and agents.
- `-Setup` must provide interactive first-run setup and trigger bootstrap login.
- Keep sections explicit and stable: purpose, scope, parameters, behavior, requirements, examples.
- When adding/changing parameters or behavior, update `-Help` and `README.md` in the same change.

## Safety and operations
- Treat `.token-cache.json` as sensitive
- Preserve idempotency (avoid duplicate schedule requests)
- Log clearly to console and configured log file
- Validate with syntax/dry-run before broad changes

## Change policy
- Prefer focused patches over large rewrites
- Update `.env.example` and `README.md` when behavior/config changes
- Do not commit generated logs, token cache, or local secrets
