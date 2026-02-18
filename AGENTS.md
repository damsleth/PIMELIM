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
- Role blocks: `PIM_ROLE_<N>_NAME`, `PIM_ROLE_<N>_REASON`
- Optional: `PIM_TIMEZONE`, `PIM_FUTURE_WINDOWS`, `PIM_ACTIVATION_DURATION_HOURS`, `PIM_LOG_FILE`

## Safety and operations
- Treat `.token-cache.json` as sensitive
- Preserve idempotency (avoid duplicate schedule requests)
- Log clearly to console and configured log file
- Validate with syntax/dry-run before broad changes

## Change policy
- Prefer focused patches over large rewrites
- Update `.env.example` and `README.md` when behavior/config changes
- Do not commit generated logs, token cache, or local secrets
