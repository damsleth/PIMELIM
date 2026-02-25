# Scheduler templates

This folder contains unattended scheduler templates for running PIMELIM every 30 minutes.

## Ubuntu (systemd)

Files:
- `systemd/pimelim.service`
- `systemd/pimelim.timer`

Setup (as root):
1. Copy both files to `/etc/systemd/system/`
2. Edit `User`, `WorkingDirectory`, and script path in `pimelim.service`
3. Enable and start timer:
   - `systemctl daemon-reload`
   - `systemctl enable --now pimelim.timer`
4. Verify:
   - `systemctl status pimelim.timer`
   - `journalctl -u pimelim.service -f`

## macOS (launchd)

File:
- `launchd/com.pimelim.runner.plist`

Setup (per-user):
1. Edit `ProgramArguments`, `WorkingDirectory`, and log file paths in plist
2. Copy plist to `~/Library/LaunchAgents/`
3. Load and start:
   - `launchctl unload ~/Library/LaunchAgents/com.pimelim.runner.plist 2>/dev/null || true`
   - `launchctl load -w ~/Library/LaunchAgents/com.pimelim.runner.plist`
4. Verify:
   - `launchctl list | grep com.pimelim.runner`

Notes:
- Run bootstrap once manually before enabling unattended schedule:
  - `pwsh ./pimelim.ps1 -Bootstrap`
- Keep `.token-cache.json` permissions restrictive.
- On macOS, if unattended refresh-token auth fails, PIMELIM sends a local notification via `osascript` (if available).

Recommended `.env` keys for unattended runs:
- Required keys:
   - `TENANT_ID=...`
   - `CLIENT_ID=...`
- Required role blocks (at least one):
   - `ROLE_1_NAME=Application Administrator`
   - `ROLE_1_REASON=Your reason`
- Optional keys:
   - `NOW=true` (default: true)
   - `COVER_FOR_HOURS=36` (default: 36)
   - `ACTIVATION_DURATION_HOURS=8` (default: 8)
   - `LOG_FILE=./pimelim.log` (default: `./pimelim.log`)