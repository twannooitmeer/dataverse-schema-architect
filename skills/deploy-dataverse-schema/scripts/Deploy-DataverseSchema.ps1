#Requires -Version 7.0
<#
.SYNOPSIS
    Idempotently deploys a Dataverse schema spec (see ../references/spec-format.md)
    produced by the design-data-model skill.
.DESCRIPTION
    Fixed processing order regardless of the spec file's own array order:
    global choices -> tables + primary attribute -> columns -> lookups ->
    alternate keys -> views -> security roles -> field security profiles.
    This mirrors the validated order from the reference implementation this
    plugin generalizes from - each category depends on the ones before it
    existing first.

    Every step is create-if-missing, via Dataverse.psm1 - safe to re-run the
    same spec file after fixing one failure partway through.
.PARAMETER SpecPath
    Path to the schema spec JSON file.
.PARAMETER EnvironmentUrl
    Dataverse environment URL, e.g. https://your-org.crm.dynamics.com. Optional -
    if omitted, resolved via Resolve-DataverseEnvironmentUrl (PAC CLI's own
    `pac auth list` auth cache). Discovery only ever fills in what you didn't
    say; it never overrides an -EnvironmentUrl you did pass.
.PARAMETER AllowedEnvironmentUrls
    Optional allowlist of environment URLs/hosts this run is permitted to
    target. Same effect as the DATAVERSE_ALLOWED_ENVIRONMENTS environment
    variable (semicolon-separated); this parameter takes precedence if both
    are set. Unset by default, which blocks nothing - this is an opt-in
    prod-safety guard, not a mandatory gate.
.PARAMETER Force
    Bypasses the allowlist check entirely. Use when you deliberately intend
    to deploy outside the configured allowlist.
.EXAMPLE
    ./Deploy-DataverseSchema.ps1 -SpecPath ./dataverse-schema.json -EnvironmentUrl https://your-org.crm.dynamics.com
.EXAMPLE
    ./Deploy-DataverseSchema.ps1 -SpecPath ./dataverse-schema.json
    # Resolves the target environment from PAC CLI's active auth profile.
.EXAMPLE
    ./Deploy-DataverseSchema.ps1 -SpecPath ./dataverse-schema.json -EnvironmentUrl https://your-org.crm.dynamics.com -WhatIf
    # Prints a create/skip preview against the live environment - see
    # Show-DataverseWhatIfPlan in Dataverse.psm1 for exactly what is and
    # isn't previewed. Nothing is created, updated, or deleted.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $SpecPath,
    [string] $EnvironmentUrl,
    [string[]] $AllowedEnvironmentUrls,
    [switch] $Force
)

# Deliberately NOT Set-StrictMode here (unlike Dataverse.psm1, which keeps it
# for its own internal code discipline). This script's whole job is reading a
# partially-optional external JSON spec - most column/lookup properties
# (required, maxLength, format, minValue...) are legitimately absent on many
# entries, and under strict mode ANY read of a property a given object simply
# doesn't have throws "cannot be found on this object", not just genuine
# typos. Hit this for real on the very first live run: a column with no
# "required" key in the spec (correctly meaning "not required") crashed the
# whole deploy after two tables had already been created. Strict mode was
# fighting the exact shape of data this script needs to accept.
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Dataverse.psm1') -Force

if (-not (Test-Path $SpecPath)) {
    throw "Spec file not found: $SpecPath"
}

$spec = Get-Content -Path $SpecPath -Raw | ConvertFrom-Json -Depth 20

# --- Validate shape before making any API call --------------------------------

if (-not $spec.solutionUniqueName) {
    throw "Spec is missing required top-level 'solutionUniqueName'. Every create call in this run needs a target solution - see references/spec-format.md."
}

# publisherUniqueName is optional - a spec targeting a solution that's
# already known to exist doesn't need it, and omitting it keeps every spec
# written before this feature existed working unchanged. Declaring it opts
# into auto-creating the publisher and solution if either is missing (a
# brand-new environment) - see New-DataversePublisher/New-DataverseSolution
# in Dataverse.psm1.
if ($spec.publisherUniqueName -and (-not $spec.publisherFriendlyName -or -not $spec.publisherPrefix)) {
    throw "Spec declares 'publisherUniqueName' but is missing 'publisherFriendlyName' and/or 'publisherPrefix' - all three are required together, or omit publisherUniqueName entirely to assume the publisher and solution already exist. See references/spec-format.md."
}

$validOwnership = @('UserOwned', 'OrganizationOwned')
$validColumnTypes = @('String', 'Memo', 'Integer', 'Decimal', 'Money', 'DateOnly', 'DateTime', 'Image', 'File', 'Boolean', 'Choice')
$validCascades = @('Referential', 'ReferentialRestrictDelete', 'Parental')

foreach ($table in $spec.tables) {
    if ($table.ownership -notin $validOwnership) {
        throw "Table '$($table.logicalName)': ownership must be one of $($validOwnership -join ', '), got '$($table.ownership)'."
    }
    foreach ($column in $table.columns) {
        if ($column.type -notin $validColumnTypes) {
            throw "Table '$($table.logicalName)' column '$($column.schemaName)': type must be one of $($validColumnTypes -join ', '), got '$($column.type)'."
        }
        if ($column.type -eq 'Choice') {
            $hasGlobal = [bool]$column.globalChoiceName
            $hasLocal = $column.localOptions -and @($column.localOptions).Count -gt 0
            if ($hasGlobal -and $hasLocal) {
                throw "Table '$($table.logicalName)' column '$($column.schemaName)': type Choice must specify either globalChoiceName or localOptions, not both."
            }
            if (-not $hasGlobal -and -not $hasLocal) {
                throw "Table '$($table.logicalName)' column '$($column.schemaName)': type Choice requires either globalChoiceName (recommended) or localOptions (only when a local picklist was specifically requested)."
            }
        }
    }
    foreach ($lookup in $table.lookups) {
        if ($lookup.cascade -notin $validCascades) {
            throw "Table '$($table.logicalName)' lookup '$($lookup.relationshipSchemaName)': cascade must be one of $($validCascades -join ', '), got '$($lookup.cascade)'. Raw cascade configuration is not supported - see the module header in Dataverse.psm1 for why."
        }
    }
}

Write-Host "Spec validated: $($spec.tables.Count) tables, $($spec.globalChoices.Count) global choices, targeting solution '$($spec.solutionUniqueName)'."
Write-Host ""

$EnvironmentUrl = Resolve-DataverseEnvironmentUrl -EnvironmentUrl $EnvironmentUrl
Assert-DataverseEnvironmentAllowed -EnvironmentUrl $EnvironmentUrl -AllowedEnvironmentUrls $AllowedEnvironmentUrls -Force:$Force

Connect-Dataverse -EnvironmentUrl $EnvironmentUrl | Out-Null

if ($WhatIfPreference) {
    Show-DataverseWhatIfPlan -Spec $spec
    Write-Host ""
    Write-Host "== What if: nothing was created, updated, or deleted =="
    Write-Host "Re-run without -WhatIf to actually deploy."
    return
}

# --- 0. Publisher & solution --------------------------------------------------------
# Opt-in: only runs when the spec declares publisherUniqueName (validated
# above). A spec targeting an already-existing solution doesn't need this
# step, and its absence is exactly how every spec written before this
# feature existed keeps working unchanged.

if ($spec.publisherUniqueName) {
    Write-Host "== Publisher & solution =="
    $publisherId = New-DataversePublisher -UniqueName $spec.publisherUniqueName -FriendlyName $spec.publisherFriendlyName -Prefix $spec.publisherPrefix
    $solutionFriendlyName = if ($spec.solutionFriendlyName) { $spec.solutionFriendlyName } else { $spec.solutionUniqueName }
    New-DataverseSolution -UniqueName $spec.solutionUniqueName -FriendlyName $solutionFriendlyName -PublisherId $publisherId
    Write-Host ""
}

# --- 1. Global choices ----------------------------------------------------------

Write-Host "== Global choices =="
foreach ($choice in $spec.globalChoices) {
    $options = $choice.options | ForEach-Object { @{ Value = $_.value; Label = $_.label } }
    New-DataverseGlobalChoice -Name $choice.name -DisplayName $choice.displayName -Options $options -SolutionUniqueName $spec.solutionUniqueName
}

# --- 2. Tables + primary attribute -----------------------------------------------

Write-Host ""
Write-Host "== Tables =="
foreach ($table in $spec.tables) {
    Write-Host "-- $($table.logicalName) --"
    $primaryMaxLength = 300
    if ($table.primaryAttribute.maxLength) { $primaryMaxLength = $table.primaryAttribute.maxLength }

    $tableParams = @{
        LogicalName                 = $table.logicalName
        DisplayName                 = $table.displayName
        PluralDisplayName            = $table.pluralDisplayName
        Description                  = $table.description
        Ownership                    = $table.ownership
        PrimaryAttributeSchemaName   = $table.primaryAttribute.schemaName
        PrimaryAttributeDisplayName  = $table.primaryAttribute.displayName
        PrimaryAttributeMaxLength    = $primaryMaxLength
        SolutionUniqueName           = $spec.solutionUniqueName
    }
    if ($table.primaryAttribute.autoNumberFormat) {
        $tableParams.PrimaryAttributeAutoNumberFormat = $table.primaryAttribute.autoNumberFormat
    }

    New-DataverseTable @tableParams
}

# --- 3. Columns -------------------------------------------------------------------

Write-Host ""
Write-Host "== Columns =="
foreach ($table in $spec.tables) {
    foreach ($column in $table.columns) {
        $params = @{
            EntityLogicalName   = $table.logicalName
            SchemaName          = $column.schemaName
            DisplayName         = $column.displayName
            Type                = $column.type
            SolutionUniqueName  = $spec.solutionUniqueName
            Required            = [bool]($column.required)
        }
        if ($column.maxLength) { $params.MaxLength = $column.maxLength }
        if ($column.format) { $params.StringFormat = $column.format }
        if ($column.autoNumberFormat) { $params.AutoNumberFormat = $column.autoNumberFormat }
        if ($null -ne $column.minValue) { $params.MinValue = $column.minValue }
        if ($null -ne $column.maxValue) { $params.MaxValue = $column.maxValue }
        if ($column.precision) { $params.Precision = $column.precision }
        if ($column.maxSizeInKb) { $params.MaxSizeInKb = $column.maxSizeInKb }
        if ($column.globalChoiceName) { $params.GlobalChoiceName = $column.globalChoiceName }
        if ($column.localOptions) { $params.LocalOptions = $column.localOptions | ForEach-Object { @{ Value = $_.value; Label = $_.label } } }

        Add-DataverseColumn @params
    }
}

# --- 4. Lookups (relationships) --------------------------------------------------

Write-Host ""
Write-Host "== Relationships =="
foreach ($table in $spec.tables) {
    foreach ($lookup in $table.lookups) {
        Add-DataverseLookup -RelationshipSchemaName $lookup.relationshipSchemaName `
            -ReferencedEntity $lookup.referencedEntity -ReferencingEntity $table.logicalName `
            -LookupSchemaName $lookup.lookupSchemaName -LookupDisplayName $lookup.lookupDisplayName `
            -Cascade $lookup.cascade -Required ([bool]($lookup.required)) `
            -SolutionUniqueName $spec.solutionUniqueName
    }
}

# --- 5. Alternate keys ------------------------------------------------------------

Write-Host ""
Write-Host "== Alternate keys =="
foreach ($table in $spec.tables) {
    foreach ($key in $table.alternateKeys) {
        New-DataverseAlternateKey -EntityLogicalName $table.logicalName -KeySchemaName $key.schemaName `
            -DisplayName $key.displayName -KeyAttributes $key.keyAttributes -SolutionUniqueName $spec.solutionUniqueName
    }
}

# --- 6. Views ---------------------------------------------------------------------

Write-Host ""
Write-Host "== Views =="
foreach ($view in $spec.views) {
    $table = $spec.tables | Where-Object { $_.logicalName -eq $view.entityLogicalName } | Select-Object -First 1
    $pluralDisplayName = if ($table) { $table.pluralDisplayName } else { $view.entityLogicalName }

    $fetchXml = New-FetchXml -EntityLogicalName $view.entityLogicalName -Attributes $view.attributes `
        -OrderAttribute $view.orderAttribute -FilterXml $view.filterXml
    $layoutXml = New-LayoutXml -EntityLogicalName $view.entityLogicalName -Attributes $view.attributes

    New-DataverseView -EntityLogicalName $view.entityLogicalName -Name $view.name -FetchXml $fetchXml `
        -LayoutXml $layoutXml -PluralDisplayName $pluralDisplayName -SolutionUniqueName $spec.solutionUniqueName
}

# --- 7. Security roles -------------------------------------------------------------

Write-Host ""
Write-Host "== Security roles =="
if ($spec.securityRoles -and $spec.securityRoles.Count -gt 0) {
    $whoAmI = Invoke-DataverseApi -Method Get -Path 'WhoAmI'
    foreach ($role in $spec.securityRoles) {
        $grants = $role.grants | ForEach-Object { @{ Entity = $_.entity; Type = $_.type; Depth = $_.depth } }
        New-DataverseSecurityRole -Name $role.name -BusinessUnitId $whoAmI.BusinessUnitId -Grants $grants -SolutionUniqueName $spec.solutionUniqueName
    }
}

# --- 8. Field security profiles -----------------------------------------------------

Write-Host ""
Write-Host "== Field security =="
foreach ($profile in $spec.fieldSecurityProfiles) {
    $profileId = New-DataverseFieldSecurityProfile -Name $profile.name -SolutionUniqueName $spec.solutionUniqueName
    foreach ($permission in $profile.permissions) {
        $canRead = $true
        if ($null -ne $permission.canRead) { $canRead = [bool]$permission.canRead }
        $canCreate = $true
        if ($null -ne $permission.canCreate) { $canCreate = [bool]$permission.canCreate }
        $canUpdate = $true
        if ($null -ne $permission.canUpdate) { $canUpdate = [bool]$permission.canUpdate }

        Add-DataverseFieldPermission -FieldSecurityProfileId $profileId `
            -EntityLogicalName $permission.entityLogicalName -AttributeLogicalName $permission.attributeLogicalName `
            -AttributeType $permission.attributeType -SolutionUniqueName $spec.solutionUniqueName `
            -CanRead $canRead -CanCreate $canCreate -CanUpdate $canUpdate
    }
}

Write-Host ""
Write-Host "== Done =="
Write-Host "Re-run any time against the same spec - every step above is create-if-missing."
