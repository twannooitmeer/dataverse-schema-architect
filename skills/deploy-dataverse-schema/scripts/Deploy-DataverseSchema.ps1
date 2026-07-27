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
    Dataverse environment URL, e.g. https://your-org.crm.dynamics.com
.EXAMPLE
    ./Deploy-DataverseSchema.ps1 -SpecPath ./dataverse-schema.json -EnvironmentUrl https://your-org.crm.dynamics.com
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $SpecPath,
    [Parameter(Mandatory)] [string] $EnvironmentUrl
)

Set-StrictMode -Version Latest
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

$validOwnership = @('UserOwned', 'OrganizationOwned')
$validColumnTypes = @('String', 'Memo', 'Integer', 'Decimal', 'Money', 'DateOnly', 'Image', 'File', 'Boolean', 'Choice')
$validCascades = @('Referential', 'ReferentialRestrictDelete', 'Parental')

foreach ($table in $spec.tables) {
    if ($table.ownership -notin $validOwnership) {
        throw "Table '$($table.logicalName)': ownership must be one of $($validOwnership -join ', '), got '$($table.ownership)'."
    }
    foreach ($column in $table.columns) {
        if ($column.type -notin $validColumnTypes) {
            throw "Table '$($table.logicalName)' column '$($column.schemaName)': type must be one of $($validColumnTypes -join ', '), got '$($column.type)'."
        }
        if ($column.type -eq 'Choice' -and -not $column.globalChoiceName) {
            throw "Table '$($table.logicalName)' column '$($column.schemaName)': type Choice requires globalChoiceName. There is no local-picklist path in this plugin."
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

Connect-Dataverse -EnvironmentUrl $EnvironmentUrl | Out-Null

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

    New-DataverseTable -LogicalName $table.logicalName -DisplayName $table.displayName `
        -PluralDisplayName $table.pluralDisplayName -Description $table.description `
        -Ownership $table.ownership `
        -PrimaryAttributeSchemaName $table.primaryAttribute.schemaName `
        -PrimaryAttributeDisplayName $table.primaryAttribute.displayName `
        -PrimaryAttributeMaxLength $primaryMaxLength `
        -SolutionUniqueName $spec.solutionUniqueName
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
        if ($null -ne $column.minValue) { $params.MinValue = $column.minValue }
        if ($null -ne $column.maxValue) { $params.MaxValue = $column.maxValue }
        if ($column.precision) { $params.Precision = $column.precision }
        if ($column.maxSizeInKb) { $params.MaxSizeInKb = $column.maxSizeInKb }
        if ($column.globalChoiceName) { $params.GlobalChoiceName = $column.globalChoiceName }

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
