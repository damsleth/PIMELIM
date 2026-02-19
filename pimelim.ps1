#!/usr/bin/env pwsh

[CmdletBinding()]
param(
    [string]$EnvFile = ".env",
    [switch]$Bootstrap,
    [switch]$DryRun,
    [int]$FutureWindows,
    [int]$DurationHours,
    [string]$Timezone
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:LogFilePath = $null

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
    param(
        [Parameter(Mandatory = $true)][string]$BaseDirectory,
        [Parameter(Mandatory = $true)][string]$PathValue
    )

    if ([System.IO.Path]::IsPathRooted($PathValue)) {
        return [System.IO.Path]::GetFullPath($PathValue)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $BaseDirectory $PathValue))
}

function Read-EnvFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    $envMap = @{}
    if (-not (Test-Path -Path $Path)) {
        return $envMap
    }

    foreach ($rawLine in Get-Content -Path $Path) {
        $line = $rawLine.Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("#")) {
            continue
        }

        $parts = $line.Split("=", 2)
        if ($parts.Count -ne 2) {
            continue
        }

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
    param(
        [hashtable]$EnvMap,
        [string]$Key,
        [string]$Default = ""
    )

    if ($EnvMap.ContainsKey($Key) -and -not [string]::IsNullOrWhiteSpace($EnvMap[$Key])) {
        return $EnvMap[$Key]
    }

    return $Default
}

function Get-RoleConfigs {
    param([hashtable]$EnvMap)

    $roles = @()
    $index = 1

    while ($true) {
        $nameKey = "PIM_ROLE_${index}_NAME"
        $reasonKey = "PIM_ROLE_${index}_REASON"

        if (-not $EnvMap.ContainsKey($nameKey) -or [string]::IsNullOrWhiteSpace($EnvMap[$nameKey])) {
            break
        }

        $roles += [PSCustomObject]@{
            Name = $EnvMap[$nameKey].Trim()
            Reason = (Get-ConfigValue -EnvMap $EnvMap -Key $reasonKey -Default "Scheduled activation by PIMELIM")
        }
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
                return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers -Body $json -ContentType "application/json"
            }

            return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers
        }
        catch {
            $attempt++
            $statusCode = $null
            $details = $null
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
            if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
                $details = $_.ErrorDetails.Message
            }

            if ($attempt -lt $maxAttempts -and (($statusCode -eq 429) -or ($statusCode -ge 500 -and $statusCode -lt 600))) {
                $sleepSeconds = [math]::Min(30, [math]::Pow(2, $attempt))
                Write-Log -Level "WARN" -Message "Graph call failed with status $statusCode. Retrying in $sleepSeconds second(s)."
                Start-Sleep -Seconds $sleepSeconds
                continue
            }

            if ($details) {
                throw "Graph $Method $Uri failed with status $statusCode. Details: $details"
            }

            throw "Graph $Method $Uri failed with status $statusCode. Error: $($_.Exception.Message)"
        }
    }
}

function Get-GraphNextLink {
    param([object]$Response)

    if (-not $Response -or -not $Response.PSObject -or -not $Response.PSObject.Properties) {
        return $null
    }

    $next = $Response.PSObject.Properties['@odata.nextLink']
    if ($next) {
        return [string]$next.Value
    }

    return $null
}

function Convert-ToUtcDateTime {
    param([object]$Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [datetime]) {
        return ([datetime]$Value).ToUniversalTime()
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    $stylesUtc = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
    [datetime]$parsed = [datetime]::MinValue

    if ([DateTime]::TryParseExact($text, "o", [System.Globalization.CultureInfo]::InvariantCulture, $stylesUtc, [ref]$parsed)) {
        return $parsed
    }

    if ([DateTime]::TryParse($text, [System.Globalization.CultureInfo]::InvariantCulture, $stylesUtc, [ref]$parsed)) {
        return $parsed
    }

    if ([DateTime]::TryParse($text, [System.Globalization.CultureInfo]::CurrentCulture, [System.Globalization.DateTimeStyles]::AssumeLocal, [ref]$parsed)) {
        return $parsed.ToUniversalTime()
    }

    throw "Unable to parse datetime value '$text'."
}

function Save-TokenCache {
    param(
        [string]$Path,
        [object]$TokenResponse
    )

    if (-not $TokenResponse.refresh_token) {
        return
    }

    $cache = [PSCustomObject]@{
        access_token = $TokenResponse.access_token
        refresh_token = $TokenResponse.refresh_token
        expires_at_utc = (Get-Date).ToUniversalTime().AddSeconds([int]$TokenResponse.expires_in).ToString("o")
    }

    $cache | ConvertTo-Json | Set-Content -Path $Path
}

function Request-DeviceCodeToken {
    param(
        [Parameter(Mandatory = $true)][string]$TenantId,
        [Parameter(Mandatory = $true)][string]$ClientId,
        [Parameter(Mandatory = $true)][string]$TokenCachePath
    )

    $scope = "https://graph.microsoft.com/.default offline_access openid profile"
    $deviceCodeUri = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/devicecode"
    $tokenUri = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"

    $deviceResponse = Invoke-RestMethod -Method POST -Uri $deviceCodeUri -ContentType "application/x-www-form-urlencoded" -Body @{
        client_id = $ClientId
        scope = $scope
    }

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
            }

            Save-TokenCache -Path $TokenCachePath -TokenResponse $tokenResponse
            return $tokenResponse
        }
        catch {
            $detail = $_.ErrorDetails.Message
            if ($detail -and $detail -match "authorization_pending|slow_down") {
                continue
            }

            throw
        }
    }

    throw "Device-code login timed out."
}

function Request-RefreshToken {
    param(
        [Parameter(Mandatory = $true)][string]$TenantId,
        [Parameter(Mandatory = $true)][string]$ClientId,
        [Parameter(Mandatory = $true)][string]$RefreshToken,
        [Parameter(Mandatory = $true)][string]$TokenCachePath
    )

    $tokenUri = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"

    $tokenResponse = Invoke-RestMethod -Method POST -Uri $tokenUri -ContentType "application/x-www-form-urlencoded" -Body @{
        grant_type = "refresh_token"
        client_id = $ClientId
        refresh_token = $RefreshToken
        scope = "https://graph.microsoft.com/.default offline_access openid profile"
    }

    Save-TokenCache -Path $TokenCachePath -TokenResponse $tokenResponse
    return $tokenResponse
}

function Get-AccessToken {
    param(
        [string]$TenantId,
        [string]$ClientId,
        [string]$TokenCachePath,
        [switch]$AllowInteractive
    )

    if (Test-Path -Path $TokenCachePath) {
        $cache = Get-Content -Path $TokenCachePath -Raw | ConvertFrom-Json
        $expiresAt = [DateTime]::MinValue
        if ($cache.expires_at_utc) {
            $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
            [datetime]$parsed = [datetime]::MinValue

            if ([DateTime]::TryParseExact([string]$cache.expires_at_utc, "o", [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
                $expiresAt = $parsed
            }
            elseif ([DateTime]::TryParse([string]$cache.expires_at_utc, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
                $expiresAt = $parsed
            }
            elseif ([DateTime]::TryParse([string]$cache.expires_at_utc, [System.Globalization.CultureInfo]::CurrentCulture, [System.Globalization.DateTimeStyles]::AssumeLocal, [ref]$parsed)) {
                $expiresAt = $parsed.ToUniversalTime()
            }
        }

        if ($cache.access_token -and $expiresAt -gt (Get-Date).ToUniversalTime().AddMinutes(5)) {
            return $cache.access_token
        }

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

    if (-not $AllowInteractive) {
        throw "No valid token cache available. Run once with -Bootstrap to complete device login."
    }

    Write-Log -Message "Starting interactive bootstrap login."
    $bootstrapToken = Request-DeviceCodeToken -TenantId $TenantId -ClientId $ClientId -TokenCachePath $TokenCachePath
    return $bootstrapToken.access_token
}

function Get-TimezoneAdapter {
    param([string]$TimezoneValue)

    if ([string]::IsNullOrWhiteSpace($TimezoneValue)) {
        $TimezoneValue = "UTC"
    }

    if ($TimezoneValue -match '^UTC([+\-])(\d{1,2})(?::?(\d{2}))?$') {
        $sign = if ($matches[1] -eq "-") { -1 } else { 1 }
        $hours = [int]$matches[2]
        $minutes = if ($matches[3]) { [int]$matches[3] } else { 0 }
        $offset = New-TimeSpan -Hours ($sign * $hours) -Minutes ($sign * $minutes)

        return [PSCustomObject]@{
            Kind = "Offset"
            Offset = $offset
            Name = $TimezoneValue
        }
    }

    try {
        return [PSCustomObject]@{
            Kind = "TimeZoneInfo"
            Value = [System.TimeZoneInfo]::FindSystemTimeZoneById($TimezoneValue)
            Name = $TimezoneValue
        }
    }
    catch {
        throw "Unsupported timezone '$TimezoneValue'. Use UTC, UTC+1, UTC-05:00, or a valid system timezone ID."
    }
}

function Convert-UtcToLocal {
    param($Adapter, [datetime]$UtcDateTime)

    if ($Adapter.Kind -eq "Offset") {
        return [datetimeoffset]::new($UtcDateTime, [timespan]::Zero).ToOffset($Adapter.Offset).DateTime
    }

    return [System.TimeZoneInfo]::ConvertTimeFromUtc($UtcDateTime, $Adapter.Value)
}

function Convert-LocalToUtc {
    param($Adapter, [datetime]$LocalDateTime)

    if ($Adapter.Kind -eq "Offset") {
        $dto = [datetimeoffset]::new($LocalDateTime, $Adapter.Offset)
        return $dto.UtcDateTime
    }

    return [System.TimeZoneInfo]::ConvertTimeToUtc($LocalDateTime, $Adapter.Value)
}

function Get-DesiredStartTimesUtc {
    param(
        [datetime]$NowUtc,
        [int]$DurationHours,
        [int]$FutureWindows
    )
    return Get-DesiredStartTimesFromAnchorUtc -FirstStartUtc $NowUtc -DurationHours $DurationHours -FutureWindows $FutureWindows
}

function Get-DesiredStartTimesFromAnchorUtc {
    param(
        [datetime]$FirstStartUtc,
        [int]$DurationHours,
        [int]$FutureWindows
    )

    $starts = @()
    for ($i = 0; $i -lt $FutureWindows; $i++) {
        $starts += $FirstStartUtc.AddHours($i * $DurationHours)
    }

    return $starts
}

function Format-GraphDateTime {
    param([datetime]$DateValue)
    return $DateValue.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
}

function Get-RoleDefinitionByName {
    param(
        [string]$RoleName,
        [string]$AccessToken
    )

    $uri = "https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions"
    $matches = @()

    while ($uri) {
        $response = Invoke-GraphRequest -Method GET -Uri $uri -AccessToken $AccessToken
        foreach ($item in $response.value) {
            if ($item.displayName -and $item.displayName.Trim().ToLowerInvariant() -eq $RoleName.Trim().ToLowerInvariant()) {
                $matches += $item
            }
        }

        $uri = Get-GraphNextLink -Response $response
    }

    if ($matches.Count -eq 0) {
        throw "Role '$RoleName' not found in tenant role definitions."
    }

    if ($matches.Count -gt 1) {
        Write-Log -Level "WARN" -Message "Multiple role definitions matched '$RoleName'. Using first match."
    }

    return $matches[0]
}

function Try-GetEndTimeFromScheduleInfo {
    param(
        [object]$ScheduleInfo,
        [datetime]$StartUtc
    )

    if (-not $ScheduleInfo -or -not $ScheduleInfo.expiration) {
        return $null
    }

    $expiration = $ScheduleInfo.expiration

    if ($expiration.endDateTime) {
        return Convert-ToUtcDateTime -Value $expiration.endDateTime
    }

    if ($expiration.type -eq "afterDuration" -and $expiration.duration) {
        try {
            $duration = [System.Xml.XmlConvert]::ToTimeSpan([string]$expiration.duration)
            return $StartUtc.Add($duration)
        }
        catch {
            return $null
        }
    }

    return $null
}

function Get-ExistingScheduledIntervals {
    param(
        [string]$PrincipalId,
        [string]$RoleDefinitionId,
        [string]$AccessToken
    )

    $filter = "principalId eq '$PrincipalId' and roleDefinitionId eq '$RoleDefinitionId'"
    $uri = "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignmentScheduleRequests?`$filter=$([uri]::EscapeDataString($filter))"

    $intervals = @()
    $response = Invoke-GraphRequest -Method GET -Uri $uri -AccessToken $AccessToken

    foreach ($item in $response.value) {
        $status = [string]$item.status
        if ($status -match 'Denied|Failed|Canceled|Revoked') {
            continue
        }

        if ($item.action -and [string]$item.action -ne 'selfActivate') {
            continue
        }

        if ($item.scheduleInfo -and $item.scheduleInfo.startDateTime) {
            $utcStart = Convert-ToUtcDateTime -Value $item.scheduleInfo.startDateTime
            $utcEnd = Try-GetEndTimeFromScheduleInfo -ScheduleInfo $item.scheduleInfo -StartUtc $utcStart
            if ($utcEnd -and $utcEnd -gt $utcStart) {
                $intervals += [PSCustomObject]@{
                    StartUtc = $utcStart
                    EndUtc = $utcEnd
                }
            }
        }
    }

    return $intervals
}

function Test-IntervalOverlap {
    param(
        [datetime]$CandidateStartUtc,
        [datetime]$CandidateEndUtc,
        [object[]]$ExistingIntervals
    )

    foreach ($interval in $ExistingIntervals) {
        if ($CandidateStartUtc -lt $interval.EndUtc -and $CandidateEndUtc -gt $interval.StartUtc) {
            return $true
        }
    }

    return $false
}

function Get-ActiveRoleAssignmentEndUtc {
    param(
        [string]$PrincipalId,
        [string]$RoleDefinitionId,
        [string]$AccessToken,
        [datetime]$NowUtc
    )

    $filter = "principalId eq '$PrincipalId' and roleDefinitionId eq '$RoleDefinitionId'"
    $uri = "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignmentScheduleInstances?`$filter=$([uri]::EscapeDataString($filter))"

    $activeEnd = $null
    while ($uri) {
        $response = Invoke-GraphRequest -Method GET -Uri $uri -AccessToken $AccessToken

        foreach ($item in $response.value) {
            if (-not $item.startDateTime -or -not $item.endDateTime) {
                continue
            }

            $startUtc = Convert-ToUtcDateTime -Value $item.startDateTime
            $endUtc = Convert-ToUtcDateTime -Value $item.endDateTime

            if ($startUtc -le $NowUtc -and $endUtc -gt $NowUtc) {
                if (-not $activeEnd -or $endUtc -gt $activeEnd) {
                    $activeEnd = $endUtc
                }
            }
        }

        $uri = Get-GraphNextLink -Response $response
    }

    return $activeEnd
}

function New-ActivationRequest {
    param(
        [string]$PrincipalId,
        [string]$RoleDefinitionId,
        [datetime]$StartUtc,
        [int]$DurationHours,
        [string]$Reason,
        [string]$AccessToken,
        [switch]$IsDryRun
    )

    $body = @{
        action = "selfActivate"
        principalId = $PrincipalId
        roleDefinitionId = $RoleDefinitionId
        directoryScopeId = "/"
        justification = $Reason
        ticketInfo = @{
            ticketNumber = "PIMELIM"
            ticketSystem = "PIMELIM"
        }
        scheduleInfo = @{
            startDateTime = (Format-GraphDateTime -DateValue $StartUtc)
            expiration = @{
                type = "afterDuration"
                duration = "PT${DurationHours}H"
            }
        }
    }

    if ($IsDryRun) {
        Write-Log -Message "[DryRun] Would create selfActivate request for start $(Format-GraphDateTime -DateValue $StartUtc)."
        return
    }

    $uri = "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignmentScheduleRequests"
    $null = Invoke-GraphRequest -Method POST -Uri $uri -AccessToken $AccessToken -Body $body
}

function Invoke-Pimelim {
    $scriptDir = Split-Path -Parent $PSCommandPath
    $envPath = Resolve-PathSafe -BaseDirectory $scriptDir -PathValue $EnvFile
    $envMap = Read-EnvFile -Path $envPath

    $tenantId = Get-ConfigValue -EnvMap $envMap -Key "TENANT_ID"
    $clientId = Get-ConfigValue -EnvMap $envMap -Key "CLIENT_ID"

    if ([string]::IsNullOrWhiteSpace($tenantId) -or [string]::IsNullOrWhiteSpace($clientId)) {
        throw "TENANT_ID and CLIENT_ID must be set in $envPath"
    }

    $duration = if ($PSBoundParameters.ContainsKey("DurationHours") -and $DurationHours -gt 0) {
        $DurationHours
    }
    else {
        [int](Get-ConfigValue -EnvMap $envMap -Key "PIM_ACTIVATION_DURATION_HOURS" -Default "8")
    }

    $futureWindowCount = if ($PSBoundParameters.ContainsKey("FutureWindows") -and $FutureWindows -gt 0) {
        $FutureWindows
    }
    else {
        [int](Get-ConfigValue -EnvMap $envMap -Key "PIM_FUTURE_WINDOWS" -Default "4")
    }

    $timezoneValue = if ($PSBoundParameters.ContainsKey("Timezone") -and -not [string]::IsNullOrWhiteSpace($Timezone)) {
        $Timezone
    }
    else {
        Get-ConfigValue -EnvMap $envMap -Key "PIM_TIMEZONE"
    }

    $logPathValue = Get-ConfigValue -EnvMap $envMap -Key "PIM_LOG_FILE" -Default "./pimelim.log"
    $script:LogFilePath = Resolve-PathSafe -BaseDirectory $scriptDir -PathValue $logPathValue

    $tokenCachePath = Resolve-PathSafe -BaseDirectory $scriptDir -PathValue ".token-cache.json"
    $roles = Get-RoleConfigs -EnvMap $envMap

    if ($roles.Count -eq 0) {
        throw "No roles configured. Add PIM_ROLE_1_NAME/PIM_ROLE_1_REASON in $envPath"
    }

    if ($duration -le 0 -or $futureWindowCount -le 0) {
        throw "PIM_ACTIVATION_DURATION_HOURS and PIM_FUTURE_WINDOWS must be positive integers."
    }

    if (-not [string]::IsNullOrWhiteSpace($timezoneValue)) {
        Write-Log -Level "WARN" -Message "PIM_TIMEZONE is ignored. Scheduling uses rolling windows anchored to now or active end-time."
    }

    Write-Log -Message "PIMELIM started. Roles=$($roles.Count), DurationHours=$duration, FutureWindows=$futureWindowCount, DryRun=$DryRun"
    $accessToken = Get-AccessToken -TenantId $tenantId -ClientId $clientId -TokenCachePath $tokenCachePath -AllowInteractive:$Bootstrap

    $me = Invoke-GraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/me?`$select=id,userPrincipalName" -AccessToken $accessToken
    $principalId = $me.id
    Write-Log -Message "Using principal: $($me.userPrincipalName) ($principalId)"

    $nowUtc = (Get-Date).ToUniversalTime()

    foreach ($role in $roles) {
        Write-Log -Message "Processing role '$($role.Name)'"

        $roleDef = Get-RoleDefinitionByName -RoleName $role.Name -AccessToken $accessToken
        $existingIntervals = Get-ExistingScheduledIntervals -PrincipalId $principalId -RoleDefinitionId $roleDef.id -AccessToken $accessToken
        $activeEndUtc = Get-ActiveRoleAssignmentEndUtc -PrincipalId $principalId -RoleDefinitionId $roleDef.id -AccessToken $accessToken -NowUtc $nowUtc

        $desiredStartsUtc = @()
        if ($activeEndUtc) {
            $desiredStartsUtc = Get-DesiredStartTimesFromAnchorUtc -FirstStartUtc $activeEndUtc -DurationHours $duration -FutureWindows $futureWindowCount
            Write-Log -Message "Role '$($role.Name)' is active until $(Format-GraphDateTime -DateValue $activeEndUtc). Scheduling next windows from active end-time."
        }
        else {
            $roleNowUtc = (Get-Date).ToUniversalTime()
            $desiredStartsUtc = Get-DesiredStartTimesUtc -NowUtc $roleNowUtc -DurationHours $duration -FutureWindows $futureWindowCount
            Write-Log -Message "Role '$($role.Name)' is inactive. Scheduling from now ($(Format-GraphDateTime -DateValue $roleNowUtc))."
        }

        $created = 0
        foreach ($startUtc in $desiredStartsUtc) {
            $candidateEndUtc = $startUtc.AddHours($duration)
            $key = Format-GraphDateTime -DateValue $startUtc
            if (Test-IntervalOverlap -CandidateStartUtc $startUtc -CandidateEndUtc $candidateEndUtc -ExistingIntervals $existingIntervals) {
                Write-Log -Message "Skipped overlap for role '$($role.Name)' at $key."
                continue
            }

            try {
                New-ActivationRequest -PrincipalId $principalId -RoleDefinitionId $roleDef.id -StartUtc $startUtc -DurationHours $duration -Reason $role.Reason -AccessToken $accessToken -IsDryRun:$DryRun
                $created++
                $existingIntervals += [PSCustomObject]@{ StartUtc = $startUtc; EndUtc = $candidateEndUtc }
                Write-Log -Message "Scheduled activation at $key for role '$($role.Name)'."
            }
            catch {
                Write-Log -Level "ERROR" -Message "Failed scheduling $key for role '$($role.Name)': $($_.Exception.Message)"
            }
        }

        Write-Log -Message "Role '$($role.Name)' completed. Created=$created"
    }

    Write-Log -Message "PIMELIM completed."
}

try {
    Invoke-Pimelim
}
catch {
    Write-Log -Level "ERROR" -Message $_.Exception.Message
    exit 1
}
