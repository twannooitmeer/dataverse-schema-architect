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
        Tries `az account get-access-token` first - this reuses an existing
        Azure CLI login with no extra sign-in step, the same pattern
        Microsoft's own power-platform-skills plugins use. Falls back to a
        device-code flow only if az CLI isn't installed or isn't logged in,
        so the plugin still works for someone without Azure CLI set up.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $EnvironmentUrl
    )

    $EnvironmentUrl = $EnvironmentUrl.TrimEnd('/')
    $token = $null

    $az = Get-Command az -ErrorAction SilentlyContinue
    if ($az) {
        try {
            $token = (az account get-access-token --resource $EnvironmentUrl --query accessToken -o tsv 2>$null)
            if ([string]::IsNullOrWhiteSpace($token)) { $token = $null }
        }
        catch {
            $token = $null
        }
    }

    if (-not $token) {
        Write-Host "Azure CLI token not available - falling back to device-code sign-in."
        Write-Host "(Install/login Azure CLI with 'az login' to skip this step next time.)"
        $token = Get-DeviceCodeToken -EnvironmentUrl $EnvironmentUrl
    }

    $script:DataverseContext = [pscustomobject]@{
        EnvironmentUrl = $EnvironmentUrl
        ApiUrl         = "$EnvironmentUrl/api/data/v9.2"
        Token          = $token
        UsingAzCli     = [bool]$az -and $token
    }

    return $script:DataverseContext
}

function Get-DeviceCodeToken {
    <#
    .SYNOPSIS
        Device-code OAuth fallback when Azure CLI isn't available.
    .DESCRIPTION
        Uses Microsoft's own public-client app registration for interactive
        Dataverse tooling (the same one documented across official Dataverse
        SDK samples). Prints a URL and a code - the person signing in opens
        their own browser and enters it; no credential passes through this
        process.
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
            return $tokenResponse.access_token
        }
        catch {
            $errorBody = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($errorBody.error -eq 'authorization_pending') { continue }
            throw
        }
    }

    throw "Device code sign-in timed out."
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
        [Parameter(Mandatory)] [ValidateSet('Get', 'Post', 'Patch', 'Delete')] [string] $Method,
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
        $status = $_.Exception.Response.StatusCode.value__
        if ($status -eq 404 -and $SuppressNotFoundError) {
            return $null
        }
        if ($status -eq 401 -and $script:DataverseContext.UsingAzCli) {
            # Token expired mid-run - az's own cache makes a silent refresh
            # painless, so just re-authenticate and retry once.
            Connect-Dataverse -EnvironmentUrl $script:DataverseContext.EnvironmentUrl | Out-Null
            $headers.Authorization = "Bearer $($script:DataverseContext.Token)"
            $params.Headers = $headers
            return Invoke-RestMethod @params
        }
        throw
    }
}

function Test-DataverseNotFound {
    param($Response)
    return $null -eq $Response -or ($Response.value -and $Response.value.Count -eq 0)
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
        Every Choice column in this module is backed by a global choice -
        there is no local-picklist path. Values are supplied explicitly by
        the caller and must be sequential from 100000000 by this module's own
        convention (not enforced here, since a caller might legitimately
        import an existing numbering scheme, but strongly recommended in the
        design skill: never rely on the publisher's auto-derived value
        prefix, which produces unpredictable numbers if the choice is ever
        recreated in a different environment).
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
        Image, File, Boolean, Choice. Choice REQUIRES -GlobalChoiceName -
        there is no local-picklist option in this module. DateOnly is for
        calendar facts (Time Zone Independent - the project-wide convention
        for anything that isn't a real moment in time); DateTime is for
        genuine moments - when something actually happened - and uses
        UserLocal behavior. Getting these two swapped is exactly the mistake
        the convention exists to prevent: a DateOnly column used for a
        "last synced at" timestamp would silently shift by time zone.
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
        [bool] $Required = $false,
        [Parameter(Mandatory)] [string] $SolutionUniqueName,
        [int] $LanguageCode = 1033
    )

    $attributeLogicalName = $SchemaName.ToLowerInvariant()
    if (Test-DataverseColumn -EntityLogicalName $EntityLogicalName -AttributeLogicalName $attributeLogicalName) {
        Write-Host "  skip   $EntityLogicalName.$attributeLogicalName"
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
            if (-not $GlobalChoiceName) {
                throw "Add-DataverseColumn -Type Choice requires -GlobalChoiceName. This module has no local-picklist path by design."
            }
            $globalChoiceId = Get-DataverseGlobalChoiceId -Name $GlobalChoiceName
            @{ '@odata.type' = 'Microsoft.Dynamics.CRM.PicklistAttributeMetadata'; SchemaName = $SchemaName
               DisplayName = $displayLabel
               'GlobalOptionSet@odata.bind' = "/GlobalOptionSetDefinitions($globalChoiceId)" }
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

function New-DataverseAlternateKey {
    <#
    .SYNOPSIS
        Idempotent alternate key creation, tolerant of the async-creation
        race documented in the module header.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $EntityLogicalName,
        [Parameter(Mandatory)] [string] $KeySchemaName,
        [Parameter(Mandatory)] [string] $DisplayName,
        [Parameter(Mandatory)] [string[]] $KeyAttributes,
        [Parameter(Mandatory)] [string] $SolutionUniqueName,
        [int] $LanguageCode = 1033
    )

    if (Test-DataverseAlternateKey -EntityLogicalName $EntityLogicalName -KeySchemaName $KeySchemaName) {
        Write-Host "  skip   alternate key $EntityLogicalName.$KeySchemaName"
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

function Set-DataverseFieldSecured {
    <#
    .SYNOPSIS
        Marks an existing column as IsSecured=true, if it isn't already.
        Required before any FieldPermission can reference it - Dataverse
        rejects field permission creation on an unsecured column outright.
    .PARAMETER AttributeType
        The concrete attribute metadata type name (e.g. "MoneyAttributeMetadata"),
        needed to address the typed PATCH endpoint the Web API requires for
        attribute metadata updates.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $EntityLogicalName,
        [Parameter(Mandatory)] [string] $AttributeLogicalName,
        [Parameter(Mandatory)] [string] $AttributeType,
        [Parameter(Mandatory)] [string] $SolutionUniqueName
    )

    $current = Invoke-DataverseApi -Method Get `
        -Path "EntityDefinitions(LogicalName='$EntityLogicalName')/Attributes(LogicalName='$AttributeLogicalName')?`$select=IsSecured"
    if ($current.IsSecured -eq $true) {
        Write-Host "  skip   $EntityLogicalName.$AttributeLogicalName already secured"
        return
    }

    $path = "EntityDefinitions(LogicalName='$EntityLogicalName')/Attributes(LogicalName='$AttributeLogicalName')/Microsoft.Dynamics.CRM.$AttributeType"
    Invoke-DataverseApi -Method Patch -Path $path -Body @{ IsSecured = $true } -SolutionUniqueName $SolutionUniqueName | Out-Null
    Write-Host "  create secured $EntityLogicalName.$AttributeLogicalName"
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

Export-ModuleMember -Function *
