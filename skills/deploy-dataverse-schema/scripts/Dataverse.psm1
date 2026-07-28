#Requires -Version 7.0
<#
    Dataverse.psm1

    Idempotent Dataverse metadata + record helpers over the Web API, direct
    REST via Invoke-RestMethod - no .NET SDK, no NuGet restore required to use
    this plugin. Mirrors the validated logic from the Tacstone Internal
    Platform's tools/SchemaDeploy C# console tool (Dataverse SDK), translated
    to the Web API equivalents, with the same lessons learned baked in as
    mandatory parameters or hardcoded-correct behavior rather than left as
    advice a caller could skip.

    Design choices that are NOT arbitrary - each traces back to a real failure
    hit while building the Tacstone Internal Platform:

    - Every Ensure*/New-Dataverse* function that creates a component takes a
      MANDATORY -SolutionUniqueName parameter and sends it as the
      MSCRM.SolutionUniqueName request header on every single create call.
      Skipping this is exactly how components silently land in whatever
      solution happens to be the environment's default.
    - Add-DataverseLookup accepts ONLY the three named cascade presets
      (Referential / ReferentialRestrictDelete / Parental) via a ValidateSet,
      never a raw cascade-configuration object a caller could build wrong.
      Referential and Parental differ ONLY in Delete behaviour - Assign,
      Share, Unshare and Reparent are NoCascade for both. Getting this wrong
      (setting those four to Cascade for "Referential") makes Dataverse treat
      the relationship as parental-equivalent, and Dataverse allows at most
      one parental-like relationship per entity - a second lookup created
      that way fails outright with "is parented to X, cannot create another
      parental relation."
    - New-DataverseAlternateKey retries past "already exists" on create, not
      just skips on a pre-check. Alternate key creation is asynchronous
      server-side (background unique-index build), so an existence check run
      immediately after a prior creation can report "not found" for a key
      that is already queued.
    - New-DataverseView checks the intended name against Dataverse's own
      known auto-generated default view name patterns ("Active {Plural}",
      "Inactive {Plural}", "My {Plural}") before creating, and warns loudly
      rather than silently creating nothing. A same-name auto-generated view
      already exists in the environment the moment a table is created; an
      existence check alone cannot tell "my view" from "the platform's view
      that happens to share this name."
    - Set-DataverseFieldSecured must run, and this module enforces it via
      Add-DataverseFieldPermission calling it automatically, before any
      field permission is created - Dataverse rejects a FieldPermission row
      for a column that isn't marked IsSecured=true, and that flag is not
      set implicitly by creating the column as "secured" in some looser sense.
    - Get-DataverseToken tries PAC CLI's own token cache (best-effort,
      UNSUPPORTED - see Get-DataverseTokenFromPacCache), then client secret
      (CI env vars), then Azure CLI, then device code, in that order - never
      reordered. Every provider before device code is silent/non-interactive
      by construction; device code is deliberately last because it's the
      only one that can require a human at a browser - and even then, only
      the first time (see the next bullet).
    - Device-code tokens are cached to disk (DPAPI-protected on Windows) and
      silently refreshed on later runs via the cached refresh token -
      Get-DataverseDeviceCodeAccessToken. Without this, every single script
      run that fell back to device code would force a fresh interactive
      sign-in, which is exactly the friction the "token reuse" safety rule
      already exists to avoid for the az CLI path.
    - A pasted -EnvironmentUrl has no guard against a typo or a copied wrong
      URL by itself. Assert-DataverseEnvironmentAllowed closes that hole,
      opt-in via -AllowedEnvironmentUrls/DATAVERSE_ALLOWED_ENVIRONMENTS, so
      it never changes behavior for a caller who hasn't configured one.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Connection ---------------------------------------------------------------

$script:DataverseContext = $null

function Connect-Dataverse {
    <#
    .SYNOPSIS
        Authenticates against a Dataverse environment and returns a context
        object used by every other function in this module.
    .DESCRIPTION
        Delegates provider selection to Get-DataverseToken - see that
        function for the priority order. The context records which provider
        actually supplied the token (AuthMethod) so Invoke-DataverseApi's
        401 retry knows whether a silent re-call of Get-DataverseToken can
        resolve it, or whether that would require a fresh interactive
        sign-in it shouldn't attempt unattended.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $EnvironmentUrl
    )

    $EnvironmentUrl = $EnvironmentUrl.TrimEnd('/')
    $result = Get-DataverseToken -EnvironmentUrl $EnvironmentUrl

    $script:DataverseContext = [pscustomobject]@{
        EnvironmentUrl = $EnvironmentUrl
        ApiUrl         = "$EnvironmentUrl/api/data/v9.2"
        Token          = $result.Token
        AuthMethod     = $result.Method
    }

    return $script:DataverseContext
}

function Get-DataverseToken {
    <#
    .SYNOPSIS
        Resolves an access token for $EnvironmentUrl from the first
        available provider, in order: PAC CLI's own cache (best-effort,
        unsupported) -> client secret (CI) -> Azure CLI -> device code.
    .DESCRIPTION
        PAC CLI's cache is tried first specifically because this module
        already assumes PAC CLI is in place (it's used for environment
        discovery - see Get-DataverseEnvironmentsFromPac) and, when it
        works, it's the only provider here that requires precisely nothing
        new: no separate az login, no app registration, no interactive
        prompt, just reading a session the user already has. It is NOT an
        officially supported mechanism - see
        Get-DataverseTokenFromPacCache's own remarks - and every failure
        mode there returns $null rather than throwing, so this is purely
        additive: nothing below it changes if it stops working.

        Client secret comes next specifically because its presence - all
        three of DATAVERSE_TENANT_ID/DATAVERSE_CLIENT_ID/
        DATAVERSE_CLIENT_SECRET set - is itself the explicit, deliberate
        signal of "this is unattended/CI, do not attempt anything
        interactive." Azure CLI or a lingering device-code session being
        also present on a CI box is coincidental, not intent, so it must not
        take priority over an explicit configuration. Azure CLI comes next
        because it reuses an existing login with no extra sign-in step -
        the same pattern Microsoft's own power-platform-skills plugins use.
        Device code is the last resort: the only provider that can require a
        human present at a browser, and even then only the first time - see
        Get-DataverseDeviceCodeAccessToken for the persistent cache/refresh
        that avoids repeating that on every later run.
    .OUTPUTS
        [pscustomobject] @{ Token; Method }. Method is one of 'PacCache',
        'ClientSecret', 'AzCli', 'DeviceCodeCached', 'DeviceCodeInteractive'
        - callers deciding whether a 401 can be silently retried should
        treat only DeviceCodeInteractive as requiring a fresh interactive
        sign-in; every other value was obtained without one.
    #>
    param([Parameter(Mandatory)] [string] $EnvironmentUrl)

    $pacCacheToken = Get-DataverseTokenFromPacCache -EnvironmentUrl $EnvironmentUrl
    if ($pacCacheToken) {
        return [pscustomobject]@{ Token = $pacCacheToken; Method = 'PacCache' }
    }

    if ($env:DATAVERSE_TENANT_ID -and $env:DATAVERSE_CLIENT_ID -and $env:DATAVERSE_CLIENT_SECRET) {
        $token = Get-ClientSecretToken -EnvironmentUrl $EnvironmentUrl `
            -TenantId $env:DATAVERSE_TENANT_ID -ClientId $env:DATAVERSE_CLIENT_ID -ClientSecret $env:DATAVERSE_CLIENT_SECRET
        return [pscustomobject]@{ Token = $token; Method = 'ClientSecret' }
    }

    $az = Get-Command az -ErrorAction SilentlyContinue
    if ($az) {
        try {
            $token = (az account get-access-token --resource $EnvironmentUrl --query accessToken -o tsv 2>$null)
            if (-not [string]::IsNullOrWhiteSpace($token)) {
                return [pscustomobject]@{ Token = $token; Method = 'AzCli' }
            }
        }
        catch {
            # Fall through to device code below.
        }
    }

    Write-Host "No PAC CLI cache, client-secret env vars, or Azure CLI token available - falling back to device-code sign-in."
    Write-Host "(Install/login Azure CLI with 'az login' to skip this step next time, or set DATAVERSE_TENANT_ID/DATAVERSE_CLIENT_ID/DATAVERSE_CLIENT_SECRET for unattended use.)"
    return Get-DataverseDeviceCodeAccessToken -EnvironmentUrl $EnvironmentUrl
}

function Get-DataverseTokenFromPacCache {
    <#
    .SYNOPSIS
        UNSUPPORTED, best-effort: reads an access token straight out of PAC
        CLI's own local MSAL token cache, instead of shelling out to `pac`
        (which has no public command to export one - `pac auth`'s
        create/list/select/who subcommands only manage which cached profile
        *other pac commands* use internally, confirmed against Microsoft's
        own CLI reference - there's nothing like `az account get-access-
        token`).
    .DESCRIPTION
        THIS IS NOT AN OFFICIALLY SUPPORTED MECHANISM AND CAN BREAK ON ANY
        PAC CLI UPDATE. It reads a private, undocumented on-disk file -
        %LOCALAPPDATA%\Microsoft\PowerAppsCli\tokencache_msalv3.dat on
        Windows, confirmed present and DPAPI-protected (its first four bytes
        match the standard Windows CRYPTPROTECTDATA blob header) on this
        project's own dev machine - that happens to be how the
        Microsoft.PowerApps.CLI NuGet tool (the actual package behind the
        `pac` command) persists its MSAL token cache today. Unprotects it
        via Windows DPAPI CurrentUser scope: the same OS-level protection
        the cache was written with, decryptable only by the same Windows
        user account that wrote it - which is the account this process
        already runs as. Nothing here decrypts anything this user couldn't
        already decrypt by just running `pac` itself; it only skips needing
        `pac` installed or invoked to reuse a session it already created.

        Every failure path returns $null rather than throwing - wrong OS,
        file missing, DPAPI unprotect failing (a different user account, a
        future cache format change), JSON in an unexpected shape, or no
        access-token entry matching this environment's host and still
        unexpired. Get-DataverseToken treats $null as "try the next
        provider," so client secret / Azure CLI / device code remain a
        working fallback chain regardless of whether this one keeps working
        on a future PAC CLI version. Windows only by construction - DPAPI is
        a Windows API; other OSes fall through immediately.
    #>
    param([Parameter(Mandatory)] [string] $EnvironmentUrl)

    if (-not $IsWindows) { return $null }

    $cachePath = Join-Path $env:LOCALAPPDATA 'Microsoft\PowerAppsCli\tokencache_msalv3.dat'
    if (-not (Test-Path $cachePath)) { return $null }

    try {
        Add-Type -AssemblyName System.Security -ErrorAction Stop
        $protectedBytes = [System.IO.File]::ReadAllBytes($cachePath)

        $plainBytes = $null
        foreach ($scope in @('CurrentUser', 'LocalMachine')) {
            try {
                $plainBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
                    $protectedBytes, $null, [System.Security.Cryptography.DataProtectionScope]::$scope)
                break
            }
            catch {
                continue
            }
        }
        if (-not $plainBytes) { return $null }

        $cache = [System.Text.Encoding]::UTF8.GetString($plainBytes) | ConvertFrom-Json -ErrorAction Stop
        if (-not $cache.AccessToken) { return $null }

        $targetHost = ([Uri]$EnvironmentUrl).Host
        $nowEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

        $candidate = $cache.AccessToken.PSObject.Properties.Value |
            Where-Object { $_.target -and $_.target -like "*$targetHost*" -and [long]$_.expires_on -gt ($nowEpoch + 60) } |
            Sort-Object -Property { [long]$_.expires_on } -Descending |
            Select-Object -First 1

        if (-not $candidate) { return $null }
        return $candidate.secret
    }
    catch {
        return $null
    }
}

function Get-ClientSecretToken {
    <#
    .SYNOPSIS
        Client-credentials OAuth flow for unattended/CI use - no interactive
        sign-in, no Azure CLI dependency.
    .DESCRIPTION
        Requires an application user already provisioned for this app
        registration in the target Dataverse environment - a client secret
        alone only proves identity to Entra ID; Dataverse itself has to
        separately recognize the app as a user with a security role before
        any Web API call succeeds. That provisioning is a one-time
        Dataverse-side setup step, not something this function does.
    #>
    param(
        [Parameter(Mandatory)] [string] $EnvironmentUrl,
        [Parameter(Mandatory)] [string] $TenantId,
        [Parameter(Mandatory)] [string] $ClientId,
        [Parameter(Mandatory)] [string] $ClientSecret
    )

    $response = Invoke-RestMethod -Method Post `
        -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
        -Body @{
            client_id     = $ClientId
            client_secret = $ClientSecret
            scope         = "$EnvironmentUrl/.default"
            grant_type    = 'client_credentials'
        }
    return $response.access_token
}

function Get-DataverseDeviceCodeAccessToken {
    <#
    .SYNOPSIS
        Device-code auth with a persistent, silent-refresh cache - only ever
        falls to an actual interactive sign-in when there's no usable cached
        refresh token for this environment.
    .DESCRIPTION
        Without this, every single run of this module that fell back to
        device code would force a fresh interactive sign-in - the device-
        code equivalent of never reusing az's own cached login, which the
        "token reuse" safety rule already exists to avoid on that path. A
        refresh token from Microsoft's public-client device-code flow is
        long-lived (weeks, not the access token's ~1 hour), so caching it is
        the same trade Azure CLI itself makes for its own cached login.

        The cache file is DPAPI-protected on Windows (CurrentUser scope,
        same mechanism Get-DataverseTokenFromPacCache reads from PAC CLI's
        own cache) since it holds a real, reusable credential. On
        non-Windows it's written in plaintext with a loud one-time warning -
        this module has only been exercised on Windows so far, so that path
        is informational rather than hardened.
    .OUTPUTS
        [pscustomobject] @{ Token; Method }. Method is 'DeviceCodeCached' if
        no interaction was needed this call (a valid cached access token, or
        a successful silent refresh), or 'DeviceCodeInteractive' if the user
        had to complete a fresh device-code sign-in.
    #>
    param([Parameter(Mandatory)] [string] $EnvironmentUrl)

    $nowEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $cached = Get-DataverseDeviceTokenCache -EnvironmentUrl $EnvironmentUrl

    if ($cached -and $cached.expires_on -gt ($nowEpoch + 60)) {
        return [pscustomobject]@{ Token = $cached.access_token; Method = 'DeviceCodeCached' }
    }

    if ($cached -and $cached.refresh_token) {
        $refreshed = Get-DataverseDeviceCodeRefreshedToken -EnvironmentUrl $EnvironmentUrl -RefreshToken $cached.refresh_token
        if ($refreshed) {
            Save-DataverseDeviceTokenCache -EnvironmentUrl $EnvironmentUrl -AccessToken $refreshed.access_token `
                -RefreshToken $refreshed.refresh_token -ExpiresOnEpoch $refreshed.expires_on
            return [pscustomobject]@{ Token = $refreshed.access_token; Method = 'DeviceCodeCached' }
        }
        # Refresh token no longer works (revoked, expired past its own
        # lifetime, tenant policy change) - fall through to a fresh
        # interactive sign-in below rather than throwing.
    }

    $tokenResponse = Get-DeviceCodeToken -EnvironmentUrl $EnvironmentUrl
    Save-DataverseDeviceTokenCache -EnvironmentUrl $EnvironmentUrl -AccessToken $tokenResponse.access_token `
        -RefreshToken $tokenResponse.refresh_token -ExpiresOnEpoch ($nowEpoch + [long]$tokenResponse.expires_in)
    return [pscustomobject]@{ Token = $tokenResponse.access_token; Method = 'DeviceCodeInteractive' }
}

function Get-DeviceCodeToken {
    <#
    .SYNOPSIS
        Device-code OAuth flow when Azure CLI isn't available. Always
        interactive - callers wanting the cache/refresh behavior should call
        Get-DataverseDeviceCodeAccessToken instead, which wraps this.
    .DESCRIPTION
        Uses Microsoft's own public-client app registration for interactive
        Dataverse tooling (the same one documented across official Dataverse
        SDK samples). Prints a URL and a code - the person signing in opens
        their own browser and enters it; no credential passes through this
        process.
    .OUTPUTS
        The full token response object (access_token, refresh_token,
        expires_in, ...) - not just the access token string - so the caller
        can persist the refresh token for later silent reuse.
    #>
    param([Parameter(Mandatory)] [string] $EnvironmentUrl)

    $tenantId = 'organizations'
    $clientId = '51f81489-12ee-4a9e-aaae-a2591f45987d'
    $scope = "$EnvironmentUrl/.default"

    $deviceCodeResponse = Invoke-RestMethod -Method Post `
        -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/devicecode" `
        -Body @{ client_id = $clientId; scope = $scope }

    Write-Host $deviceCodeResponse.message
    Write-Host ""

    $tokenUri = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token"
    $interval = 5
    if ($deviceCodeResponse.interval) { $interval = [int]$deviceCodeResponse.interval }
    $expiresAt = (Get-Date).AddSeconds([int]$deviceCodeResponse.expires_in)

    while ((Get-Date) -lt $expiresAt) {
        Start-Sleep -Seconds $interval
        try {
            $tokenResponse = Invoke-RestMethod -Method Post -Uri $tokenUri -Body @{
                grant_type  = 'urn:ietf:params:oauth:grant-type:device_code'
                client_id   = $clientId
                device_code = $deviceCodeResponse.device_code
            }
            Write-Host "Authenticated."
            return $tokenResponse
        }
        catch {
            $errorBody = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($errorBody.error -eq 'authorization_pending') { continue }
            throw
        }
    }

    throw "Device code sign-in timed out."
}

function Get-DataverseDeviceCodeRefreshedToken {
    <#
    .SYNOPSIS
        Silently exchanges a cached refresh token for a new access token -
        the mechanism that lets a device-code session survive across
        separate runs of this module without a fresh interactive sign-in
        every time.
    .DESCRIPTION
        Returns $null (never throws) on any failure - an expired, revoked,
        or policy-invalidated refresh token is an expected, recoverable
        case, not an error: the caller falls back to a fresh interactive
        device-code sign-in when this returns nothing.
    #>
    param(
        [Parameter(Mandatory)] [string] $EnvironmentUrl,
        [Parameter(Mandatory)] [string] $RefreshToken
    )

    $clientId = '51f81489-12ee-4a9e-aaae-a2591f45987d'
    try {
        $response = Invoke-RestMethod -Method Post `
            -Uri "https://login.microsoftonline.com/organizations/oauth2/v2.0/token" `
            -Body @{
                grant_type    = 'refresh_token'
                client_id     = $clientId
                refresh_token = $RefreshToken
                scope         = "$EnvironmentUrl/.default"
            }
        return @{
            access_token  = $response.access_token
            refresh_token = if ($response.refresh_token) { $response.refresh_token } else { $RefreshToken }
            expires_on    = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + [long]$response.expires_in
        }
    }
    catch {
        return $null
    }
}

function Get-DataverseDeviceTokenCachePath {
    param([Parameter(Mandatory)] [string] $EnvironmentUrl)

    $targetHost = ([Uri]$EnvironmentUrl).Host
    $dir = if ($IsWindows) {
        Join-Path $env:LOCALAPPDATA 'dataverse-schema-architect\device-token-cache'
    }
    else {
        Join-Path $HOME '.dataverse-schema-architect/device-token-cache'
    }
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return Join-Path $dir "$targetHost.json"
}

function Save-DataverseDeviceTokenCache {
    <#
    .SYNOPSIS
        Persists a device-code access + refresh token to disk so a later
        run of this module can refresh silently instead of prompting for a
        fresh interactive sign-in every time.
    .DESCRIPTION
        DPAPI CurrentUser-protected on Windows before being written to disk
        - the refresh token this file holds is a real, long-lived
        credential, not something to leave in plaintext. On non-Windows,
        written in plaintext with a loud one-time warning.
    #>
    param(
        [Parameter(Mandatory)] [string] $EnvironmentUrl,
        [Parameter(Mandatory)] [string] $AccessToken,
        [string] $RefreshToken,
        [Parameter(Mandatory)] [long] $ExpiresOnEpoch
    )

    $path = Get-DataverseDeviceTokenCachePath -EnvironmentUrl $EnvironmentUrl
    $payload = @{ access_token = $AccessToken; refresh_token = $RefreshToken; expires_on = $ExpiresOnEpoch } | ConvertTo-Json -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)

    if ($IsWindows) {
        Add-Type -AssemblyName System.Security
        $protectedBytes = [System.Security.Cryptography.ProtectedData]::Protect(
            $bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        [System.IO.File]::WriteAllBytes($path, $protectedBytes)
    }
    else {
        Write-Warning "Storing the device-code refresh token in plaintext at $path - this module's persistent auth cache is only DPAPI-protected on Windows."
        [System.IO.File]::WriteAllBytes($path, $bytes)
    }
}

function Get-DataverseDeviceTokenCache {
    <#
    .SYNOPSIS
        Reads back what Save-DataverseDeviceTokenCache wrote, or $null if
        there's nothing cached yet, the file is unreadable, or (Windows)
        DPAPI can't unprotect it - e.g. a different Windows user account.
        Never throws.
    #>
    param([Parameter(Mandatory)] [string] $EnvironmentUrl)

    $path = Get-DataverseDeviceTokenCachePath -EnvironmentUrl $EnvironmentUrl
    if (-not (Test-Path $path)) { return $null }

    try {
        $bytes = [System.IO.File]::ReadAllBytes($path)
        if ($IsWindows) {
            Add-Type -AssemblyName System.Security
            $plainBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
                $bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
            return [System.Text.Encoding]::UTF8.GetString($plainBytes) | ConvertFrom-Json -ErrorAction Stop
        }
        return [System.Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return $null
    }
}

# --- Environment discovery -----------------------------------------------------

function Get-DataverseEnvironmentsFromPac {
    <#
    .SYNOPSIS
        Best-effort discovery of Dataverse environments already known to
        this machine's PAC CLI auth cache, via `pac auth list --json`.
    .DESCRIPTION
        Returns $null - never throws - if `pac` isn't installed, isn't
        logged into anything, or its --json output doesn't parse cleanly.
        Discovery is a convenience layered on top of the existing
        -EnvironmentUrl parameter, never a hard requirement to use this
        module: nothing here should turn "PAC CLI isn't set up" into a
        harder failure than just asking for -EnvironmentUrl directly.
        PAC CLI's own JSON property naming for the org/environment URL has
        varied across versions - this tries several candidate property
        names rather than assuming one.
    #>
    $pac = Get-Command pac -ErrorAction SilentlyContinue
    if (-not $pac) { return $null }

    try {
        $raw = pac auth list --json 2>$null
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        $profiles = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return $null
    }
    if (-not $profiles) { return $null }

    $result = foreach ($p in $profiles) {
        $url = $p.EnvironmentUrl
        if (-not $url) { $url = $p.Resource }
        if (-not $url) { $url = $p.Environment }
        if (-not $url) { continue }
        [pscustomobject]@{
            Name           = $p.Name
            EnvironmentUrl = $url.TrimEnd('/')
            IsActive       = [bool]$p.Active
        }
    }
    return $result
}

function Resolve-DataverseEnvironmentUrl {
    <#
    .SYNOPSIS
        Resolves the target environment URL for a deploy: an explicit
        -EnvironmentUrl always wins; otherwise falls back to whichever
        single environment PAC CLI's own auth cache reports.
    .DESCRIPTION
        Deliberately does not guess when discovery turns up more than one
        candidate and none is marked active in PAC CLI - environment choice
        is exactly the kind of mistake this module's allowlist guard
        (Assert-DataverseEnvironmentAllowed) also exists to catch, so an
        ambiguous discovery result fails loudly with the candidate list
        rather than silently picking one.
    #>
    param([string] $EnvironmentUrl)

    if ($EnvironmentUrl) { return $EnvironmentUrl.TrimEnd('/') }

    $discovered = Get-DataverseEnvironmentsFromPac
    if (-not $discovered -or @($discovered).Count -eq 0) {
        throw "No -EnvironmentUrl given and no environments discoverable via 'pac auth list'. Pass -EnvironmentUrl explicitly, or run 'pac auth create --url <environment-url>' first."
    }
    $discovered = @($discovered)

    $active = @($discovered | Where-Object { $_.IsActive })
    if ($active.Count -eq 1) {
        Write-Host "No -EnvironmentUrl given - using PAC CLI's active auth profile: $($active[0].EnvironmentUrl) ($($active[0].Name))"
        return $active[0].EnvironmentUrl
    }
    if ($discovered.Count -eq 1) {
        Write-Host "No -EnvironmentUrl given - using the only environment PAC CLI knows about: $($discovered[0].EnvironmentUrl)"
        return $discovered[0].EnvironmentUrl
    }

    $list = ($discovered | ForEach-Object { "  - $($_.EnvironmentUrl) ($($_.Name))" }) -join "`n"
    throw "No -EnvironmentUrl given and PAC CLI reports $($discovered.Count) environments with none marked active:`n$list`nPass -EnvironmentUrl explicitly to disambiguate."
}

# --- Environment allowlist / prod guard -----------------------------------------

function Assert-DataverseEnvironmentAllowed {
    <#
    .SYNOPSIS
        Refuses to proceed against an environment URL that doesn't match a
        configured allowlist, unless explicitly overridden.
    .DESCRIPTION
        Opt-in, not a mandatory gate: an unset allowlist blocks nothing, so
        this is fully backward compatible for anyone deploying to a single
        environment today. Configure it via -AllowedEnvironmentUrls or the
        DATAVERSE_ALLOWED_ENVIRONMENTS environment variable (semicolon-
        separated URLs), matched on host only (scheme/trailing-slash
        differences don't matter). -Force bypasses the check entirely, for
        the deliberate "yes, I know, deploy anyway" case - the free-text
        pasted -EnvironmentUrl this module has always accepted is otherwise
        a genuine prod-safety hole with no guard against a typo or a copied
        wrong URL landing real writes in the wrong environment.
    #>
    param(
        [Parameter(Mandatory)] [string] $EnvironmentUrl,
        [string[]] $AllowedEnvironmentUrls,
        [switch] $Force
    )

    if ($Force) { return }

    $allowlist = $AllowedEnvironmentUrls
    if ((-not $allowlist -or $allowlist.Count -eq 0) -and $env:DATAVERSE_ALLOWED_ENVIRONMENTS) {
        $allowlist = $env:DATAVERSE_ALLOWED_ENVIRONMENTS -split ';' | Where-Object { $_ }
    }
    if (-not $allowlist -or $allowlist.Count -eq 0) { return }

    $targetHost = ([Uri]$EnvironmentUrl).Host.ToLowerInvariant()
    $allowedHosts = $allowlist | ForEach-Object { ([Uri]$_.Trim()).Host.ToLowerInvariant() }

    if ($targetHost -notin $allowedHosts) {
        throw "Refusing to deploy to '$EnvironmentUrl' - its host does not match the configured allowlist ($($allowedHosts -join ', ')). Pass -Force to override, or add it to -AllowedEnvironmentUrls / DATAVERSE_ALLOWED_ENVIRONMENTS if this is intentional."
    }
}

# --- Core REST plumbing --------------------------------------------------------

function Invoke-DataverseApi {
    <#
    .SYNOPSIS
        Thin wrapper over Invoke-RestMethod with Dataverse's required headers.
    .PARAMETER SolutionUniqueName
        When set, sent as the MSCRM.SolutionUniqueName header - the Web API
        mechanism that pins a created component to a specific solution
        regardless of the environment's default solution. Every function in
        this module that creates something requires this from its own
        caller; this parameter is how it actually reaches the request.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('Get', 'Post', 'Patch', 'Put', 'Delete')] [string] $Method,
        [Parameter(Mandatory)] [string] $Path,
        $Body,
        [string] $SolutionUniqueName,
        [switch] $SuppressNotFoundError
    )

    if (-not $script:DataverseContext) {
        throw "Not connected. Call Connect-Dataverse first."
    }

    $headers = @{
        Authorization     = "Bearer $($script:DataverseContext.Token)"
        'OData-MaxVersion' = '4.0'
        'OData-Version'    = '4.0'
        Accept            = 'application/json'
    }
    if ($SolutionUniqueName) {
        $headers['MSCRM.SolutionUniqueName'] = $SolutionUniqueName
    }

    $uri = "$($script:DataverseContext.ApiUrl)/$Path"
    $params = @{
        Method  = $Method
        Uri     = $uri
        Headers = $headers
    }
    if ($Body) {
        $params.ContentType = 'application/json'
        $params.Body = ($Body | ConvertTo-Json -Depth 20)
    }

    try {
        return Invoke-RestMethod @params
    }
    catch {
        # $_.Exception.Response only exists on an HTTP-status-level failure
        # (a real 4xx/5xx from Dataverse). A connection-level failure - DNS
        # resolution, connection refused, TLS, timeout - throws a different
        # exception type (typically HttpRequestException) with no Response
        # property at all, and under this module's strict mode, dot-access
        # to a genuinely absent property throws "cannot be found on this
        # object" instead of returning $null - masking the real, actually
        # useful underlying error (e.g. "could not resolve host") behind a
        # confusing unrelated one. Index into PSObject.Properties instead,
        # same pattern as the nextLink handling above, so $status stays
        # $null for a connection-level failure and falls through to the
        # bare `throw` below, which re-raises the original exception intact.
        $responseProp = $_.Exception.PSObject.Properties['Response']
        $status = if ($responseProp -and $responseProp.Value) { $responseProp.Value.StatusCode.value__ } else { $null }
        if ($status -eq 404 -and $SuppressNotFoundError) {
            return $null
        }
        $silentlyRetryableAuthMethods = @('PacCache', 'ClientSecret', 'AzCli', 'DeviceCodeCached')
        if ($status -eq 401 -and $script:DataverseContext.AuthMethod -in $silentlyRetryableAuthMethods) {
            # Token expired mid-run - every method except DeviceCodeInteractive
            # can re-authenticate without a human present (DeviceCodeCached
            # included, since Get-DataverseDeviceCodeAccessToken's own cache/
            # refresh is itself silent), so just re-call Get-DataverseToken
            # via Connect-Dataverse and retry once. DeviceCodeInteractive is
            # excluded: retrying it would mean prompting for a fresh
            # interactive sign-in mid-deploy, which this module never does
            # on its own.
            Connect-Dataverse -EnvironmentUrl $script:DataverseContext.EnvironmentUrl | Out-Null
            $headers.Authorization = "Bearer $($script:DataverseContext.Token)"
            $params.Headers = $headers
            return Invoke-RestMethod @params
        }
        throw
    }
}

function Test-DataverseNotFound {
    <#
    .SYNOPSIS
        True when a collection-query response (savedqueries, roles,
        fieldsecurityprofiles, fieldpermissions - anything checked via
        $filter=... rather than a by-key metadata GET) matched nothing.
    .DESCRIPTION
        A "no rows match" $filter query returns HTTP 200 with an empty
        value array, not a 404 - so this cannot just check $null (that
        pattern is Test-DataverseTable/Column/Relationship's job, which
        query by key and genuinely 404 instead). The bug this fixes: an
        empty PowerShell array is falsy, so "$Response.value -and
        $Response.value.Count -eq 0" short-circuited on the array itself
        before ever reaching -eq 0, making every zero-match response
        register as "found". That silently no-op'd every view, security
        role and field permission this module ever tried to create -
        caught only by independently re-querying after a "skip" and
        finding nothing there.
    #>
    param($Response)
    if ($null -eq $Response -or $null -eq $Response.value) { return $true }
    return $Response.value.Count -eq 0
}

# --- Cascade presets ------------------------------------------------------------
# Named presets only - see the module header remark on why raw cascade
# configuration objects are not an option this module exposes.

$script:CascadePresets = @{
    Referential = @{
        '@odata.type' = 'Microsoft.Dynamics.CRM.CascadeConfiguration'
        Assign = 'NoCascade'; Share = 'NoCascade'; Unshare = 'NoCascade'
        Reparent = 'NoCascade'; Delete = 'RemoveLink'; Merge = 'Cascade'
    }
    ReferentialRestrictDelete = @{
        '@odata.type' = 'Microsoft.Dynamics.CRM.CascadeConfiguration'
        Assign = 'NoCascade'; Share = 'NoCascade'; Unshare = 'NoCascade'
        Reparent = 'NoCascade'; Delete = 'Restrict'; Merge = 'Cascade'
    }
    Parental = @{
        '@odata.type' = 'Microsoft.Dynamics.CRM.CascadeConfiguration'
        Assign = 'Cascade'; Share = 'Cascade'; Unshare = 'Cascade'
        Reparent = 'Cascade'; Delete = 'Cascade'; Merge = 'Cascade'
    }
}

# --- Drift detection ------------------------------------------------------------
# Maps this module's -Type values to Dataverse's own AttributeTypeName.Value
# strings, confirmed against Microsoft's column-type reference table before
# writing this (not guessed) - DateOnly and DateTime both map to DateTimeType
# since Dataverse doesn't distinguish them at this level; the difference is
# DateTimeBehavior, a separate property Test-DataverseColumnDrift does not
# compare.

$script:ExpectedAttributeTypeName = @{
    String   = 'StringType'
    Memo     = 'MemoType'
    Integer  = 'IntegerType'
    Decimal  = 'DecimalType'
    Money    = 'MoneyType'
    DateOnly = 'DateTimeType'
    DateTime = 'DateTimeType'
    Image    = 'ImageType'
    File     = 'FileType'
    Boolean  = 'BooleanType'
    Choice   = 'PicklistType'
}

function Test-DataverseColumnDrift {
    <#
    .SYNOPSIS
        Warns (never throws, never blocks) when an existing column's live
        Dataverse type doesn't match what the spec asks for.
    .DESCRIPTION
        Create-if-missing means a wrong-typed existing column is otherwise
        left silently wrong forever - this module never alters an existing
        column's type (that's a deliberate migration a human should decide
        on, not something to do implicitly on a routine re-run), so the most
        this function can respectably do is surface the mismatch loudly
        rather than let the "skip" log line look like everything matched.
        Every failure path (the read call itself failing, an unmapped
        -Type, a live type this module doesn't recognize) returns quietly
        rather than raising a false positive - an unverifiable comparison is
        reported as nothing, not as drift.
    #>
    param(
        [Parameter(Mandatory)] [string] $EntityLogicalName,
        [Parameter(Mandatory)] [string] $AttributeLogicalName,
        [Parameter(Mandatory)] [string] $ExpectedType
    )

    $expectedTypeName = $script:ExpectedAttributeTypeName[$ExpectedType]
    if (-not $expectedTypeName) { return }

    $live = Invoke-DataverseApi -Method Get `
        -Path "EntityDefinitions(LogicalName='$EntityLogicalName')/Attributes(LogicalName='$AttributeLogicalName')?`$select=AttributeTypeName" `
        -SuppressNotFoundError
    if (-not $live -or -not $live.AttributeTypeName -or -not $live.AttributeTypeName.Value) { return }

    $liveTypeName = $live.AttributeTypeName.Value
    if ($liveTypeName -ne $expectedTypeName) {
        Write-Warning "  drift  $EntityLogicalName.$AttributeLogicalName - spec asks for -Type $ExpectedType ($expectedTypeName), live column is $liveTypeName. This module never changes an existing column's type; a mismatch needs a deliberate migration, not a silent skip."
    }
}

# --- Global choices -------------------------------------------------------------

function Test-DataverseGlobalChoice {
    param([Parameter(Mandatory)] [string] $Name)
    $result = Invoke-DataverseApi -Method Get -Path "GlobalOptionSetDefinitions(Name='$Name')?`$select=Name" -SuppressNotFoundError
    return $null -ne $result
}

function Get-DataverseGlobalChoiceId {
    <#
    .SYNOPSIS
        Resolves a global choice's MetadataId from its name.
    .DESCRIPTION
        Used instead of binding a new Picklist attribute's GlobalOptionSet
        navigation property via the Name-based alternate-key form
        (GlobalOptionSetDefinitions(Name='...')) in an @odata.bind annotation.
        Microsoft's own Web API docs list that form as valid, but it failed
        outright against a real environment with "Guid should contain 32
        digits with 4 dashes" - whatever the exact cause, resolving the real
        MetadataId first and binding to that (the form the same docs present
        as primary) sidesteps the ambiguity entirely rather than trusting an
        alternate-key path that didn't work in practice.
    #>
    param([Parameter(Mandatory)] [string] $Name)
    $result = Invoke-DataverseApi -Method Get -Path "GlobalOptionSetDefinitions(Name='$Name')?`$select=MetadataId"
    return $result.MetadataId
}

function New-DataverseGlobalChoice {
    <#
    .SYNOPSIS
        Idempotent global choice (option set) creation.
    .DESCRIPTION
        The recommended path for a Choice column in this module - see
        Add-DataverseColumn's -LocalOptions for the alternative used only
        when a local picklist was specifically requested. Values are
        supplied explicitly by the caller and must be sequential from
        100000000 by this module's own convention (not enforced here, since
        a caller might legitimately import an existing numbering scheme, but
        strongly recommended in the design skill: never rely on the
        publisher's auto-derived value prefix, which produces unpredictable
        numbers if the choice is ever recreated in a different environment).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $DisplayName,
        [Parameter(Mandatory)] [hashtable[]] $Options,  # @{ Value = 100000000; Label = "Employee" }
        [Parameter(Mandatory)] [string] $SolutionUniqueName,
        [int] $LanguageCode = 1033
    )

    if (Test-DataverseGlobalChoice -Name $Name) {
        Write-Host "  skip   global choice $Name"
        return
    }

    $body = @{
        '@odata.type' = 'Microsoft.Dynamics.CRM.OptionSetMetadata'
        Name          = $Name
        IsGlobal      = $true
        OptionSetType = 'Picklist'
        DisplayName   = @{ LocalizedLabels = @(@{ Label = $DisplayName; LanguageCode = $LanguageCode }) }
        Options       = $Options | ForEach-Object {
            @{
                Value       = $_.Value
                Label       = @{ LocalizedLabels = @(@{ Label = $_.Label; LanguageCode = $LanguageCode }) }
            }
        }
    }

    Invoke-DataverseApi -Method Post -Path 'GlobalOptionSetDefinitions' -Body $body -SolutionUniqueName $SolutionUniqueName | Out-Null
    Write-Host "  create global choice $Name ($($Options.Count) options)"
}

# --- Tables ---------------------------------------------------------------------

function Test-DataverseTable {
    param([Parameter(Mandatory)] [string] $LogicalName)
    $result = Invoke-DataverseApi -Method Get -Path "EntityDefinitions(LogicalName='$LogicalName')?`$select=LogicalName" -SuppressNotFoundError
    return $null -ne $result
}

function New-DataverseTable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $LogicalName,
        [Parameter(Mandatory)] [string] $DisplayName,
        [Parameter(Mandatory)] [string] $PluralDisplayName,
        [Parameter(Mandatory)] [string] $Description,
        [Parameter(Mandatory)] [ValidateSet('UserOwned', 'OrganizationOwned')] [string] $Ownership,
        [Parameter(Mandatory)] [string] $PrimaryAttributeSchemaName,
        [Parameter(Mandatory)] [string] $PrimaryAttributeDisplayName,
        [int] $PrimaryAttributeMaxLength = 300,
        [string] $PrimaryAttributeAutoNumberFormat,
        [Parameter(Mandatory)] [string] $SolutionUniqueName,
        [int] $LanguageCode = 1033
    )

    if (Test-DataverseTable -LogicalName $LogicalName) {
        Write-Host "  skip   table $LogicalName"
        return
    }

    $label = { param($t) @{ LocalizedLabels = @(@{ Label = $t; LanguageCode = $LanguageCode }) } }

    $primaryAttribute = @{
        '@odata.type'  = 'Microsoft.Dynamics.CRM.StringAttributeMetadata'
        SchemaName     = $PrimaryAttributeSchemaName
        DisplayName    = (& $label $PrimaryAttributeDisplayName)
        RequiredLevel  = @{ Value = 'ApplicationRequired' }
        MaxLength      = $PrimaryAttributeMaxLength
        IsPrimaryName  = $true
    }
    if ($PrimaryAttributeAutoNumberFormat) {
        # Primary name column can be autonumbered directly - e.g. a quote or
        # project number like QUO-00001. Requires ApplicationRequired here
        # regardless, since Dataverse still needs a RequiredLevel on the
        # primary name even though the value gets generated automatically.
        $primaryAttribute.AutoNumberFormat = $PrimaryAttributeAutoNumberFormat
    }

    $body = @{
        '@odata.type'          = 'Microsoft.Dynamics.CRM.EntityMetadata'
        SchemaName             = $LogicalName
        DisplayName            = (& $label $DisplayName)
        DisplayCollectionName  = (& $label $PluralDisplayName)
        Description            = (& $label $Description)
        OwnershipType          = $Ownership
        HasActivities          = $false
        HasNotes               = $false
        Attributes             = @($primaryAttribute)
    }

    Invoke-DataverseApi -Method Post -Path 'EntityDefinitions' -Body $body -SolutionUniqueName $SolutionUniqueName | Out-Null
    Write-Host "  create table $LogicalName"
}

# --- Columns ---------------------------------------------------------------------

function Test-DataverseColumn {
    param([Parameter(Mandatory)] [string] $EntityLogicalName, [Parameter(Mandatory)] [string] $AttributeLogicalName)
    $result = Invoke-DataverseApi -Method Get `
        -Path "EntityDefinitions(LogicalName='$EntityLogicalName')/Attributes(LogicalName='$AttributeLogicalName')?`$select=LogicalName" `
        -SuppressNotFoundError
    return $null -ne $result
}

function Add-DataverseColumn {
    <#
    .SYNOPSIS
        Generic column creation, idempotent, dispatching to the right
        Dataverse attribute metadata shape by -Type.
    .PARAMETER Type
        One of: String, Memo, Integer, Decimal, Money, DateOnly, DateTime,
        Image, File, Boolean, Choice. Choice requires exactly one of
        -GlobalChoiceName or -LocalOptions - see those parameters. DateOnly
        is for calendar facts (Time Zone Independent - the project-wide
        convention for anything that isn't a real moment in time); DateTime
        is for genuine moments - when something actually happened - and uses
        UserLocal behavior. Getting these two swapped is exactly the mistake
        the convention exists to prevent: a DateOnly column used for a
        "last synced at" timestamp would silently shift by time zone.
    .PARAMETER GlobalChoiceName
        The recommended path for -Type Choice. Backs the column with a
        reusable global choice (see New-DataverseGlobalChoice) - portable
        across tables and across environments, since its values are
        explicit rather than derived from a publisher prefix.
    .PARAMETER LocalOptions
        The -Type Choice path for when a local (table-specific) picklist was
        specifically requested rather than a global choice - e.g. @{ Value =
        100000000; Label = "Draft" }, @{ Value = 100000001; Label = "Sent" }.
        Deliberately a separate, differently-named parameter from
        -GlobalChoiceName rather than a shared "-Options" with a switch: a
        caller has to name what they're asking for, not flip a flag next to
        the default path. Still takes explicit sequential values, same as a
        global choice - a local picklist's values are just as much a
        cross-environment portability risk if left to the publisher's
        auto-derived prefix; this parameter does not remove that risk, only
        the reuse-across-tables benefit a global choice would have given.
    .PARAMETER AutoNumberFormat
        Only meaningful with -Type String. A Dataverse autonumber format
        string, e.g. "QUO-{SEQNUM:5}" -> QUO-00001. See Microsoft's
        AutoNumberFormat placeholder reference (SEQNUM, RANDSTRING,
        DATETIMEUTC) - this module passes the string through as-is and does
        not validate its placeholder syntax, since Dataverse itself only
        validates it lazily on first save, not at column-creation time.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $EntityLogicalName,
        [Parameter(Mandatory)] [string] $SchemaName,
        [Parameter(Mandatory)] [string] $DisplayName,
        [Parameter(Mandatory)] [ValidateSet('String', 'Memo', 'Integer', 'Decimal', 'Money', 'DateOnly', 'DateTime', 'Image', 'File', 'Boolean', 'Choice')]
        [string] $Type,
        [int] $MaxLength = 100,
        [ValidateSet('Text', 'Email', 'Url', 'TextArea')] [string] $StringFormat = 'Text',
        [string] $AutoNumberFormat,
        [int] $MinValue,
        [int] $MaxValue,
        [int] $Precision = 2,
        [int] $MaxSizeInKb = 10240,
        [string] $TrueLabel = 'Yes',
        [string] $FalseLabel = 'No',
        [bool] $DefaultBooleanValue = $false,
        [string] $GlobalChoiceName,
        [hashtable[]] $LocalOptions,  # @{ Value = 100000000; Label = "Draft" } - only when a local picklist was specifically requested
        [bool] $Required = $false,
        [Parameter(Mandatory)] [string] $SolutionUniqueName,
        [int] $LanguageCode = 1033
    )

    $attributeLogicalName = $SchemaName.ToLowerInvariant()
    if (Test-DataverseColumn -EntityLogicalName $EntityLogicalName -AttributeLogicalName $attributeLogicalName) {
        Write-Host "  skip   $EntityLogicalName.$attributeLogicalName"
        Test-DataverseColumnDrift -EntityLogicalName $EntityLogicalName -AttributeLogicalName $attributeLogicalName -ExpectedType $Type
        return
    }

    $displayLabel = @{ LocalizedLabels = @(@{ Label = $DisplayName; LanguageCode = $LanguageCode }) }
    $requiredLevel = @{ Value = if ($Required) { 'ApplicationRequired' } else { 'None' } }

    $body = switch ($Type) {
        'String' {
            $stringBody = @{ '@odata.type' = 'Microsoft.Dynamics.CRM.StringAttributeMetadata'; SchemaName = $SchemaName
               DisplayName = $displayLabel; MaxLength = $MaxLength; Format = $StringFormat; RequiredLevel = $requiredLevel }
            if ($AutoNumberFormat) {
                # Per Microsoft's own docs: Format/FormatName must be Text for
                # an autonumber column - fail loudly here rather than let
                # Dataverse reject a StringFormat/AutoNumberFormat combination
                # that can never work, with a less obvious error message.
                if ($StringFormat -ne 'Text') {
                    throw "Add-DataverseColumn: -AutoNumberFormat requires -StringFormat Text (got '$StringFormat'). Dataverse does not support autonumber on Email/Url/TextArea columns."
                }
                $stringBody.AutoNumberFormat = $AutoNumberFormat
            }
            $stringBody
        }
        'Memo' {
            @{ '@odata.type' = 'Microsoft.Dynamics.CRM.MemoAttributeMetadata'; SchemaName = $SchemaName
               DisplayName = $displayLabel; MaxLength = $MaxLength }
        }
        'Integer' {
            @{ '@odata.type' = 'Microsoft.Dynamics.CRM.IntegerAttributeMetadata'; SchemaName = $SchemaName
               DisplayName = $displayLabel; MinValue = $MinValue; MaxValue = $MaxValue; Format = 'None' }
        }
        'Decimal' {
            @{ '@odata.type' = 'Microsoft.Dynamics.CRM.DecimalAttributeMetadata'; SchemaName = $SchemaName
               DisplayName = $displayLabel; Precision = $Precision }
        }
        'Money' {
            @{ '@odata.type' = 'Microsoft.Dynamics.CRM.MoneyAttributeMetadata'; SchemaName = $SchemaName
               DisplayName = $displayLabel }
        }
        'DateOnly' {
            @{ '@odata.type' = 'Microsoft.Dynamics.CRM.DateTimeAttributeMetadata'; SchemaName = $SchemaName
               DisplayName = $displayLabel; Format = 'DateOnly'; DateTimeBehavior = @{ Value = 'DateOnly' }; RequiredLevel = $requiredLevel }
        }
        'DateTime' {
            @{ '@odata.type' = 'Microsoft.Dynamics.CRM.DateTimeAttributeMetadata'; SchemaName = $SchemaName
               DisplayName = $displayLabel; Format = 'DateAndTime'; DateTimeBehavior = @{ Value = 'UserLocal' }; RequiredLevel = $requiredLevel }
        }
        'Image' {
            @{ '@odata.type' = 'Microsoft.Dynamics.CRM.ImageAttributeMetadata'; SchemaName = $SchemaName; DisplayName = $displayLabel }
        }
        'File' {
            @{ '@odata.type' = 'Microsoft.Dynamics.CRM.FileAttributeMetadata'; SchemaName = $SchemaName
               DisplayName = $displayLabel; MaxSizeInKB = $MaxSizeInKb }
        }
        'Boolean' {
            @{ '@odata.type' = 'Microsoft.Dynamics.CRM.BooleanAttributeMetadata'; SchemaName = $SchemaName
               DisplayName = $displayLabel
               OptionSet = @{
                   TrueOption  = @{ Value = 1; Label = @{ LocalizedLabels = @(@{ Label = $TrueLabel; LanguageCode = $LanguageCode }) } }
                   FalseOption = @{ Value = 0; Label = @{ LocalizedLabels = @(@{ Label = $FalseLabel; LanguageCode = $LanguageCode }) } }
               }
               DefaultValue = $DefaultBooleanValue }
        }
        'Choice' {
            if ($GlobalChoiceName -and $LocalOptions) {
                throw "Add-DataverseColumn -Type Choice: pass either -GlobalChoiceName or -LocalOptions, not both."
            }
            if ($GlobalChoiceName) {
                $globalChoiceId = Get-DataverseGlobalChoiceId -Name $GlobalChoiceName
                @{ '@odata.type' = 'Microsoft.Dynamics.CRM.PicklistAttributeMetadata'; SchemaName = $SchemaName
                   DisplayName = $displayLabel
                   'GlobalOptionSet@odata.bind' = "/GlobalOptionSetDefinitions($globalChoiceId)" }
            }
            elseif ($LocalOptions) {
                # Local (table-specific) picklist - only reached when a caller
                # deliberately named -LocalOptions. Still explicit, sequential
                # values, same reasoning as New-DataverseGlobalChoice: never
                # the publisher's auto-derived prefix.
                @{ '@odata.type' = 'Microsoft.Dynamics.CRM.PicklistAttributeMetadata'; SchemaName = $SchemaName
                   DisplayName = $displayLabel
                   OptionSet = @{
                       '@odata.type' = 'Microsoft.Dynamics.CRM.OptionSetMetadata'
                       IsGlobal      = $false
                       OptionSetType = 'Picklist'
                       Options       = $LocalOptions | ForEach-Object {
                           @{ Value = $_.Value; Label = @{ LocalizedLabels = @(@{ Label = $_.Label; LanguageCode = $LanguageCode }) } }
                       }
                   } }
            }
            else {
                throw "Add-DataverseColumn -Type Choice requires either -GlobalChoiceName (recommended - see references/choice-and-column-conventions.md) or -LocalOptions (only when a local picklist was specifically requested for this column)."
            }
        }
    }

    Invoke-DataverseApi -Method Post -Path "EntityDefinitions(LogicalName='$EntityLogicalName')/Attributes" -Body $body -SolutionUniqueName $SolutionUniqueName | Out-Null
    Write-Host "  create $EntityLogicalName.$attributeLogicalName"
}

# --- Lookups / 1:N relationships -------------------------------------------------

function Test-DataverseRelationship {
    param([Parameter(Mandatory)] [string] $SchemaName)
    $result = Invoke-DataverseApi -Method Get -Path "RelationshipDefinitions(SchemaName='$SchemaName')?`$select=SchemaName" -SuppressNotFoundError
    return $null -ne $result
}

function Add-DataverseLookup {
    <#
    .SYNOPSIS
        Creates a 1:N relationship and its lookup column together, using only
        a named cascade preset.
    .PARAMETER Cascade
        One of Referential, ReferentialRestrictDelete, Parental. There is no
        way to pass a raw cascade configuration through this function - see
        the module header for exactly why that restriction exists.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RelationshipSchemaName,
        [Parameter(Mandatory)] [string] $ReferencedEntity,
        [Parameter(Mandatory)] [string] $ReferencingEntity,
        [Parameter(Mandatory)] [string] $LookupSchemaName,
        [Parameter(Mandatory)] [string] $LookupDisplayName,
        [Parameter(Mandatory)] [ValidateSet('Referential', 'ReferentialRestrictDelete', 'Parental')] [string] $Cascade,
        [bool] $Required = $false,
        [Parameter(Mandatory)] [string] $SolutionUniqueName,
        [int] $LanguageCode = 1033
    )

    if (Test-DataverseRelationship -SchemaName $RelationshipSchemaName) {
        Write-Host "  skip   relationship $RelationshipSchemaName"
        return
    }

    $body = @{
        '@odata.type'          = 'Microsoft.Dynamics.CRM.OneToManyRelationshipMetadata'
        SchemaName             = $RelationshipSchemaName
        ReferencedEntity       = $ReferencedEntity
        ReferencingEntity      = $ReferencingEntity
        CascadeConfiguration   = $script:CascadePresets[$Cascade]
        Lookup                 = @{
            '@odata.type' = 'Microsoft.Dynamics.CRM.LookupAttributeMetadata'
            SchemaName    = $LookupSchemaName
            DisplayName   = @{ LocalizedLabels = @(@{ Label = $LookupDisplayName; LanguageCode = $LanguageCode }) }
            RequiredLevel = @{ Value = if ($Required) { 'ApplicationRequired' } else { 'None' } }
        }
    }

    Invoke-DataverseApi -Method Post -Path 'RelationshipDefinitions' -Body $body -SolutionUniqueName $SolutionUniqueName | Out-Null
    Write-Host "  create relationship $RelationshipSchemaName ($ReferencingEntity.$($LookupSchemaName.ToLowerInvariant()) -> $ReferencedEntity)"
}

# --- Alternate keys ---------------------------------------------------------------

function Test-DataverseAlternateKey {
    param([Parameter(Mandatory)] [string] $EntityLogicalName, [Parameter(Mandatory)] [string] $KeySchemaName)
    $entity = Invoke-DataverseApi -Method Get -Path "EntityDefinitions(LogicalName='$EntityLogicalName')?`$expand=Keys(`$select=SchemaName)" -SuppressNotFoundError
    if (-not $entity) { return $false }
    return [bool]($entity.Keys | Where-Object { $_.SchemaName -eq $KeySchemaName })
}

function Wait-DataverseAlternateKeyActive {
    <#
    .SYNOPSIS
        Polls EntityKeyIndexStatus until the key reaches Active or Failed,
        or a bounded timeout elapses - closes the gap where "safe to
        re-run" wasn't yet fully true for alternate keys.
    .DESCRIPTION
        Confirmed against Microsoft's own Web API reference before writing
        this: EntityKeyIndexStatus is a named enum - Pending, InProgress,
        Active, Failed (see EntityKeyIndexStatus EnumType) - returned as one
        of those strings, not a raw integer, so the string comparisons below
        are exact, not a guess. New-DataverseAlternateKey previously only
        tolerated the "not found yet" half of the async-creation race (the
        try/catch on "already exists"); it never confirmed the key actually
        finished building before returning control to the caller. A caller
        that immediately upserts against a key still Pending/InProgress can
        hit a transient failure that looks like a bug in this module rather
        than the documented async index build Microsoft's own docs describe.

        Does not block indefinitely - index build time scales with existing
        row count, and an already-large table could legitimately take
        longer than any reasonable script timeout, per Microsoft's own
        guidance. A key still Pending/InProgress after -MaxWaitSeconds logs
        a warning and returns rather than hanging forever; the create call
        itself already succeeded, so this is a status warning, not a deploy
        failure. Failed is treated differently - it is an actual problem
        the platform is reporting, not a timing race, so it throws with the
        system-job name Microsoft's docs say to look for.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $EntityLogicalName,
        [Parameter(Mandatory)] [string] $KeySchemaName,
        [int] $MaxWaitSeconds = 60,
        [int] $PollIntervalSeconds = 3
    )

    $deadline = (Get-Date).AddSeconds($MaxWaitSeconds)
    do {
        $entity = Invoke-DataverseApi -Method Get `
            -Path "EntityDefinitions(LogicalName='$EntityLogicalName')?`$expand=Keys(`$select=SchemaName,EntityKeyIndexStatus)" `
            -SuppressNotFoundError
        $key = $null
        if ($entity) { $key = $entity.Keys | Where-Object { $_.SchemaName -eq $KeySchemaName } | Select-Object -First 1 }

        if ($key -and $key.EntityKeyIndexStatus -eq 'Active') {
            Write-Host "  active alternate key $EntityLogicalName.$KeySchemaName"
            return
        }
        if ($key -and $key.EntityKeyIndexStatus -eq 'Failed') {
            throw "Alternate key $EntityLogicalName.$KeySchemaName failed to build (EntityKeyIndexStatus: Failed). Look for the async system job named 'Create index for $DisplayName for table $EntityLogicalName' for the cause, fix it, then use the ReactivateEntityKey action - this module does not do that automatically."
        }

        if ((Get-Date) -lt $deadline) { Start-Sleep -Seconds $PollIntervalSeconds }
    } while ((Get-Date) -lt $deadline)

    Write-Warning "Alternate key $EntityLogicalName.$KeySchemaName is still building after ${MaxWaitSeconds}s (not yet Active) - expected for a table with a lot of existing data, since index build time scales with row count. This is not a deploy failure; re-run later to confirm it reached Active."
}

function New-DataverseAlternateKey {
    <#
    .SYNOPSIS
        Idempotent alternate key creation, tolerant of the async-creation
        race documented in the module header, and polls to Active (or a
        bounded timeout) before returning - see Wait-DataverseAlternateKeyActive.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $EntityLogicalName,
        [Parameter(Mandatory)] [string] $KeySchemaName,
        [Parameter(Mandatory)] [string] $DisplayName,
        [Parameter(Mandatory)] [string[]] $KeyAttributes,
        [Parameter(Mandatory)] [string] $SolutionUniqueName,
        [int] $LanguageCode = 1033,
        [int] $MaxWaitSeconds = 60
    )

    if (Test-DataverseAlternateKey -EntityLogicalName $EntityLogicalName -KeySchemaName $KeySchemaName) {
        Write-Host "  skip   alternate key $EntityLogicalName.$KeySchemaName"
        Wait-DataverseAlternateKeyActive -EntityLogicalName $EntityLogicalName -KeySchemaName $KeySchemaName -MaxWaitSeconds $MaxWaitSeconds
        return
    }

    $body = @{
        SchemaName    = $KeySchemaName
        DisplayName   = @{ LocalizedLabels = @(@{ Label = $DisplayName; LanguageCode = $LanguageCode }) }
        KeyAttributes = $KeyAttributes
    }

    try {
        Invoke-DataverseApi -Method Post -Path "EntityDefinitions(LogicalName='$EntityLogicalName')/Keys" -Body $body -SolutionUniqueName $SolutionUniqueName | Out-Null
        Write-Host "  create alternate key $EntityLogicalName.$KeySchemaName ($($KeyAttributes -join ', '))"
    }
    catch {
        if ($_.ErrorDetails.Message -match 'already exists') {
            Write-Host "  skip   alternate key $EntityLogicalName.$KeySchemaName (already queued)"
        }
        else {
            throw
        }
    }

    Wait-DataverseAlternateKeyActive -EntityLogicalName $EntityLogicalName -KeySchemaName $KeySchemaName -MaxWaitSeconds $MaxWaitSeconds
}

# --- Views ---------------------------------------------------------------------

function Test-DataverseAutoGeneratedViewCollision {
    <#
    .SYNOPSIS
        Warns if a proposed view name matches one of Dataverse's own
        auto-generated default view naming patterns for a table.
    .DESCRIPTION
        Dataverse creates "Active {Plural}", "Inactive {Plural}" and a
        personal "My {Plural}"-style view automatically the moment a table is
        created. A same-name check against savedquery alone cannot tell "my
        intended business-filtered view" from "the platform's own view that
        happens to share this name" - this was hit directly building the
        Tacstone Internal Platform: two of five intended certification views
        were silently never created because the platform's own defaults
        occupied those exact names first.
    #>
    param([Parameter(Mandatory)] [string] $PluralDisplayName, [Parameter(Mandatory)] [string] $ProposedName)

    $reservedPatterns = @(
        "Active $PluralDisplayName", "Inactive $PluralDisplayName", "My $PluralDisplayName"
    )
    return $reservedPatterns -contains $ProposedName
}

function New-DataverseView {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $EntityLogicalName,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $FetchXml,
        [Parameter(Mandatory)] [string] $LayoutXml,
        [Parameter(Mandatory)] [string] $PluralDisplayName,
        [Parameter(Mandatory)] [string] $SolutionUniqueName
    )

    if (Test-DataverseAutoGeneratedViewCollision -PluralDisplayName $PluralDisplayName -ProposedName $Name) {
        Write-Warning "'$Name' matches a Dataverse auto-generated default view name for $EntityLogicalName. Rename this view - it will silently create nothing (the platform's own view already occupies that name)."
        return
    }

    $existing = Invoke-DataverseApi -Method Get `
        -Path "savedqueries?`$filter=returnedtypecode eq '$EntityLogicalName' and name eq '$Name'&`$select=savedqueryid" `
        -SuppressNotFoundError
    if (-not (Test-DataverseNotFound $existing)) {
        Write-Host "  skip   view $EntityLogicalName.$Name"
        return
    }

    $body = @{
        name           = $Name
        returnedtypecode = $EntityLogicalName
        querytype      = 0
        fetchxml       = $FetchXml
        layoutxml      = $LayoutXml
    }

    Invoke-DataverseApi -Method Post -Path 'savedqueries' -Body $body -SolutionUniqueName $SolutionUniqueName | Out-Null
    Write-Host "  create view $EntityLogicalName.$Name"
}

function New-FetchXml {
    param(
        [Parameter(Mandatory)] [string] $EntityLogicalName,
        [Parameter(Mandatory)] [string[]] $Attributes,
        [string] $OrderAttribute,
        [string] $FilterXml
    )
    $attrXml = ($Attributes | ForEach-Object { "<attribute name=`"$_`" />" }) -join ''
    $orderXml = if ($OrderAttribute) { "<order attribute=`"$OrderAttribute`" descending=`"false`" />" } else { '' }
    return "<fetch version=`"1.0`" output-format=`"xml-platform`" mapping=`"logical`" distinct=`"false`"><entity name=`"$EntityLogicalName`">$attrXml$orderXml$FilterXml</entity></fetch>"
}

function New-LayoutXml {
    param([Parameter(Mandatory)] [string] $EntityLogicalName, [Parameter(Mandatory)] [string[]] $Attributes)
    $cellXml = ($Attributes | ForEach-Object { "<cell name=`"$_`" width=`"150`" />" }) -join ''
    return "<grid name=`"resultset`" object=`"1`" jump=`"$($Attributes[0])`" select=`"1`" icon=`"1`" preview=`"1`"><row name=`"result`" id=`"$($EntityLogicalName)id`">$cellXml</row></grid>"
}

# --- Field security ---------------------------------------------------------------

function Publish-DataverseEntity {
    <#
    .SYNOPSIS
        Publishes customizations for one table via the Web API's PublishXml
        action - required after an UPDATE to an already-existing solution
        component, unlike every CREATE call elsewhere in this module.
    .DESCRIPTION
        Confirmed against Microsoft's own docs before writing this, not
        assumed: "Solution components are published automatically when they
        are created or deleted. You must publish changes when solution
        components are updated." Every New-Dataverse*/Add-Dataverse*
        function in this module only ever creates (POST) - Set-
        DataverseFieldSecured is the sole exception, since marking an
        existing column IsSecured is a PUT against something that already
        existed and was already published. This is why nothing else in this
        module has ever needed an explicit publish call, and also why that
        absence wasn't a gap needing a fix everywhere - it only needed
        closing at the one call site that actually updates something.

        Scoped to the single entity that changed via PublishXml, not the
        heavier PublishAllXml - Microsoft's own admin guidance is explicit
        that publishing "can interfere with normal system operation," so
        this module publishes only what it actually touched, not every
        pending customization across the whole organization.
    #>
    param([Parameter(Mandatory)] [string] $EntityLogicalName)

    $parameterXml = "<importexportxml><entities><entity>$EntityLogicalName</entity></entities></importexportxml>"
    Invoke-DataverseApi -Method Post -Path 'PublishXml' -Body @{ ParameterXml = $parameterXml } | Out-Null
    Write-Host "  publish $EntityLogicalName"
}

function Set-DataverseFieldSecured {
    <#
    .SYNOPSIS
        Marks an existing column as IsSecured=true, if it isn't already.
        Required before any FieldPermission can reference it - Dataverse
        rejects field permission creation on an unsecured column outright.
    .PARAMETER AttributeType
        The concrete attribute metadata type name (e.g. "MoneyAttributeMetadata"),
        needed to address the typed endpoint the Web API requires for attribute
        metadata updates.
    .DESCRIPTION
        Attribute (and entity) metadata updates are one of the few Web API
        surfaces that reject PATCH outright - Microsoft's own docs are
        explicit that "You can't use the PATCH method to update data model
        entities... you must use the PUT method... and be careful to include
        all the existing properties that you don't intend to change." Found
        live: a partial PATCH with just {IsSecured: true} came back 405
        "resource does not support http method 'PATCH'". Fixed by retrieving
        the full typed attribute definition first, changing only IsSecured on
        it, and PUTting the whole thing back - the pattern Microsoft's own
        Web API sample uses for every attribute metadata update.

        This PUT is also this module's one and only UPDATE to an existing
        solution component (everything else only creates) - see
        Publish-DataverseEntity for why that specifically requires an
        explicit publish call afterward, which this function now makes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $EntityLogicalName,
        [Parameter(Mandatory)] [string] $AttributeLogicalName,
        [Parameter(Mandatory)] [string] $AttributeType,
        [Parameter(Mandatory)] [string] $SolutionUniqueName
    )

    $path = "EntityDefinitions(LogicalName='$EntityLogicalName')/Attributes(LogicalName='$AttributeLogicalName')/Microsoft.Dynamics.CRM.$AttributeType"

    $current = Invoke-DataverseApi -Method Get -Path $path
    if ($current.IsSecured -eq $true) {
        Write-Host "  skip   $EntityLogicalName.$AttributeLogicalName already secured"
        return
    }

    $current.IsSecured = $true
    Invoke-DataverseApi -Method Put -Path $path -Body $current -SolutionUniqueName $SolutionUniqueName | Out-Null
    Write-Host "  create secured $EntityLogicalName.$AttributeLogicalName"
    Publish-DataverseEntity -EntityLogicalName $EntityLogicalName
}

function New-DataverseFieldSecurityProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Name, [Parameter(Mandatory)] [string] $SolutionUniqueName)

    $existing = Invoke-DataverseApi -Method Get -Path "fieldsecurityprofiles?`$filter=name eq '$Name'&`$select=fieldsecurityprofileid" -SuppressNotFoundError
    if (-not (Test-DataverseNotFound $existing)) {
        Write-Host "  skip   field security profile $Name"
        return $existing.value[0].fieldsecurityprofileid
    }

    $created = Invoke-DataverseApi -Method Post -Path 'fieldsecurityprofiles' -Body @{ name = $Name } -SolutionUniqueName $SolutionUniqueName
    Write-Host "  create field security profile $Name"
    # Web API returns the new id via the OData-EntityId response header in real
    # use; callers of this module should re-query by name immediately after if
    # they need the id, since Invoke-RestMethod does not surface response
    # headers by default. See deploy-dataverse-schema's reference doc.
    return (Invoke-DataverseApi -Method Get -Path "fieldsecurityprofiles?`$filter=name eq '$Name'&`$select=fieldsecurityprofileid").value[0].fieldsecurityprofileid
}

function Add-DataverseFieldPermission {
    <#
    .SYNOPSIS
        Grants read/create/update on one column to a field security profile.
        Automatically ensures the column is IsSecured first - see
        Set-DataverseFieldSecured.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [guid] $FieldSecurityProfileId,
        [Parameter(Mandatory)] [string] $EntityLogicalName,
        [Parameter(Mandatory)] [string] $AttributeLogicalName,
        [Parameter(Mandatory)] [string] $AttributeType,
        [Parameter(Mandatory)] [string] $SolutionUniqueName,
        [bool] $CanRead = $true,
        [bool] $CanCreate = $true,
        [bool] $CanUpdate = $true
    )

    Set-DataverseFieldSecured -EntityLogicalName $EntityLogicalName -AttributeLogicalName $AttributeLogicalName `
        -AttributeType $AttributeType -SolutionUniqueName $SolutionUniqueName

    $existing = Invoke-DataverseApi -Method Get `
        -Path "fieldpermissions?`$filter=_fieldsecurityprofileid_value eq $FieldSecurityProfileId and attributelogicalname eq '$AttributeLogicalName'&`$select=fieldpermissionid" `
        -SuppressNotFoundError
    if (-not (Test-DataverseNotFound $existing)) {
        Write-Host "  skip   field permission $EntityLogicalName.$AttributeLogicalName"
        return
    }

    # field_security_permission_type global choice: 0 = Not Allowed, 4 = Allowed.
    # Confirmed against Microsoft's own reference before writing this - not 0/1.
    $allowed = 4
    $notAllowed = 0

    $body = @{
        'fieldsecurityprofileid@odata.bind' = "/fieldsecurityprofiles($FieldSecurityProfileId)"
        entityname                          = $EntityLogicalName
        attributelogicalname                = $AttributeLogicalName
        canread                             = if ($CanRead) { $allowed } else { $notAllowed }
        cancreate                           = if ($CanCreate) { $allowed } else { $notAllowed }
        canupdate                           = if ($CanUpdate) { $allowed } else { $notAllowed }
    }

    # Not solution-targeted: fieldpermission travels with its parent profile,
    # it is not an independent solution component in its own right.
    Invoke-DataverseApi -Method Post -Path 'fieldpermissions' -Body $body | Out-Null
    Write-Host "  create field permission $EntityLogicalName.$AttributeLogicalName (read=$CanRead create=$CanCreate update=$CanUpdate)"
}

# --- Security roles ---------------------------------------------------------------

function Get-DataverseEntityPrivileges {
    <#
    .SYNOPSIS
        Returns a hashtable of PrivilegeType -> PrivilegeId for one table,
        used to resolve grants before building a role's privilege list.
    #>
    param([Parameter(Mandatory)] [string] $EntityLogicalName)

    $response = Invoke-DataverseApi -Method Get -Path "EntityDefinitions(LogicalName='$EntityLogicalName')/Privileges"
    $map = @{}
    foreach ($privilege in $response.value) {
        $map[$privilege.PrivilegeType] = $privilege.PrivilegeId
    }
    return $map
}

function New-DataverseSecurityRole {
    <#
    .SYNOPSIS
        Idempotent security role creation from a flat grant list.
    .PARAMETER Grants
        Array of @{ Entity = 'x'; Type = 'Read'; Depth = 'Global' } hashtables.
        Type is one of Create/Read/Write/Delete/Append/AppendTo/Assign/Share.
        Depth is one of Basic/Local/Deep/Global (Basic = "User", Global =
        "Organization" in the maker-portal's own language).
    .PARAMETER AutoExpandAppend
        When set (default true), automatically adds Append and AppendTo
        grants at the same depth as each Read grant. Dataverse has no
        privilege scoped to a specific lookup relationship - Append/AppendTo
        are per-entity, covering every lookup that table participates in on
        either side - so this is the actual achievable granularity, not an
        approximation of a finer mechanism the platform doesn't offer.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [guid] $BusinessUnitId,
        [Parameter(Mandatory)] [hashtable[]] $Grants,
        [Parameter(Mandatory)] [string] $SolutionUniqueName,
        [bool] $AutoExpandAppend = $true
    )

    $existing = Invoke-DataverseApi -Method Get -Path "roles?`$filter=name eq '$Name'&`$select=roleid" -SuppressNotFoundError
    if (-not (Test-DataverseNotFound $existing)) {
        Write-Host "  skip   security role $Name"
        return
    }

    $expanded = [System.Collections.Generic.List[hashtable]]::new()
    $Grants | ForEach-Object { $expanded.Add($_) }
    if ($AutoExpandAppend) {
        foreach ($grant in ($Grants | Where-Object { $_.Type -eq 'Read' })) {
            $expanded.Add(@{ Entity = $grant.Entity; Type = 'Append'; Depth = $grant.Depth })
            $expanded.Add(@{ Entity = $grant.Entity; Type = 'AppendTo'; Depth = $grant.Depth })
        }
    }

    $roleBody = @{ name = $Name; 'businessunitid@odata.bind' = "/businessunits($BusinessUnitId)" }
    $roleResponse = Invoke-DataverseApi -Method Post -Path 'roles' -Body $roleBody -SolutionUniqueName $SolutionUniqueName
    $roleId = (Invoke-DataverseApi -Method Get -Path "roles?`$filter=name eq '$Name'&`$select=roleid").value[0].roleid

    $privilegesByEntity = @{}
    $rolePrivileges = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($grant in $expanded) {
        if (-not $privilegesByEntity.ContainsKey($grant.Entity)) {
            $privilegesByEntity[$grant.Entity] = Get-DataverseEntityPrivileges -EntityLogicalName $grant.Entity
        }
        $privilegeId = $privilegesByEntity[$grant.Entity][$grant.Type]
        if ($privilegeId) {
            $rolePrivileges.Add(@{
                '@odata.type' = 'Microsoft.Dynamics.CRM.RolePrivilege'
                PrivilegeId   = $privilegeId
                Depth         = $grant.Depth
            })
        }
    }

    Invoke-DataverseApi -Method Post -Path "roles($roleId)/Microsoft.Dynamics.CRM.AddPrivilegesRole" -Body @{ Privileges = $rolePrivileges } | Out-Null
    Write-Host "  create security role $Name ($($rolePrivileges.Count) privileges)"
}

# --- What-if / dry run ------------------------------------------------------------

function Show-DataverseWhatIfPlan {
    <#
    .SYNOPSIS
        Prints a create/skip preview for every item in a schema spec against
        the currently connected environment, without creating, updating, or
        deleting anything.
    .DESCRIPTION
        Deliberately calls only Test-Dataverse*/read (GET) paths - never any
        New-Dataverse*/Add-Dataverse* function - so a -WhatIf run cannot
        mutate anything even if a flag check elsewhere in this module were
        ever wrong. A structurally separate, read-only path is a stronger
        guarantee than threading -WhatIf through every creating function and
        trusting each one to correctly no-op: several of those functions
        return an id a later step depends on (New-DataverseSecurityRole's
        roleId, New-DataverseFieldSecurityProfile's fieldsecurityprofileid) -
        skipping the create but not the later dependent lookup would hit a
        genuine null-reference failure under this module's own
        Set-StrictMode, on exactly the common case of a first-ever deploy of
        a brand new schema where nothing exists yet to fall back to.

        Because of that same dependency, security-role and field-security
        items are reported by existence only (does the role/profile itself
        already exist), not diffed at the privilege/permission level - doing
        that correctly would mean resolving privilege IDs from tables that
        may not exist yet either in a first-time -WhatIf run. Said plainly
        in the output rather than pretended away, the same convention this
        module already uses for rollup columns and custom forms.
    #>
    param([Parameter(Mandatory)] $Spec)

    Write-Host "== What if: global choices =="
    foreach ($choice in $Spec.globalChoices) {
        if (Test-DataverseGlobalChoice -Name $choice.name) { Write-Host "  skip   global choice $($choice.name)" }
        else { Write-Host "  create global choice $($choice.name) ($($choice.options.Count) options)" }
    }

    Write-Host ""
    Write-Host "== What if: tables =="
    foreach ($table in $Spec.tables) {
        if (Test-DataverseTable -LogicalName $table.logicalName) { Write-Host "  skip   table $($table.logicalName)" }
        else { Write-Host "  create table $($table.logicalName)" }
    }

    Write-Host ""
    Write-Host "== What if: columns =="
    foreach ($table in $Spec.tables) {
        foreach ($column in $table.columns) {
            $attributeLogicalName = $column.schemaName.ToLowerInvariant()
            if (Test-DataverseColumn -EntityLogicalName $table.logicalName -AttributeLogicalName $attributeLogicalName) {
                Write-Host "  skip   $($table.logicalName).$attributeLogicalName"
            }
            else {
                Write-Host "  create $($table.logicalName).$attributeLogicalName"
            }
        }
    }

    Write-Host ""
    Write-Host "== What if: relationships =="
    foreach ($table in $Spec.tables) {
        foreach ($lookup in $table.lookups) {
            if (Test-DataverseRelationship -SchemaName $lookup.relationshipSchemaName) {
                Write-Host "  skip   relationship $($lookup.relationshipSchemaName)"
            }
            else {
                Write-Host "  create relationship $($lookup.relationshipSchemaName) ($($table.logicalName).$($lookup.lookupSchemaName.ToLowerInvariant()) -> $($lookup.referencedEntity))"
            }
        }
    }

    Write-Host ""
    Write-Host "== What if: alternate keys =="
    foreach ($table in $Spec.tables) {
        foreach ($key in $table.alternateKeys) {
            if (Test-DataverseAlternateKey -EntityLogicalName $table.logicalName -KeySchemaName $key.schemaName) {
                Write-Host "  skip   alternate key $($table.logicalName).$($key.schemaName)"
            }
            else {
                Write-Host "  create alternate key $($table.logicalName).$($key.schemaName) ($($key.keyAttributes -join ', '))"
            }
        }
    }

    Write-Host ""
    Write-Host "== What if: views =="
    foreach ($view in $Spec.views) {
        $table = $Spec.tables | Where-Object { $_.logicalName -eq $view.entityLogicalName } | Select-Object -First 1
        $pluralDisplayName = if ($table) { $table.pluralDisplayName } else { $view.entityLogicalName }

        if (Test-DataverseAutoGeneratedViewCollision -PluralDisplayName $pluralDisplayName -ProposedName $view.name) {
            Write-Warning "'$($view.name)' matches a Dataverse auto-generated default view name for $($view.entityLogicalName) - would warn and create nothing."
            continue
        }

        $existing = Invoke-DataverseApi -Method Get `
            -Path "savedqueries?`$filter=returnedtypecode eq '$($view.entityLogicalName)' and name eq '$($view.name)'&`$select=savedqueryid" `
            -SuppressNotFoundError
        if (-not (Test-DataverseNotFound $existing)) { Write-Host "  skip   view $($view.entityLogicalName).$($view.name)" }
        else { Write-Host "  create view $($view.entityLogicalName).$($view.name)" }
    }

    Write-Host ""
    Write-Host "== What if: security roles =="
    foreach ($role in $Spec.securityRoles) {
        $existing = Invoke-DataverseApi -Method Get -Path "roles?`$filter=name eq '$($role.name)'&`$select=roleid" -SuppressNotFoundError
        if (-not (Test-DataverseNotFound $existing)) { Write-Host "  skip   security role $($role.name)" }
        else { Write-Host "  create security role $($role.name) (existence only - privilege-level diffing not previewed)" }
    }

    Write-Host ""
    Write-Host "== What if: field security =="
    foreach ($profile in $Spec.fieldSecurityProfiles) {
        $existing = Invoke-DataverseApi -Method Get -Path "fieldsecurityprofiles?`$filter=name eq '$($profile.name)'&`$select=fieldsecurityprofileid" -SuppressNotFoundError
        if (-not (Test-DataverseNotFound $existing)) { Write-Host "  skip   field security profile $($profile.name) (permission-level diffing not previewed)" }
        else { Write-Host "  create field security profile $($profile.name) (permission-level diffing not previewed)" }
    }
}

# --- Solution structure -----------------------------------------------------
# Supports skills/validate-solution-structure. Read-only against `solutions`
# and `solutioncomponents` - nothing in this section ever creates, updates,
# or moves a component. Reassigning a component's owning solution isn't even
# always possible without recreating it (different publishers can't share a
# component), so this reports drift for a human to act on, the same way
# Microsoft's own FastTrack Solution Component Validation Tool does - see
# skills/validate-solution-structure/references/checks.md for the full
# reasoning and citation.

$script:SolutionComponentTypeNames = @{
    # Sourced from Microsoft's own solutioncomponent table/entity reference
    # (componenttype's global choice values). NOT exhaustive - Power
    # Platform has added component types since this reference was written
    # (Canvas Apps, Custom APIs, Connection References, Environment
    # Variables, Connectors and others aren't in Microsoft's own published
    # list) - Get-DataverseSolutionComponentTypeName falls back to the raw
    # numeric code rather than guessing a name for anything not in this
    # table, matching this project's own rule of never assuming a value
    # scheme it hasn't confirmed.
    1 = 'Entity'; 2 = 'Attribute'; 3 = 'Relationship'; 4 = 'Attribute Picklist Value'
    5 = 'Attribute Lookup Value'; 6 = 'View Attribute'; 7 = 'Localized Label'
    8 = 'Relationship Extra Condition'; 9 = 'Option Set'; 10 = 'Entity Relationship'
    11 = 'Entity Relationship Role'; 12 = 'Entity Relationship Relationships'
    13 = 'Managed Property'; 14 = 'Entity Key'; 16 = 'Privilege'
    17 = 'PrivilegeObjectTypeCode'; 18 = 'Index'; 20 = 'Role'; 21 = 'Role Privilege'
    22 = 'Display String'; 23 = 'Display String Map'; 24 = 'Form'; 25 = 'Organization'
    26 = 'Saved Query'; 29 = 'Workflow'; 31 = 'Report'; 32 = 'Report Entity'
    33 = 'Report Category'; 34 = 'Report Visibility'; 35 = 'Attachment'
    36 = 'Email Template'; 37 = 'Contract Template'; 38 = 'KB Article Template'
    39 = 'Mail Merge Template'; 44 = 'Duplicate Rule'; 45 = 'Duplicate Rule Condition'
    46 = 'Entity Map'; 47 = 'Attribute Map'; 48 = 'Ribbon Command'
    49 = 'Ribbon Context Group'; 50 = 'Ribbon Customization'; 52 = 'Ribbon Rule'
    53 = 'Ribbon Tab To Command Map'; 55 = 'Ribbon Diff'; 59 = 'Saved Query Visualization'
    60 = 'System Form'; 61 = 'Web Resource'; 62 = 'Site Map'; 63 = 'Connection Role'
    64 = 'Complex Control'; 65 = 'Hierarchy Rule'; 66 = 'Custom Control (PCF)'
    68 = 'Custom Control Default Config'; 70 = 'Field Security Profile'
    71 = 'Field Permission'; 90 = 'Plugin Type'; 91 = 'Plugin Assembly'
    92 = 'SDK Message Processing Step'; 93 = 'SDK Message Processing Step Image'
    95 = 'Service Endpoint'; 150 = 'Routing Rule'; 151 = 'Routing Rule Item'
    152 = 'SLA'; 153 = 'SLA Item'; 154 = 'Convert Rule'; 155 = 'Convert Rule Item'
    161 = 'Mobile Offline Profile'; 162 = 'Mobile Offline Profile Item'
    165 = 'Similarity Rule'
}

function Get-DataverseSolutionComponentTypeName {
    <#
    .SYNOPSIS
        Human-readable name for a solutioncomponent `componenttype` code, or
        the raw code itself (never a guess) if it isn't in this module's
        reference table.
    #>
    param([Parameter(Mandatory)] [int] $ComponentType)

    if ($script:SolutionComponentTypeNames.ContainsKey($ComponentType)) {
        return $script:SolutionComponentTypeNames[$ComponentType]
    }
    return "Component Type $ComponentType (unmapped - see Microsoft's solutioncomponent reference)"
}

function Get-DataverseSolutionByUniqueName {
    <#
    .SYNOPSIS
        Resolves a solution's id, display name, version, and publisher
        (unique name + customization prefix) from its unique name. Returns
        $null (not a throw) if no solution with that unique name exists -
        an expected, reportable case for this skill, not an error.
    #>
    param([Parameter(Mandatory)] [string] $UniqueName)

    $result = Invoke-DataverseApi -Method Get -Path (
        "solutions?`$filter=uniquename eq '$UniqueName'" +
        "&`$select=solutionid,friendlyname,uniquename,version,ismanaged" +
        "&`$expand=publisherid(`$select=uniquename,customizationprefix,friendlyname)"
    ) -SuppressNotFoundError

    if (Test-DataverseNotFound $result) { return $null }
    return $result.value[0]
}

function Get-DataverseSolutionComponents {
    <#
    .SYNOPSIS
        Every solutioncomponent row (componenttype, objectid) for one
        solution, following `@odata.nextLink` until the full set is
        retrieved - a real solution can hold far more components than a
        single Web API page returns.
    .DESCRIPTION
        `@odata.nextLink` comes back as a full URL rooted at this module's
        own ApiUrl. Rather than issue a second, separately-built
        Invoke-RestMethod call for continuation pages, this strips that
        known prefix and keeps routing every page through
        Invoke-DataverseApi - the same "every call goes through this one
        function" discipline the rest of this module and both skills'
        SKILL.md files already enforce.
    #>
    param([Parameter(Mandatory)] [guid] $SolutionId)

    $components = [System.Collections.Generic.List[pscustomobject]]::new()
    $path = "solutioncomponents?`$filter=_solutionid_value eq $SolutionId&`$select=componenttype,objectid"

    while ($path) {
        $response = Invoke-DataverseApi -Method Get -Path $path
        foreach ($c in $response.value) { $components.Add($c) }

        $path = $null
        # Strict mode (on in this module) throws on dot-access to a property
        # that genuinely isn't there - and the Web API omits @odata.nextLink
        # entirely on the last page, not just sets it empty. Index into
        # PSObject.Properties instead, which returns $null for "absent"
        # rather than throwing - the same class of bug already hit once in
        # this project's history reading an external JSON spec under strict
        # mode (see Deploy-DataverseSchema.ps1's own remark on why it
        # disables strict mode for that reason); a live API response is the
        # same kind of "partially-optional external shape" this function
        # needs to tolerate, even though the rest of this module keeps
        # strict mode on for its own code.
        $nextLinkProp = $response.psobject.Properties['@odata.nextLink']
        $nextLink = if ($nextLinkProp) { $nextLinkProp.Value } else { $null }
        if ($nextLink) {
            $prefix = "$($script:DataverseContext.ApiUrl)/"
            if ($nextLink.StartsWith($prefix)) {
                $path = $nextLink.Substring($prefix.Length)
            }
            else {
                Write-Warning "solutioncomponents @odata.nextLink didn't match the expected ApiUrl prefix - stopping pagination early for solution $SolutionId. Results below may be incomplete."
            }
        }
    }

    return $components
}

Export-ModuleMember -Function *
