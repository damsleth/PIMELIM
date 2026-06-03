#!/usr/bin/env pwsh

[CmdletBinding()]
param(
    [string]$EnvFile = ".env",
    [switch]$Setup,
    [string]$TenantId,
    [string]$ClientId,
    [string]$Now,
    [object[]]$Roles,
    [int]$CoverForHours = -1,
    [int]$RoleDurationHours = -1,
    [switch]$Bootstrap,
    [switch]$DryRun,
    [switch]$Status,
    [Alias("v")][switch]$Version,
    [Alias("h")][switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:LogFilePath = $null
$script:PimelimVersion = "1.0.0"

# Workaround: .NET may try IPv6 first for Microsoft endpoints; on networks with
# split-DNS or broken IPv6 routes this causes DNS resolution and connection hangs.
# Must be set as env var before any .NET networking is used (AppContext switch alone
# is insufficient — it doesn't cover DNS resolution on all platforms).
$env:DOTNET_SYSTEM_NET_DISABLEIPV6 = "1"

function Show-PimelimHelp {
    @"
# PIMELIM v$($script:PimelimVersion) CLI Help

## Purpose
Automate Azure Entra PIM self-activation requests for configured eligible roles.

## Scope
- Runtime: PowerShell 7 script
- Auth: Device-code bootstrap + refresh-token cache
- Supports unattended runs (cron/systemd/launchd)

## Parameters
-Setup
    Interactive first-run wizard:
    - creates .env from .env.example if missing
    - prompts for TenantId, ClientId, and at least one role+reason
    - runs bootstrap login

-TenantId <string>
  Entra tenant ID or domain.
  Fallback: TENANT_ID in .env

-ClientId <string>
  App registration client ID.
  Fallback: CLIENT_ID in .env

-Now <bool>
  If true and role is inactive, schedule immediate activation window.
  Default: true
  Fallback: NOW in .env (true/false)

-Roles <object[]>
  Array/list of role objects. Supported input:
  1) Hashtable array literal (recommended):
     -Roles @(@{name="Application Administrator";reason="apps are great"}, @{name="SharePoint Administrator"})
  2) JSON string:
     -Roles '[{"name":"Application Administrator","reason":"apps are great"}]'

  Required field: name
  Optional field: reason
  If reason is missing/blank, reason defaults to name.
    Fallback: ROLE_<N>_NAME and ROLE_<N>_REASON in .env

-CoverForHours <int>
    Target coverage horizon from scheduling anchor (hours).
    Default: 36
    Fallback: COVER_FOR_HOURS in .env

-RoleDurationHours <int>
  Activation duration (hours).
  Default: 8
        Fallback: ACTIVATION_DURATION_HOURS in .env

ACTIVATION_TIME_BUFFER <int> (env only)
  Seconds added between consecutive scheduled windows to avoid Graph overlap errors.
  Default: 60
  Fallback: ACTIVATION_TIME_BUFFER in .env

-Bootstrap
    Forces interactive device-code login if needed.
    If token cache is missing, bootstrap is auto-enabled even without this switch.

-DryRun
  Logs planned requests without creating schedule requests.

-Status
  Print a table of currently active and scheduled PIM role activations.
  Requires an existing token cache (run -Bootstrap first if needed).

-Version
  Prints the PIMELIM version (semver). See CHANGELOG.md for release history.

-Help
  Prints this guide.

Default behavior:
- If run with no parameters and no .env exists, help is printed.
- On macOS, unattended auth failure triggers a local notification via osascript (if available).

## Scheduling Behavior
Per role:
- If role is currently active: coverage is anchored at the active end-time.
- If role is inactive and Now=true: coverage is anchored at now (immediate activation).
- If role is inactive and Now=false: coverage is anchored at now + duration (future-only).

Coverage model:
- Existing pending activation requests are fetched first; new windows are planned
  only into the uncovered gaps between them, up to CoverForHours from the anchor.
- Windows are RoleDurationHours long, except when a window is clipped shorter to
  clear an upcoming pending request window.
- CoverForHours=0 schedules no windows.

Overlap safety:
- PIM rejects a new timebound request whose boundary lands in the same wall-clock
  minute as an existing pending request boundary (minute granularity, inclusive).
  Planned windows therefore keep at least ACTIVATION_TIME_BUFFER seconds AND a
  full minute boundary clear of existing pending windows, so doomed requests are
  never submitted.
- If Graph still reports overlap during create (e.g. a zombie pending request from
  a prior failed run), the window is logged as skipped and execution continues.

## Requirements
- PowerShell 7+
- Entra app registration with delegated Graph permissions:
  RoleManagement.ReadWrite.Directory, offline_access, openid, profile
- Eligible PIM role assignments for target roles

## Examples
# Interactive setup wizard (recommended first run)
pwsh ./pimelim.ps1 -Setup

# Bootstrap once using .env
pwsh ./pimelim.ps1 -Bootstrap

# Run with .env values only
pwsh ./pimelim.ps1

# Dry-run with .env values
pwsh ./pimelim.ps1 -DryRun

# Dry-run with explicit hashtable roles
pwsh ./pimelim.ps1 -DryRun -TenantId "<tenant>" -ClientId "<client>" -Now $true -CoverForHours 36 -RoleDurationHours 8 -Roles @(@{name="Application Administrator"}, @{name="SharePoint Administrator";reason="SharePoint ops"})

# Dry-run with JSON roles
pwsh ./pimelim.ps1 -DryRun -Now true -CoverForHours 36 -Roles '[{"name":"Application Administrator"},{"name":"SharePoint Administrator","reason":"SharePoint ops"}]'

# Future-only scheduling (inactive roles are not activated immediately)
pwsh ./pimelim.ps1 -Now false -CoverForHours 36
"@
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR")][string]$Level = "INFO"
    )

    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "[$timestamp][$Level] $Message"
    Write-Host $line
    if ($script:LogFilePath) {
        Add-Content -Path $script:LogFilePath -Value $line
    }
}

function Send-MacNotification {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$Title = "PIMELIM"
    )

    if (-not $IsMacOS) { return }

    $osascript = Get-Command -Name "osascript" -ErrorAction SilentlyContinue
    if (-not $osascript) { return }

    $safeMessage = $Message.Replace('"', '\"').Replace("`n", " ").Replace("`r", " ")
    $safeTitle = $Title.Replace('"', '\"').Replace("`n", " ").Replace("`r", " ")
    $scriptLine = 'display notification "{0}" with title "{1}"' -f $safeMessage, $safeTitle

    try {
        & $osascript.Source -e $scriptLine | Out-Null
    }
    catch {
    }
}

function Resolve-PathSafe {
    param([Parameter(Mandatory = $true)][string]$BaseDirectory, [Parameter(Mandatory = $true)][string]$PathValue)
    if ([System.IO.Path]::IsPathRooted($PathValue)) { return [System.IO.Path]::GetFullPath($PathValue) }
    return [System.IO.Path]::GetFullPath((Join-Path $BaseDirectory $PathValue))
}

function Prompt-Value {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [string]$DefaultValue = "",
        [switch]$Required
    )

    while ($true) {
        $suffix = if (-not [string]::IsNullOrWhiteSpace($DefaultValue)) { " [$DefaultValue]" } else { "" }
        $input = Read-Host "$Prompt$suffix"

        if ([string]::IsNullOrWhiteSpace($input)) {
            if (-not [string]::IsNullOrWhiteSpace($DefaultValue)) {
                return $DefaultValue
            }
            if (-not $Required) {
                return ""
            }
            Write-Host "Value is required." -ForegroundColor Yellow
            continue
        }

        return $input.Trim()
    }
}

function Write-EnvFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][hashtable]$EnvMap
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($key in @("TENANT_ID", "CLIENT_ID", "NOW", "COVER_FOR_HOURS", "ACTIVATION_DURATION_HOURS", "ACTIVATION_TIME_BUFFER", "LOG_FILE")) {
        if ($EnvMap.ContainsKey($key)) {
            $lines.Add("$key=$($EnvMap[$key])")
        }
    }

    $roleIndex = 1
    while ($true) {
        $nameKey = "ROLE_${roleIndex}_NAME"
        $reasonKey = "ROLE_${roleIndex}_REASON"
        if (-not $EnvMap.ContainsKey($nameKey)) {
            break
        }

        $lines.Add("")
        $lines.Add("$nameKey=$($EnvMap[$nameKey])")
        $lines.Add("$reasonKey=$($EnvMap[$reasonKey])")
        $roleIndex++
    }

    $content = ($lines -join [Environment]::NewLine) + [Environment]::NewLine
    Set-Content -Path $Path -Value $content
}

function Invoke-SetupWizard {
    param([string]$ScriptDirectory, [string]$EnvPath)

    $envExamplePath = Join-Path $ScriptDirectory ".env.example"
    if (-not (Test-Path -Path $EnvPath)) {
        if (Test-Path -Path $envExamplePath) {
            Copy-Item -Path $envExamplePath -Destination $EnvPath
            Write-Host "Created .env from .env.example"
        }
        else {
            Set-Content -Path $EnvPath -Value "TENANT_ID=`nCLIENT_ID=`nNOW=true`nCOVER_FOR_HOURS=36`nACTIVATION_DURATION_HOURS=8`nLOG_FILE=./pimelim.log`n"
            Write-Host "Created new .env"
        }
    }
    else {
        Write-Host ".env already exists. Using existing values as defaults."
    }

    $envMap = Read-EnvFile -Path $EnvPath
    $envMap["TENANT_ID"] = Prompt-Value -Prompt "Tenant ID" -DefaultValue (Get-ConfigValue -EnvMap $envMap -Key "TENANT_ID") -Required
    $envMap["CLIENT_ID"] = Prompt-Value -Prompt "Client ID" -DefaultValue (Get-ConfigValue -EnvMap $envMap -Key "CLIENT_ID") -Required

    if (-not $envMap.ContainsKey("NOW")) { $envMap["NOW"] = "true" }
    if (-not $envMap.ContainsKey("COVER_FOR_HOURS")) { $envMap["COVER_FOR_HOURS"] = "36" }
    if (-not $envMap.ContainsKey("ACTIVATION_DURATION_HOURS")) {
        $envMap["ACTIVATION_DURATION_HOURS"] = "8"
    }
    if (-not $envMap.ContainsKey("LOG_FILE")) { $envMap["LOG_FILE"] = "./pimelim.log" }

    $existingRoles = Get-RoleConfigsFromEnv -EnvMap $envMap
    $defaultRoleCount = if ($existingRoles.Count -gt 0) { $existingRoles.Count } else { 1 }
    $roleCountRaw = Prompt-Value -Prompt "Number of PIM roles" -DefaultValue $defaultRoleCount -Required
    $roleCount = 1
    if (-not [int]::TryParse($roleCountRaw, [ref]$roleCount) -or $roleCount -lt 1) {
        throw "Number of PIM roles must be an integer >= 1"
    }

    foreach ($key in @($envMap.Keys)) {
        if ($key -match '^ROLE_\d+_(NAME|REASON)$') {
            $envMap.Remove($key)
        }
    }

    for ($i = 1; $i -le $roleCount; $i++) {
        $defaultName = if ($existingRoles.Count -ge $i) { $existingRoles[$i - 1].Name } else { "" }
        $defaultReason = if ($existingRoles.Count -ge $i) { $existingRoles[$i - 1].Reason } else { "" }

        $roleName = Prompt-Value -Prompt "Role $i name" -DefaultValue $defaultName -Required
        $roleReason = Prompt-Value -Prompt "Role $i reason" -DefaultValue $(if ([string]::IsNullOrWhiteSpace($defaultReason)) { $roleName } else { $defaultReason }) -Required

        $envMap["ROLE_${i}_NAME"] = $roleName
        $envMap["ROLE_${i}_REASON"] = $roleReason
    }

    Write-EnvFile -Path $EnvPath -EnvMap $envMap
    Write-Host "Saved setup to $EnvPath"

    $script:Bootstrap = $true
    Write-Host "Starting bootstrap login..."
}

function Read-EnvFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    $envMap = @{}
    if (-not (Test-Path -Path $Path)) { return $envMap }

    foreach ($rawLine in Get-Content -Path $Path) {
        $line = $rawLine.Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("#")) { continue }
        $parts = $line.Split("=", 2)
        if ($parts.Count -ne 2) { continue }

        $key = $parts[0].Trim()
        $value = $parts[1].Trim()
        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $envMap[$key] = $value
    }
    return $envMap
}

function Get-ConfigValue {
    param([hashtable]$EnvMap, [string]$Key, [string]$Default = "")
    if ($EnvMap.ContainsKey($Key) -and -not [string]::IsNullOrWhiteSpace($EnvMap[$Key])) { return $EnvMap[$Key] }
    return $Default
}

function Get-ConfigValueFromKeys {
    param([hashtable]$EnvMap, [string[]]$Keys, [string]$Default = "")
    foreach ($key in $Keys) {
        if ($EnvMap.ContainsKey($key) -and -not [string]::IsNullOrWhiteSpace($EnvMap[$key])) {
            return $EnvMap[$key]
        }
    }
    return $Default
}

function Convert-ToUtcDateTime {
    param([object]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return ([datetime]$Value).ToUniversalTime() }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }

    $stylesUtc = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
    [datetime]$parsed = [datetime]::MinValue
    if ([DateTime]::TryParseExact($text, "o", [System.Globalization.CultureInfo]::InvariantCulture, $stylesUtc, [ref]$parsed)) { return $parsed }
    if ([DateTime]::TryParse($text, [System.Globalization.CultureInfo]::InvariantCulture, $stylesUtc, [ref]$parsed)) { return $parsed }
    if ([DateTime]::TryParse($text, [System.Globalization.CultureInfo]::CurrentCulture, [System.Globalization.DateTimeStyles]::AssumeLocal, [ref]$parsed)) { return $parsed.ToUniversalTime() }
    throw "Unable to parse datetime value '$text'."
}

function Convert-ToBoolean {
    param([string]$Value, [bool]$Default)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $Default }
    $v = $Value.Trim().ToLowerInvariant()
    if ($v -in @("1", "true", "yes", "y", "on")) { return $true }
    if ($v -in @("0", "false", "no", "n", "off")) { return $false }
    return $Default
}

function Convert-ToIntOrDefault {
    param([string]$Value, [int]$Default)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $Default }
    $parsed = 0
    if ([int]::TryParse($Value, [ref]$parsed)) { return $parsed }
    return $Default
}

function Get-GraphNextLink {
    param([object]$Response)
    if (-not $Response -or -not $Response.PSObject -or -not $Response.PSObject.Properties) { return $null }
    $next = $Response.PSObject.Properties['@odata.nextLink']
    if ($next) { return [string]$next.Value }
    return $null
}

function Resolve-RoleObjectsFromInput {
    param([object[]]$RolesInput)

    if (-not $RolesInput -or $RolesInput.Count -eq 0) { return @() }

    $expanded = @()
    foreach ($entry in $RolesInput) {
        if ($entry -is [string] -and $entry.Trim().StartsWith("[")) {
            $jsonRoles = $entry | ConvertFrom-Json
            if ($jsonRoles -is [System.Collections.IEnumerable]) {
                foreach ($jsonRole in $jsonRoles) { $expanded += $jsonRole }
            }
            else {
                $expanded += $jsonRoles
            }
        }
        else {
            $expanded += $entry
        }
    }

    $roles = @()
    foreach ($entry in $expanded) {
        $name = $null
        $reason = $null

        if ($entry -is [hashtable]) {
            if ($entry.ContainsKey("name")) { $name = [string]$entry["name"] }
            elseif ($entry.ContainsKey("Name")) { $name = [string]$entry["Name"] }

            if ($entry.ContainsKey("reason")) { $reason = [string]$entry["reason"] }
            elseif ($entry.ContainsKey("Reason")) { $reason = [string]$entry["Reason"] }
        }
        else {
            $propName = $entry.PSObject.Properties["name"]
            if (-not $propName) { $propName = $entry.PSObject.Properties["Name"] }
            $propReason = $entry.PSObject.Properties["reason"]
            if (-not $propReason) { $propReason = $entry.PSObject.Properties["Reason"] }

            if ($propName) { $name = [string]$propName.Value }
            if ($propReason) { $reason = [string]$propReason.Value }
        }

        if ([string]::IsNullOrWhiteSpace($name)) {
            throw "Each role must provide 'name'."
        }

        if ([string]::IsNullOrWhiteSpace($reason)) {
            $reason = $name
        }

        $roles += [PSCustomObject]@{ Name = $name.Trim(); Reason = $reason.Trim() }
    }

    return $roles
}

function Get-RoleConfigsFromEnv {
    param([hashtable]$EnvMap)
    $roles = @()
    $index = 1
    while ($true) {
        $nameKey = "ROLE_${index}_NAME"
        $reasonKey = "ROLE_${index}_REASON"
        if (-not $EnvMap.ContainsKey($nameKey) -or [string]::IsNullOrWhiteSpace($EnvMap[$nameKey])) { break }

        $name = $EnvMap[$nameKey].Trim()
        $reason = (Get-ConfigValue -EnvMap $EnvMap -Key $reasonKey -Default $name).Trim()
        if ([string]::IsNullOrWhiteSpace($reason)) { $reason = $name }

        $roles += [PSCustomObject]@{ Name = $name; Reason = $reason }
        $index++
    }
    return $roles
}

function Invoke-GraphRequest {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("GET", "POST")][string]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$AccessToken,
        [object]$Body = $null
    )

    $headers = @{ Authorization = "Bearer $AccessToken" }
    $attempt = 0
    $maxAttempts = 4

    while ($true) {
        try {
            if ($null -ne $Body) {
                $json = $Body | ConvertTo-Json -Depth 10
                return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers -Body $json -ContentType "application/json" -TimeoutSec 30
            }
            return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers -TimeoutSec 30
        }
        catch {
            $attempt++
            $statusCode = $null
            $details = $null
            if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response -and $_.Exception.Response.PSObject.Properties['StatusCode']) { $statusCode = [int]$_.Exception.Response.StatusCode }
            if ($_.PSObject.Properties['ErrorDetails'] -and $_.ErrorDetails -and $_.ErrorDetails.PSObject.Properties['Message']) { $details = $_.ErrorDetails.Message }

            if ($attempt -lt $maxAttempts -and (($statusCode -eq 429) -or ($statusCode -ge 500 -and $statusCode -lt 600))) {
                $sleepSeconds = [math]::Min(30, [math]::Pow(2, $attempt))
                Write-Log -Level "WARN" -Message "Graph call failed with status $statusCode. Retrying in $sleepSeconds second(s)."
                Start-Sleep -Seconds $sleepSeconds
                continue
            }

            if ($details) { throw "Graph $Method $Uri failed with status $statusCode. Details: $details" }
            throw "Graph $Method $Uri failed with status $statusCode. Error: $($_.Exception.Message)"
        }
    }
}

function Save-TokenCache {
    param([string]$Path, [object]$TokenResponse)
    if (-not $TokenResponse.refresh_token) { return }
    $cache = [PSCustomObject]@{
        access_token = $TokenResponse.access_token
        refresh_token = $TokenResponse.refresh_token
        expires_at_utc = (Get-Date).ToUniversalTime().AddSeconds([int]$TokenResponse.expires_in).ToString("o")
    }
    $cache | ConvertTo-Json | Set-Content -Path $Path
}

function Request-DeviceCodeToken {
    param([string]$TenantId, [string]$ClientId, [string]$TokenCachePath)

    $scope = "https://graph.microsoft.com/.default offline_access openid profile"
    $deviceCodeUri = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/devicecode"
    $tokenUri = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"

    $deviceResponse = Invoke-RestMethod -Method POST -Uri $deviceCodeUri -ContentType "application/x-www-form-urlencoded" -Body @{ client_id = $ClientId; scope = $scope } -TimeoutSec 30
    Write-Log -Message $deviceResponse.message

    $pollInterval = [int]$deviceResponse.interval
    $expiresAt = (Get-Date).AddSeconds([int]$deviceResponse.expires_in)

    while ((Get-Date) -lt $expiresAt) {
        Start-Sleep -Seconds $pollInterval
        try {
            $tokenResponse = Invoke-RestMethod -Method POST -Uri $tokenUri -ContentType "application/x-www-form-urlencoded" -Body @{
                grant_type = "urn:ietf:params:oauth:grant-type:device_code"
                client_id = $ClientId
                device_code = $deviceResponse.device_code
            } -TimeoutSec 30
            Save-TokenCache -Path $TokenCachePath -TokenResponse $tokenResponse
            return $tokenResponse
        }
        catch {
            $detail = if ($_.PSObject.Properties['ErrorDetails'] -and $_.ErrorDetails) { $_.ErrorDetails.Message } else { $null }
            if ($detail -and $detail -match "authorization_pending|slow_down") { continue }
            throw
        }
    }
    throw "Device-code login timed out."
}

function Request-RefreshToken {
    param([string]$TenantId, [string]$ClientId, [string]$RefreshToken, [string]$TokenCachePath)

    $tokenUri = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
    $tokenResponse = Invoke-RestMethod -Method POST -Uri $tokenUri -ContentType "application/x-www-form-urlencoded" -Body @{
        grant_type = "refresh_token"
        client_id = $ClientId
        refresh_token = $RefreshToken
        scope = "https://graph.microsoft.com/.default offline_access openid profile"
    } -TimeoutSec 30
    Save-TokenCache -Path $TokenCachePath -TokenResponse $tokenResponse
    return $tokenResponse
}

function Get-AccessToken {
    param([string]$TenantId, [string]$ClientId, [string]$TokenCachePath, [switch]$AllowInteractive)

    if (Test-Path -Path $TokenCachePath) {
        $cache = Get-Content -Path $TokenCachePath -Raw | ConvertFrom-Json
        $expiresAt = [DateTime]::MinValue
        if ($cache.expires_at_utc) {
            try { $expiresAt = Convert-ToUtcDateTime -Value $cache.expires_at_utc } catch { Write-Log -Level "WARN" -Message "Token cache expiry parse failed. Forcing refresh-token flow." }
        }

        if ($cache.access_token -and $expiresAt -gt (Get-Date).ToUniversalTime().AddMinutes(5)) { return $cache.access_token }

        if ($cache.refresh_token) {
            try {
                $tokenResponse = Request-RefreshToken -TenantId $TenantId -ClientId $ClientId -RefreshToken $cache.refresh_token -TokenCachePath $TokenCachePath
                Write-Log -Message "Refreshed Graph token from local cache."
                return $tokenResponse.access_token
            }
            catch {
                Write-Log -Level "WARN" -Message "Refresh token flow failed: $($_.Exception.Message)"
                if (-not $AllowInteractive) {
                    Send-MacNotification -Message "PIMELIM auth refresh failed. Run 'pwsh ./pimelim.ps1 -Bootstrap' to re-authenticate."
                }
            }
        }
    }

    if (-not $AllowInteractive) { throw "No valid token cache available. Run once with -Bootstrap to complete device login." }
    Write-Log -Message "Starting interactive bootstrap login."
    return (Request-DeviceCodeToken -TenantId $TenantId -ClientId $ClientId -TokenCachePath $TokenCachePath).access_token
}

function Truncate-ToUtcSecond {
    param([datetime]$DateValue)
    return [datetime]::new($DateValue.Year, $DateValue.Month, $DateValue.Day, $DateValue.Hour, $DateValue.Minute, $DateValue.Second, [DateTimeKind]::Utc)
}

function Truncate-ToUtcMinute {
    param([datetime]$DateValue)
    return [datetime]::new($DateValue.Year, $DateValue.Month, $DateValue.Day, $DateValue.Hour, $DateValue.Minute, 0, [DateTimeKind]::Utc)
}

# PIM compares pending request windows at minute granularity with inclusive bounds:
# a new timebound request whose start or end lands in the same wall-clock minute as
# an existing pending request's boundary is rejected with
# OverlapsPendingRoleAssignmentRequests, even with a real gap of up to 59 seconds.
# (Observed empirically: 33s/46s/2s gaps in the same minute rejected; a 60s gap
# crossing a minute boundary accepted.) The helpers below produce boundaries that
# respect both the configured buffer and that minute rule.
function Get-MinuteSafeStartAfter {
    param([datetime]$EndUtc, [int]$BufferSeconds)
    $buffered = $EndUtc.AddSeconds($BufferSeconds)
    $minuteSafe = (Truncate-ToUtcMinute -DateValue $EndUtc).AddMinutes(1)
    if ($buffered -gt $minuteSafe) { return $buffered }
    return $minuteSafe
}

function Get-MinuteSafeEndBefore {
    param([datetime]$StartUtc, [int]$BufferSeconds)
    $buffered = $StartUtc.AddSeconds(-$BufferSeconds)
    $minuteSafe = (Truncate-ToUtcMinute -DateValue $StartUtc).AddSeconds(-1)
    if ($buffered -lt $minuteSafe) { return $buffered }
    return $minuteSafe
}

function Get-PlannedActivationWindows {
    param(
        [Parameter(Mandatory = $true)][datetime]$AnchorUtc,
        [Parameter(Mandatory = $true)][int]$CoverForHours,
        [Parameter(Mandatory = $true)][int]$DurationHours,
        [Parameter(Mandatory = $true)][int]$BufferSeconds,
        [object[]]$ExistingIntervals = @(),
        [int]$MinimumWindowMinutes = 5
    )

    if ($CoverForHours -le 0) { return @() }

    $horizonUtc = $AnchorUtc.AddHours($CoverForHours)

    # Merge existing pending intervals into an ordered, non-overlapping block list.
    $blocks = @()
    foreach ($interval in ($ExistingIntervals | Sort-Object -Property StartUtc)) {
        if ($blocks.Count -gt 0 -and $interval.StartUtc -le $blocks[-1].EndUtc) {
            if ($interval.EndUtc -gt $blocks[-1].EndUtc) { $blocks[-1].EndUtc = $interval.EndUtc }
        }
        else {
            $blocks += [PSCustomObject]@{ StartUtc = $interval.StartUtc; EndUtc = $interval.EndUtc }
        }
    }

    $windows = @()
    $cursorUtc = $AnchorUtc
    $blockIndex = 0

    while ($cursorUtc -lt $horizonUtc) {
        # Skip blocks already behind the cursor, lifting the cursor if it sits
        # too close (same minute / inside buffer) to a block's end boundary.
        while ($blockIndex -lt $blocks.Count -and $blocks[$blockIndex].EndUtc -le $cursorUtc) {
            $safeStart = Get-MinuteSafeStartAfter -EndUtc $blocks[$blockIndex].EndUtc -BufferSeconds $BufferSeconds
            if ($safeStart -gt $cursorUtc) { $cursorUtc = $safeStart }
            $blockIndex++
        }

        # Cursor inside a pending window: that span is already covered, resume after it.
        if ($blockIndex -lt $blocks.Count -and $blocks[$blockIndex].StartUtc -le $cursorUtc) {
            $cursorUtc = Get-MinuteSafeStartAfter -EndUtc $blocks[$blockIndex].EndUtc -BufferSeconds $BufferSeconds
            $blockIndex++
            continue
        }

        # Free slot: bounded by the next pending window (minute-safe), if any.
        $slotEndLimitUtc = $null
        if ($blockIndex -lt $blocks.Count) {
            $slotEndLimitUtc = Get-MinuteSafeEndBefore -StartUtc $blocks[$blockIndex].StartUtc -BufferSeconds $BufferSeconds
        }

        $windowEndUtc = $cursorUtc.AddHours($DurationHours)
        if ($null -ne $slotEndLimitUtc -and $windowEndUtc -gt $slotEndLimitUtc) { $windowEndUtc = $slotEndLimitUtc }

        if (($windowEndUtc - $cursorUtc).TotalMinutes -ge $MinimumWindowMinutes) {
            $windows += [PSCustomObject]@{ StartUtc = $cursorUtc; EndUtc = $windowEndUtc }
            $cursorUtc = Get-MinuteSafeStartAfter -EndUtc $windowEndUtc -BufferSeconds $BufferSeconds
        }
        elseif ($blockIndex -lt $blocks.Count) {
            # Gap too small for a meaningful window: resume after the next pending window.
            $cursorUtc = Get-MinuteSafeStartAfter -EndUtc $blocks[$blockIndex].EndUtc -BufferSeconds $BufferSeconds
            $blockIndex++
        }
        else {
            break
        }
    }

    return $windows
}

function Format-GraphDateTime {
    param([datetime]$DateValue)
    return $DateValue.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
}

function Get-RoleDefinitionByName {
    param([string]$RoleName, [string]$AccessToken)

    $uri = "https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions"
    $matches = @()
    while ($uri) {
        $response = Invoke-GraphRequest -Method GET -Uri $uri -AccessToken $AccessToken
        foreach ($item in $response.value) {
            if ($item.displayName -and $item.displayName.Trim().Equals($RoleName.Trim(), [System.StringComparison]::OrdinalIgnoreCase)) {
                $matches += $item
            }
        }
        $uri = Get-GraphNextLink -Response $response
    }

    if ($matches.Count -eq 0) { throw "Role '$RoleName' not found in tenant role definitions." }
    if ($matches.Count -gt 1) { Write-Log -Level "WARN" -Message "Multiple role definitions matched '$RoleName'. Using first match." }
    return $matches[0]
}

function Try-GetEndTimeFromScheduleInfo {
    param([object]$ScheduleInfo, [datetime]$StartUtc)
    if (-not $ScheduleInfo -or -not $ScheduleInfo.expiration) { return $null }

    $expiration = $ScheduleInfo.expiration
    if ($expiration.endDateTime) { return Convert-ToUtcDateTime -Value $expiration.endDateTime }
    if ($expiration.type -eq "afterDuration" -and $expiration.duration) {
        try { return $StartUtc.Add([System.Xml.XmlConvert]::ToTimeSpan([string]$expiration.duration)) } catch { return $null }
    }
    return $null
}

function Get-ExistingScheduledIntervals {
    param([string]$PrincipalId, [string]$RoleDefinitionId, [string]$AccessToken)

    $nowUtc = (Get-Date).ToUniversalTime()
    $filter = "principalId eq '$PrincipalId' and roleDefinitionId eq '$RoleDefinitionId'"
    $uri = "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignmentScheduleRequests?`$filter=$([uri]::EscapeDataString($filter))"
    $intervals = @()

    while ($uri) {
        $response = Invoke-GraphRequest -Method GET -Uri $uri -AccessToken $AccessToken
        foreach ($item in $response.value) {
            $status = [string]$item.status
            if ($status -match 'Denied|Failed|Canceled|Revoked') { continue }
            if ([string]$item.action -ne 'selfActivate') { continue }

            if ($item.scheduleInfo -and $item.scheduleInfo.startDateTime) {
                # Truncate to whole seconds so interval boundaries align with PIMELIM-created schedule times
                $startUtc = Truncate-ToUtcSecond -DateValue (Convert-ToUtcDateTime -Value $item.scheduleInfo.startDateTime)
                # Only include future-starting requests. Past-started windows are authoritative via
                # the instances API (Get-ActiveRoleAssignmentEndUtc). A past-started request with no
                # corresponding instance is a failed/stuck activation and must not block new scheduling.
                if ($startUtc -le $nowUtc) { continue }
                $endUtc = Try-GetEndTimeFromScheduleInfo -ScheduleInfo $item.scheduleInfo -StartUtc $startUtc
                if ($endUtc -and $endUtc -gt $startUtc) {
                    $intervals += [PSCustomObject]@{ StartUtc = $startUtc; EndUtc = (Truncate-ToUtcSecond -DateValue $endUtc) }
                }
            }
        }
        $uri = Get-GraphNextLink -Response $response
    }
    return $intervals
}

function Get-ActiveRoleAssignmentEndUtc {
    param([string]$PrincipalId, [string]$RoleDefinitionId, [string]$AccessToken, [datetime]$NowUtc)

    $filter = "principalId eq '$PrincipalId' and roleDefinitionId eq '$RoleDefinitionId'"
    $uri = "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignmentScheduleInstances?`$filter=$([uri]::EscapeDataString($filter))"
    $activeEnd = $null

    while ($uri) {
        $response = Invoke-GraphRequest -Method GET -Uri $uri -AccessToken $AccessToken
        foreach ($item in $response.value) {
            if (-not $item.startDateTime -or -not $item.endDateTime) { continue }
            $startUtc = Convert-ToUtcDateTime -Value $item.startDateTime
            $endUtc = Convert-ToUtcDateTime -Value $item.endDateTime

            if ($startUtc -le $NowUtc -and $endUtc -gt $NowUtc) {
                # Truncate to whole seconds so the scheduling anchor aligns with PIMELIM-created windows
                $endUtcTruncated = Truncate-ToUtcSecond -DateValue $endUtc
                if (-not $activeEnd -or $endUtcTruncated -gt $activeEnd) { $activeEnd = $endUtcTruncated }
            }
        }
        $uri = Get-GraphNextLink -Response $response
    }

    return $activeEnd
}

function New-ActivationRequest {
    param([string]$PrincipalId, [string]$RoleDefinitionId, [datetime]$StartUtc, [int]$DurationMinutes, [string]$Reason, [string]$AccessToken, [switch]$IsDryRun)

    $durationIso = if ($DurationMinutes % 60 -eq 0) { "PT$([int]($DurationMinutes / 60))H" } else { "PT${DurationMinutes}M" }
    $body = @{
        action = "selfActivate"
        principalId = $PrincipalId
        roleDefinitionId = $RoleDefinitionId
        directoryScopeId = "/"
        justification = $Reason
        ticketInfo = @{ ticketNumber = "PIMELIM"; ticketSystem = "PIMELIM" }
        scheduleInfo = @{
            startDateTime = (Format-GraphDateTime -DateValue $StartUtc)
            expiration = @{ type = "afterDuration"; duration = $durationIso }
        }
    }

    if ($IsDryRun) {
        Write-Log -Message "[DryRun] Would create selfActivate request for start $(Format-GraphDateTime -DateValue $StartUtc) (duration $durationIso)."
        return
    }

    $uri = "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignmentScheduleRequests"
    $null = Invoke-GraphRequest -Method POST -Uri $uri -AccessToken $AccessToken -Body $body
}

function Test-IsOverlapRequestError {
    param([string]$ErrorMessage)
    if ([string]::IsNullOrWhiteSpace($ErrorMessage)) { return $false }
    # PendingRoleAssignmentRequest (without the Overlaps prefix) is returned when an
    # immediate activation is blocked by a zombie pending request from a failed run.
    return $ErrorMessage -match "PendingRoleAssignmentRequest|overlaps existing role assignment requests"
}

function Get-TenantDisplayName {
    param([string]$AccessToken)
    $response = Invoke-GraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/organization?`$select=displayName,id" -AccessToken $AccessToken
    if ($response.value -and $response.value.Count -gt 0) {
        return [PSCustomObject]@{ DisplayName = $response.value[0].displayName; Id = $response.value[0].id }
    }
    return [PSCustomObject]@{ DisplayName = ""; Id = "" }
}

function Get-AllRoleScheduleInstances {
    param([string]$PrincipalId, [string]$RoleDefinitionId, [string]$AccessToken)

    $nowUtc = (Get-Date).ToUniversalTime()
    $filter = "principalId eq '$PrincipalId' and roleDefinitionId eq '$RoleDefinitionId'"
    $uri = "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignmentScheduleInstances?`$filter=$([uri]::EscapeDataString($filter))"
    $instances = @()

    while ($uri) {
        $response = Invoke-GraphRequest -Method GET -Uri $uri -AccessToken $AccessToken
        foreach ($item in $response.value) {
            if (-not $item.startDateTime -or -not $item.endDateTime) { continue }
            $startUtc = Convert-ToUtcDateTime -Value $item.startDateTime
            $endUtc = Convert-ToUtcDateTime -Value $item.endDateTime
            if ($endUtc -le $nowUtc) { continue }
            $instances += [PSCustomObject]@{ StartUtc = $startUtc; EndUtc = $endUtc }
        }
        $uri = Get-GraphNextLink -Response $response
    }

    return $instances | Sort-Object StartUtc
}

function Format-RemainingTime {
    param([TimeSpan]$Span, [bool]$IsFuture)
    $totalMinutes = [int]$Span.TotalMinutes
    if ($totalMinutes -lt 1) { return ($IsFuture ? "in <1m" : "<1m") }
    $h = [int][Math]::Floor($Span.TotalHours)
    $m = $Span.Minutes
    $formatted = if ($h -gt 0) { "${h}h ${m}m" } else { "${m}m" }
    return ($IsFuture ? "in $formatted" : $formatted)
}

function Show-PimelimStatus {
    $scriptDir = Split-Path -Parent $PSCommandPath
    $envPath = Resolve-PathSafe -BaseDirectory $scriptDir -PathValue $EnvFile
    $envMap = Read-EnvFile -Path $envPath

    $resolvedTenantId = if (-not [string]::IsNullOrWhiteSpace($TenantId)) { $TenantId } else { Get-ConfigValue -EnvMap $envMap -Key "TENANT_ID" }
    $resolvedClientId = if (-not [string]::IsNullOrWhiteSpace($ClientId)) { $ClientId } else { Get-ConfigValue -EnvMap $envMap -Key "CLIENT_ID" }

    if ([string]::IsNullOrWhiteSpace($resolvedTenantId) -or [string]::IsNullOrWhiteSpace($resolvedClientId)) {
        throw "TenantId/ClientId are required. Provide CLI values or TENANT_ID/CLIENT_ID in $envPath"
    }

    $resolvedRoles = if ($null -ne $Roles -and @($Roles).Count -gt 0) {
        Resolve-RoleObjectsFromInput -RolesInput $Roles
    }
    else {
        Get-RoleConfigsFromEnv -EnvMap $envMap
    }

    if (-not $resolvedRoles -or $resolvedRoles.Count -eq 0) {
        throw "No roles configured. Provide -Roles or ROLE_<N>_NAME in $envPath"
    }

    $tokenCachePath = Resolve-PathSafe -BaseDirectory $scriptDir -PathValue ".token-cache.json"
    $accessToken = Get-AccessToken -TenantId $resolvedTenantId -ClientId $resolvedClientId -TokenCachePath $tokenCachePath

    $tenant = Get-TenantDisplayName -AccessToken $accessToken
    $me = Invoke-GraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/me?`$select=id,userPrincipalName" -AccessToken $accessToken
    $principalId = $me.id

    $nowUtc = (Get-Date).ToUniversalTime()
    $rows = @()

    foreach ($role in $resolvedRoles) {
        $roleDef = $null
        try {
            $roleDef = Get-RoleDefinitionByName -RoleName $role.Name -AccessToken $accessToken
        }
        catch {
            Write-Log -Level "WARN" -Message "Role '$($role.Name)' not found: $($_.Exception.Message)"
            $rows += [PSCustomObject]@{ Role = $role.Name; Status = "INACTIVE"; StartUtc = $null; EndUtc = $null }
            continue
        }

        $instances = @(Get-AllRoleScheduleInstances -PrincipalId $principalId -RoleDefinitionId $roleDef.id -AccessToken $accessToken)

        if ($instances.Count -eq 0) {
            $rows += [PSCustomObject]@{ Role = $role.Name; Status = "INACTIVE"; StartUtc = $null; EndUtc = $null }
        }
        else {
            foreach ($inst in $instances) {
                $status = if ($inst.StartUtc -le $nowUtc) { "ACTIVE" } else { "SCHEDULED" }
                $rows += [PSCustomObject]@{ Role = $role.Name; Status = $status; StartUtc = $inst.StartUtc; EndUtc = $inst.EndUtc }
            }
        }
    }

    $tenantDisplay = if (-not [string]::IsNullOrWhiteSpace($tenant.DisplayName)) { $tenant.DisplayName } else { $resolvedTenantId }
    $tenantId = if (-not [string]::IsNullOrWhiteSpace($tenant.Id)) { $tenant.Id } else { $resolvedTenantId }

    Write-Host ""
    Write-Host "Tenant   : $tenantDisplay"
    Write-Host "Tenant ID: $tenantId"
    Write-Host ""

    $colRole = 30
    $colStatus = 9
    $colDt = 20

    $header  = "{0,-$colRole}  {1,-$colStatus}  {2,-$colDt}  {3,-$colDt}  {4}" -f "Role", "Status", "Start (UTC)", "End (UTC)", "Remaining"
    $divider = "{0}  {1}  {2}  {3}  {4}" -f ("-" * $colRole), ("-" * $colStatus), ("-" * $colDt), ("-" * $colDt), ("-" * 9)
    Write-Host $header
    Write-Host $divider

    foreach ($row in $rows) {
        $startStr = if ($row.StartUtc) { $row.StartUtc.ToString("yyyy-MM-dd HH:mm:ss") } else { "-" }
        $endStr   = if ($row.EndUtc)   { $row.EndUtc.ToString("yyyy-MM-dd HH:mm:ss")   } else { "-" }

        $remaining = "-"
        if ($row.Status -eq "ACTIVE" -and $row.EndUtc) {
            $span = $row.EndUtc - $nowUtc
            $remaining = Format-RemainingTime -Span $span -IsFuture $false
        }
        elseif ($row.Status -eq "SCHEDULED" -and $row.StartUtc) {
            $span = $row.StartUtc - $nowUtc
            $remaining = Format-RemainingTime -Span $span -IsFuture $true
        }

        Write-Host ("{0,-$colRole}  {1,-$colStatus}  {2,-$colDt}  {3,-$colDt}  {4}" -f $row.Role, $row.Status, $startStr, $endStr, $remaining)
    }

    Write-Host ""
}

function Invoke-Pimelim {
    $scriptDir = Split-Path -Parent $PSCommandPath
    $envPath = Resolve-PathSafe -BaseDirectory $scriptDir -PathValue $EnvFile
    $envMap = Read-EnvFile -Path $envPath

    $resolvedTenantId = if (-not [string]::IsNullOrWhiteSpace($TenantId)) { $TenantId } else { Get-ConfigValue -EnvMap $envMap -Key "TENANT_ID" }
    $resolvedClientId = if (-not [string]::IsNullOrWhiteSpace($ClientId)) { $ClientId } else { Get-ConfigValue -EnvMap $envMap -Key "CLIENT_ID" }

    if ([string]::IsNullOrWhiteSpace($resolvedTenantId) -or [string]::IsNullOrWhiteSpace($resolvedClientId)) {
        throw "TenantId/ClientId are required. Provide CLI values or TENANT_ID/CLIENT_ID in $envPath"
    }

    $resolvedNow = Convert-ToBoolean -Value $(if (-not [string]::IsNullOrWhiteSpace([string]$Now)) { [string]$Now } else { Get-ConfigValue -EnvMap $envMap -Key "NOW" }) -Default $true

    $resolvedCoverForHours = if ($CoverForHours -ge 0) {
        $CoverForHours
    }
    else {
        Convert-ToIntOrDefault -Value (Get-ConfigValue -EnvMap $envMap -Key "COVER_FOR_HOURS") -Default 36
    }

    $resolvedDurationHours = if ($RoleDurationHours -gt 0) {
        $RoleDurationHours
    }
    else {
        Convert-ToIntOrDefault -Value (Get-ConfigValue -EnvMap $envMap -Key "ACTIVATION_DURATION_HOURS") -Default 8
    }

    $resolvedBufferSeconds = Convert-ToIntOrDefault -Value (Get-ConfigValue -EnvMap $envMap -Key "ACTIVATION_TIME_BUFFER") -Default 60

    if ($resolvedCoverForHours -lt 0 -or $resolvedDurationHours -le 0) {
        throw "CoverForHours must be >= 0 and RoleDurationHours must be > 0."
    }

    $resolvedRoles = if ($null -ne $Roles -and @($Roles).Count -gt 0) {
        Resolve-RoleObjectsFromInput -RolesInput $Roles
    }
    else {
        Get-RoleConfigsFromEnv -EnvMap $envMap
    }

    if (-not $resolvedRoles -or $resolvedRoles.Count -eq 0) {
        throw "No roles configured. Provide -Roles or ROLE_<N>_NAME in $envPath"
    }

    $logPathValue = Get-ConfigValue -EnvMap $envMap -Key "LOG_FILE" -Default "./pimelim.log"
    $script:LogFilePath = Resolve-PathSafe -BaseDirectory $scriptDir -PathValue $logPathValue
    $tokenCachePath = Resolve-PathSafe -BaseDirectory $scriptDir -PathValue ".token-cache.json"

    $allowInteractive = $Bootstrap
    if (-not (Test-Path -Path $tokenCachePath)) {
        if (-not $Bootstrap) {
            Write-Log -Message "No token cache found. Auto-enabling bootstrap device login."
        }
        $allowInteractive = $true
    }

    Write-Log -Message "PIMELIM v$($script:PimelimVersion) started. Roles=$($resolvedRoles.Count), Now=$resolvedNow, CoverForHours=$resolvedCoverForHours, DurationHours=$resolvedDurationHours, BufferSeconds=$resolvedBufferSeconds, DryRun=$DryRun"
    $accessToken = Get-AccessToken -TenantId $resolvedTenantId -ClientId $resolvedClientId -TokenCachePath $tokenCachePath -AllowInteractive:$allowInteractive

    $me = Invoke-GraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/me?`$select=id,userPrincipalName" -AccessToken $accessToken
    $principalId = $me.id
    Write-Log -Message "Using principal: $($me.userPrincipalName) ($principalId)"

    foreach ($role in $resolvedRoles) {
        Write-Log -Message "Processing role '$($role.Name)'"

        $roleNowUtc = Truncate-ToUtcSecond -DateValue (Get-Date).ToUniversalTime()
        $roleDef = Get-RoleDefinitionByName -RoleName $role.Name -AccessToken $accessToken
        $activeEndUtc = Get-ActiveRoleAssignmentEndUtc -PrincipalId $principalId -RoleDefinitionId $roleDef.id -AccessToken $accessToken -NowUtc $roleNowUtc

        if ($activeEndUtc) {
            $anchorUtc = $activeEndUtc
            Write-Log -Message "Role '$($role.Name)' is active until $(Format-GraphDateTime -DateValue $activeEndUtc). Coverage target=$resolvedCoverForHours hour(s)."
        }
        else {
            $anchorUtc = if ($resolvedNow) { $roleNowUtc } else { $roleNowUtc.AddHours($resolvedDurationHours) }
            Write-Log -Message "Role '$($role.Name)' is inactive. Coverage target=$resolvedCoverForHours hour(s) from $(Format-GraphDateTime -DateValue $anchorUtc)."
        }

        if ($resolvedCoverForHours -le 0) {
            Write-Log -Message "Role '$($role.Name)' completed. Created=0 (CoverForHours=0)."
            continue
        }

        # Plan new windows only into uncovered gaps between existing pending requests,
        # keeping every boundary buffer- and minute-safe so Graph never rejects the
        # request as overlapping. Past-started zombie requests are deliberately absent
        # from the intervals (see Get-ExistingScheduledIntervals); if one blocks an
        # immediate activation, Graph is the final arbiter and the create is warn-skipped.
        $existingIntervals = @(Get-ExistingScheduledIntervals -PrincipalId $principalId -RoleDefinitionId $roleDef.id -AccessToken $accessToken)
        $plannedWindows = @(Get-PlannedActivationWindows -AnchorUtc $anchorUtc -CoverForHours $resolvedCoverForHours -DurationHours $resolvedDurationHours -BufferSeconds $resolvedBufferSeconds -ExistingIntervals $existingIntervals)

        if ($plannedWindows.Count -eq 0) {
            Write-Log -Message "Role '$($role.Name)' coverage horizon already filled by $($existingIntervals.Count) pending window(s). Created=0"
            continue
        }

        $created = 0
        $fullWindowMinutes = $resolvedDurationHours * 60
        foreach ($window in $plannedWindows) {
            $durationMinutes = [int][Math]::Floor(($window.EndUtc - $window.StartUtc).TotalMinutes)
            $key = Format-GraphDateTime -DateValue $window.StartUtc

            try {
                New-ActivationRequest -PrincipalId $principalId -RoleDefinitionId $roleDef.id -StartUtc $window.StartUtc -DurationMinutes $durationMinutes -Reason $role.Reason -AccessToken $accessToken -IsDryRun:$DryRun
                $created++
                if ($durationMinutes -lt $fullWindowMinutes) {
                    Write-Log -Message "Scheduled activation at $key for role '$($role.Name)' (clipped to $durationMinutes minute(s) to clear a pending window)."
                }
                else {
                    Write-Log -Message "Scheduled activation at $key for role '$($role.Name)'."
                }
            }
            catch {
                $errMessage = $_.Exception.Message
                if (Test-IsOverlapRequestError -ErrorMessage $errMessage) {
                    Write-Log -Level "WARN" -Message "Skipped overlap for role '$($role.Name)' at $key (reported by Graph on create)."
                    continue
                }

                Write-Log -Level "ERROR" -Message "Failed scheduling $key for role '$($role.Name)': $errMessage"
            }
        }

        Write-Log -Message "Role '$($role.Name)' completed. Created=$created"
    }

    Write-Log -Message "PIMELIM completed."
}

try {
    $scriptDir = Split-Path -Parent $PSCommandPath
    $envPath = Resolve-PathSafe -BaseDirectory $scriptDir -PathValue $EnvFile

    if ($Version) {
        Write-Host "PIMELIM v$($script:PimelimVersion)"
        exit 0
    }

    if ($Help) {
        Show-PimelimHelp
        exit 0
    }

    if ($Setup) {
        Invoke-SetupWizard -ScriptDirectory $scriptDir -EnvPath $envPath
    }

    if ($PSBoundParameters.Count -eq 0 -and -not (Test-Path -Path $envPath)) {
        Show-PimelimHelp
        exit 0
    }

    if ($Status) {
        Show-PimelimStatus
        exit 0
    }

    Invoke-Pimelim
}
catch {
    Write-Log -Level "ERROR" -Message $_.Exception.Message
    exit 1
}
