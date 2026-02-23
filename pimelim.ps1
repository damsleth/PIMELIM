#!/usr/bin/env pwsh

[CmdletBinding()]
param(
    [string]$EnvFile = ".env",
    [switch]$Setup,
    [string]$TenantId,
    [string]$ClientId,
    [string]$Now,
    [object[]]$Roles,
    [int]$ScheduledFutureActivations = -1,
    [int]$RoleDurationHours = -1,
    [switch]$Bootstrap,
    [switch]$DryRun,
    [Alias("h")][switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:LogFilePath = $null

# Workaround: .NET may try IPv6 first for Microsoft endpoints; on networks with
# split-DNS or broken IPv6 routes this causes DNS resolution and connection hangs.
# Must be set as env var before any .NET networking is used (AppContext switch alone
# is insufficient — it doesn't cover DNS resolution on all platforms).
$env:DOTNET_SYSTEM_NET_DISABLEIPV6 = "1"

function Show-PimelimHelp {
    @"
# PIMELIM CLI Help

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
  Fallback: PIM_ROLE_<N>_NAME and PIM_ROLE_<N>_REASON in .env

-ScheduledFutureActivations <int>
  Number of future back-to-back windows to schedule.
  Default: 0
  Fallback: PIM_FUTURE_WINDOWS or SCHEDULED_FUTURE_ACTIVATIONS in .env

-RoleDurationHours <int>
  Activation duration (hours).
  Default: 8
  Fallback: PIM_ACTIVATION_DURATION_HOURS or ROLE_DURATION_HOURS in .env

-Bootstrap
    Forces interactive device-code login if needed.
    If token cache is missing, bootstrap is auto-enabled even without this switch.

-DryRun
  Logs planned requests without creating schedule requests.

-Help
  Prints this guide.

Default behavior:
- If run with no parameters and no .env exists, help is printed.

## Scheduling Behavior
Per role:
- If role is currently active: schedule from active end-time.
- If role is inactive and Now=true: schedule from now.
- If role is inactive and Now=false: schedule only future windows from now + duration.

Window count:
- Active role: ScheduledFutureActivations windows.
- Inactive role + Now=true: 1 immediate + ScheduledFutureActivations future windows.
- Inactive role + Now=false: ScheduledFutureActivations future windows.

Overlap safety:
- Candidate windows that overlap existing non-failed requests are skipped.
- If Graph reports overlap during create, the window is logged as skipped and execution continues.

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
pwsh ./pimelim.ps1 -DryRun -TenantId "<tenant>" -ClientId "<client>" -Now $true -ScheduledFutureActivations 1 -RoleDurationHours 8 -Roles @(@{name="Application Administrator"}, @{name="SharePoint Administrator";reason="SharePoint ops"})

# Dry-run with JSON roles
pwsh ./pimelim.ps1 -DryRun -Now true -ScheduledFutureActivations 1 -Roles '[{"name":"Application Administrator"},{"name":"SharePoint Administrator","reason":"SharePoint ops"}]'

# Future-only scheduling (inactive roles are not activated immediately)
pwsh ./pimelim.ps1 -Now false -ScheduledFutureActivations 2
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
    foreach ($key in @("TENANT_ID", "CLIENT_ID", "NOW", "PIM_FUTURE_WINDOWS", "PIM_ACTIVATION_DURATION_HOURS", "PIM_LOG_FILE")) {
        if ($EnvMap.ContainsKey($key)) {
            $lines.Add("$key=$($EnvMap[$key])")
        }
    }

    $roleIndex = 1
    while ($true) {
        $nameKey = "PIM_ROLE_${roleIndex}_NAME"
        $reasonKey = "PIM_ROLE_${roleIndex}_REASON"
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
            Set-Content -Path $EnvPath -Value "TENANT_ID=`nCLIENT_ID=`nNOW=true`nPIM_FUTURE_WINDOWS=0`nPIM_ACTIVATION_DURATION_HOURS=8`nPIM_LOG_FILE=./pimelim.log`n"
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
    if (-not $envMap.ContainsKey("PIM_FUTURE_WINDOWS")) {
        $envMap["PIM_FUTURE_WINDOWS"] = Get-ConfigValueFromKeys -EnvMap $envMap -Keys @("SCHEDULED_FUTURE_ACTIVATIONS") -Default "0"
    }
    if (-not $envMap.ContainsKey("PIM_ACTIVATION_DURATION_HOURS")) {
        $envMap["PIM_ACTIVATION_DURATION_HOURS"] = Get-ConfigValueFromKeys -EnvMap $envMap -Keys @("ROLE_DURATION_HOURS") -Default "8"
    }
    if (-not $envMap.ContainsKey("PIM_LOG_FILE")) { $envMap["PIM_LOG_FILE"] = "./pimelim.log" }

    $existingRoles = Get-RoleConfigsFromEnv -EnvMap $envMap
    $defaultRoleCount = if ($existingRoles.Count -gt 0) { $existingRoles.Count } else { 1 }
    $roleCountRaw = Prompt-Value -Prompt "Number of PIM roles" -DefaultValue $defaultRoleCount -Required
    $roleCount = 1
    if (-not [int]::TryParse($roleCountRaw, [ref]$roleCount) -or $roleCount -lt 1) {
        throw "Number of PIM roles must be an integer >= 1"
    }

    foreach ($key in @($envMap.Keys)) {
        if ($key -match '^PIM_ROLE_\d+_(NAME|REASON)$') {
            $envMap.Remove($key)
        }
    }

    for ($i = 1; $i -le $roleCount; $i++) {
        $defaultName = if ($existingRoles.Count -ge $i) { $existingRoles[$i - 1].Name } else { "" }
        $defaultReason = if ($existingRoles.Count -ge $i) { $existingRoles[$i - 1].Reason } else { "" }

        $roleName = Prompt-Value -Prompt "Role $i name" -DefaultValue $defaultName -Required
        $roleReason = Prompt-Value -Prompt "Role $i reason" -DefaultValue $(if ([string]::IsNullOrWhiteSpace($defaultReason)) { $roleName } else { $defaultReason }) -Required

        $envMap["PIM_ROLE_${i}_NAME"] = $roleName
        $envMap["PIM_ROLE_${i}_REASON"] = $roleReason
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
        $nameKey = "PIM_ROLE_${index}_NAME"
        $reasonKey = "PIM_ROLE_${index}_REASON"
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
            }
        }
    }

    if (-not $AllowInteractive) { throw "No valid token cache available. Run once with -Bootstrap to complete device login." }
    Write-Log -Message "Starting interactive bootstrap login."
    return (Request-DeviceCodeToken -TenantId $TenantId -ClientId $ClientId -TokenCachePath $TokenCachePath).access_token
}

function Get-DesiredStartTimesFromAnchorUtc {
    param([datetime]$FirstStartUtc, [int]$DurationHours, [int]$WindowCount)
    $starts = @()
    for ($i = 0; $i -lt $WindowCount; $i++) { $starts += $FirstStartUtc.AddHours($i * $DurationHours) }
    return $starts
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

    $filter = "principalId eq '$PrincipalId' and roleDefinitionId eq '$RoleDefinitionId'"
    $uri = "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignmentScheduleRequests?`$filter=$([uri]::EscapeDataString($filter))"
    $intervals = @()

    while ($uri) {
        $response = Invoke-GraphRequest -Method GET -Uri $uri -AccessToken $AccessToken
        foreach ($item in $response.value) {
            $status = [string]$item.status
            if ($status -match 'Denied|Failed|Canceled|Revoked') { continue }
            if ($item.action -and [string]$item.action -ne 'selfActivate') { continue }

            if ($item.scheduleInfo -and $item.scheduleInfo.startDateTime) {
                $startUtc = Convert-ToUtcDateTime -Value $item.scheduleInfo.startDateTime
                $endUtc = Try-GetEndTimeFromScheduleInfo -ScheduleInfo $item.scheduleInfo -StartUtc $startUtc
                if ($endUtc -and $endUtc -gt $startUtc) {
                    $intervals += [PSCustomObject]@{ StartUtc = $startUtc; EndUtc = $endUtc }
                }
            }
        }
        $uri = Get-GraphNextLink -Response $response
    }
    return $intervals
}

function Test-IntervalOverlap {
    param([datetime]$CandidateStartUtc, [datetime]$CandidateEndUtc, [object[]]$ExistingIntervals)
    foreach ($interval in $ExistingIntervals) {
        if ($CandidateStartUtc -lt $interval.EndUtc -and $CandidateEndUtc -gt $interval.StartUtc) { return $true }
    }
    return $false
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
                if (-not $activeEnd -or $endUtc -gt $activeEnd) { $activeEnd = $endUtc }
            }
        }
        $uri = Get-GraphNextLink -Response $response
    }

    return $activeEnd
}

function New-ActivationRequest {
    param([string]$PrincipalId, [string]$RoleDefinitionId, [datetime]$StartUtc, [int]$DurationHours, [string]$Reason, [string]$AccessToken, [switch]$IsDryRun)

    $body = @{
        action = "selfActivate"
        principalId = $PrincipalId
        roleDefinitionId = $RoleDefinitionId
        directoryScopeId = "/"
        justification = $Reason
        ticketInfo = @{ ticketNumber = "PIMELIM"; ticketSystem = "PIMELIM" }
        scheduleInfo = @{
            startDateTime = (Format-GraphDateTime -DateValue $StartUtc)
            expiration = @{ type = "afterDuration"; duration = "PT${DurationHours}H" }
        }
    }

    if ($IsDryRun) {
        Write-Log -Message "[DryRun] Would create selfActivate request for start $(Format-GraphDateTime -DateValue $StartUtc)."
        return
    }

    $uri = "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignmentScheduleRequests"
    $null = Invoke-GraphRequest -Method POST -Uri $uri -AccessToken $AccessToken -Body $body
}

function Test-IsOverlapRequestError {
    param([string]$ErrorMessage)
    if ([string]::IsNullOrWhiteSpace($ErrorMessage)) { return $false }
    return $ErrorMessage -match "OverlapsPendingRoleAssignmentRequests|overlaps existing role assignment requests"
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

    $resolvedFuture = if ($ScheduledFutureActivations -ge 0) {
        $ScheduledFutureActivations
    }
    else {
        Convert-ToIntOrDefault -Value (Get-ConfigValueFromKeys -EnvMap $envMap -Keys @("PIM_FUTURE_WINDOWS", "SCHEDULED_FUTURE_ACTIVATIONS")) -Default 0
    }

    $resolvedDurationHours = if ($RoleDurationHours -gt 0) {
        $RoleDurationHours
    }
    else {
        Convert-ToIntOrDefault -Value (Get-ConfigValueFromKeys -EnvMap $envMap -Keys @("PIM_ACTIVATION_DURATION_HOURS", "ROLE_DURATION_HOURS")) -Default 8
    }

    if ($resolvedFuture -lt 0 -or $resolvedDurationHours -le 0) {
        throw "ScheduledFutureActivations must be >= 0 and RoleDurationHours must be > 0."
    }

    $resolvedRoles = if ($null -ne $Roles -and @($Roles).Count -gt 0) {
        Resolve-RoleObjectsFromInput -RolesInput $Roles
    }
    else {
        Get-RoleConfigsFromEnv -EnvMap $envMap
    }

    if (-not $resolvedRoles -or $resolvedRoles.Count -eq 0) {
        throw "No roles configured. Provide -Roles or PIM_ROLE_<N>_NAME in $envPath"
    }

    $logPathValue = Get-ConfigValue -EnvMap $envMap -Key "PIM_LOG_FILE" -Default "./pimelim.log"
    $script:LogFilePath = Resolve-PathSafe -BaseDirectory $scriptDir -PathValue $logPathValue
    $tokenCachePath = Resolve-PathSafe -BaseDirectory $scriptDir -PathValue ".token-cache.json"

    $allowInteractive = $Bootstrap
    if (-not (Test-Path -Path $tokenCachePath)) {
        if (-not $Bootstrap) {
            Write-Log -Message "No token cache found. Auto-enabling bootstrap device login."
        }
        $allowInteractive = $true
    }

    Write-Log -Message "PIMELIM started. Roles=$($resolvedRoles.Count), Now=$resolvedNow, Future=$resolvedFuture, DurationHours=$resolvedDurationHours, DryRun=$DryRun"
    $accessToken = Get-AccessToken -TenantId $resolvedTenantId -ClientId $resolvedClientId -TokenCachePath $tokenCachePath -AllowInteractive:$allowInteractive

    $me = Invoke-GraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/me?`$select=id,userPrincipalName" -AccessToken $accessToken
    $principalId = $me.id
    Write-Log -Message "Using principal: $($me.userPrincipalName) ($principalId)"

    foreach ($role in $resolvedRoles) {
        Write-Log -Message "Processing role '$($role.Name)'"

        $roleNowUtc = (Get-Date).ToUniversalTime()
        $roleDef = Get-RoleDefinitionByName -RoleName $role.Name -AccessToken $accessToken
        $activeEndUtc = Get-ActiveRoleAssignmentEndUtc -PrincipalId $principalId -RoleDefinitionId $roleDef.id -AccessToken $accessToken -NowUtc $roleNowUtc

        $desiredStartsUtc = @()
        if ($activeEndUtc) {
            $desiredStartsUtc = @(Get-DesiredStartTimesFromAnchorUtc -FirstStartUtc $activeEndUtc -DurationHours $resolvedDurationHours -WindowCount $resolvedFuture)
            Write-Log -Message "Role '$($role.Name)' is active until $(Format-GraphDateTime -DateValue $activeEndUtc). Scheduling $resolvedFuture future window(s)."
        }
        else {
            $windowCount = if ($resolvedNow) { $resolvedFuture + 1 } else { $resolvedFuture }
            if ($windowCount -gt 0) {
                $anchor = if ($resolvedNow) { $roleNowUtc } else { $roleNowUtc.AddHours($resolvedDurationHours) }
                $desiredStartsUtc = @(Get-DesiredStartTimesFromAnchorUtc -FirstStartUtc $anchor -DurationHours $resolvedDurationHours -WindowCount $windowCount)
                Write-Log -Message "Role '$($role.Name)' is inactive. Scheduling $windowCount window(s) from $(Format-GraphDateTime -DateValue $anchor)."
            }
            else {
                Write-Log -Message "Role '$($role.Name)' is inactive. No activation requested (Now=false and ScheduledFutureActivations=0)."
            }
        }

        if (@($desiredStartsUtc).Count -eq 0) {
            Write-Log -Message "Role '$($role.Name)' completed. Created=0"
            continue
        }

        $existingIntervals = @(Get-ExistingScheduledIntervals -PrincipalId $principalId -RoleDefinitionId $roleDef.id -AccessToken $accessToken)

        $created = 0
        foreach ($startUtc in $desiredStartsUtc) {
            $candidateEndUtc = $startUtc.AddHours($resolvedDurationHours)
            $key = Format-GraphDateTime -DateValue $startUtc

            if (Test-IntervalOverlap -CandidateStartUtc $startUtc -CandidateEndUtc $candidateEndUtc -ExistingIntervals $existingIntervals) {
                Write-Log -Message "Skipped overlap for role '$($role.Name)' at $key."
                continue
            }

            try {
                New-ActivationRequest -PrincipalId $principalId -RoleDefinitionId $roleDef.id -StartUtc $startUtc -DurationHours $resolvedDurationHours -Reason $role.Reason -AccessToken $accessToken -IsDryRun:$DryRun
                $created++
                $existingIntervals += [PSCustomObject]@{ StartUtc = $startUtc; EndUtc = $candidateEndUtc }
                Write-Log -Message "Scheduled activation at $key for role '$($role.Name)'."
            }
            catch {
                $errMessage = $_.Exception.Message
                if (Test-IsOverlapRequestError -ErrorMessage $errMessage) {
                    $existingIntervals += [PSCustomObject]@{ StartUtc = $startUtc; EndUtc = $candidateEndUtc }
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

    Invoke-Pimelim
}
catch {
    Write-Log -Level "ERROR" -Message $_.Exception.Message
    exit 1
}
