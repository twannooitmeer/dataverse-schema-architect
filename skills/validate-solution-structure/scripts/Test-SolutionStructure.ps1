#Requires -Version 7.0
<#
.SYNOPSIS
    Checks whether live Dataverse solution components actually match a
    declared horizontal-segmentation topology (see
    ../references/solution-layout-format.md) - the same allowlist-per-solution
    mechanism Microsoft's own FastTrack Solution Component Validation Tool
    uses, run on demand instead of as an installed, always-on watcher.
.DESCRIPTION
    Entirely read-only against `solutions` and `solutioncomponents` - this
    script never creates, updates, or reassigns anything. See
    ../references/checks.md for what each check catches and why.
.PARAMETER LayoutPath
    Path to the solution layout JSON file (see
    ../references/solution-layout-format.md).
.PARAMETER EnvironmentUrl
    Dataverse environment URL. Optional - if omitted, resolved via
    Resolve-DataverseEnvironmentUrl (PAC CLI's own auth cache), same as
    deploy-dataverse-schema. There is no environment-allowlist guard here
    unlike the deploy script - this tool never writes anything, so the
    write-safety reasoning that guard exists for doesn't apply.
.EXAMPLE
    ./Test-SolutionStructure.ps1 -LayoutPath ./solution-layout.json -EnvironmentUrl https://your-org.crm.dynamics.com
#>
[CmdletBinding()]
param(
    [string] $LayoutPath = 'solution-layout.json',
    [string] $EnvironmentUrl
)

# Deliberately NOT Set-StrictMode here, matching Deploy-DataverseSchema.ps1's
# own reasoning: this script's job is reading a human-authored JSON topology
# file where some shape mistakes need a clear thrown message, not a generic
# "property not found" - explicit checks below do that job instead of
# relying on strict mode to catch it as a side effect.
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '../../deploy-dataverse-schema/scripts/Dataverse.psm1') -Force

if (-not (Test-Path $LayoutPath)) {
    throw "Solution layout file not found: $LayoutPath. See ../references/solution-layout-format.md for the expected shape."
}

$layout = Get-Content -Path $LayoutPath -Raw | ConvertFrom-Json -Depth 10

# --- Validate shape before making any API call ----------------------------------

if (-not $layout.publisherUniqueName) {
    throw "Layout is missing required top-level 'publisherUniqueName'. Every layer's solution is expected to share this publisher - see references/checks.md for why that's checked first."
}
if (-not $layout.layers -or @($layout.layers).Count -eq 0) {
    throw "Layout has no 'layers' - nothing to check. See references/solution-layout-format.md."
}

$layerNames = @{}
foreach ($layer in $layout.layers) {
    if (-not $layer.name) { throw "A layer is missing required 'name'." }
    if ($layerNames.ContainsKey($layer.name)) { throw "Layer name '$($layer.name)' is declared more than once - names must be unique within one layout file." }
    if (-not $layer.solutionUniqueName) { throw "Layer '$($layer.name)' is missing required 'solutionUniqueName'." }
    $layerNames[$layer.name] = $layer
}

foreach ($layer in $layout.layers) {
    foreach ($dep in @($layer.dependsOn)) {
        if (-not $layerNames.ContainsKey($dep)) {
            throw "Layer '$($layer.name)' declares dependsOn '$dep', which doesn't match any layer's 'name' in this file."
        }
    }
}

# Cycle detection over the dependsOn graph - plain DFS with a recursion-stack
# set, same idea as any topological-sort cycle check. This is the one check
# in this script that never touches the network - see references/checks.md
# for why the actual, Dataverse-enforced import order isn't verified here.
function Test-DependencyCycle {
    param([hashtable] $LayerNames)

    $visited = @{}
    $inStack = @{}

    function Visit {
        param([string] $Name, [hashtable] $LayerNames, [hashtable] $Visited, [hashtable] $InStack)
        if ($InStack[$Name]) { return $Name }
        if ($Visited[$Name]) { return $null }
        $Visited[$Name] = $true
        $InStack[$Name] = $true
        foreach ($dep in @($LayerNames[$Name].dependsOn)) {
            $cycleAt = Visit -Name $dep -LayerNames $LayerNames -Visited $Visited -InStack $InStack
            if ($cycleAt) { return $cycleAt }
        }
        $InStack[$Name] = $false
        return $null
    }

    foreach ($name in $LayerNames.Keys) {
        $cycleAt = Visit -Name $name -LayerNames $LayerNames -Visited $visited -InStack $inStack
        if ($cycleAt) { return $cycleAt }
    }
    return $null
}

$cycleAt = Test-DependencyCycle -LayerNames $layerNames
if ($cycleAt) {
    throw "Layout's dependsOn graph has a cycle involving layer '$cycleAt'. Fix the declared dependencies before running this check against a live environment."
}

Write-Host "Layout validated: $($layout.layers.Count) layers, publisher '$($layout.publisherUniqueName)', no dependency cycle."
Write-Host ""

$EnvironmentUrl = Resolve-DataverseEnvironmentUrl -EnvironmentUrl $EnvironmentUrl
Connect-Dataverse -EnvironmentUrl $EnvironmentUrl | Out-Null

# --- Resolve every layer's solution, fetch its components ------------------------

$resolvedLayers = [System.Collections.Generic.List[pscustomobject]]::new()

Write-Host "== Resolving layers =="
foreach ($layer in $layout.layers) {
    $solution = Get-DataverseSolutionByUniqueName -UniqueName $layer.solutionUniqueName
    if (-not $solution) {
        Write-Host "  missing  $($layer.name) (solution '$($layer.solutionUniqueName)' doesn't exist in this environment yet)"
        continue
    }

    $components = Get-DataverseSolutionComponents -SolutionId $solution.solutionid
    Write-Host "  ok       $($layer.name) -> '$($solution.friendlyname)' ($($layer.solutionUniqueName)): $($components.Count) component(s)"

    $resolvedLayers.Add([pscustomobject]@{
        Name                  = $layer.name
        Solution              = $solution
        AllowedComponentTypes = @($layer.allowedComponentTypes)
        Components            = $components
    })
}

# --- 1. Component-type drift, per layer -------------------------------------------

Write-Host ""
Write-Host "== Component-type drift =="
$anyDrift = $false
foreach ($resolved in $resolvedLayers) {
    $violations = $resolved.Components | Where-Object { $_.componenttype -notin $resolved.AllowedComponentTypes }
    if (@($violations).Count -eq 0) {
        Write-Host "  clean    $($resolved.Name) - every component matches its allowed types"
        continue
    }
    $anyDrift = $true
    $grouped = $violations | Group-Object -Property componenttype
    foreach ($group in $grouped) {
        $typeName = Get-DataverseSolutionComponentTypeName -ComponentType ([int]$group.Name)
        Write-Host "  drift    $($resolved.Name): $($group.Count) component(s) of type '$typeName' not in this layer's allowlist"
    }
}
if (-not $anyDrift) { Write-Host "  (no drift found in any resolved layer)" }

# --- 2. Cross-layer duplicate ownership -------------------------------------------

Write-Host ""
Write-Host "== Cross-layer duplicate ownership =="
$ownersByComponent = @{}
foreach ($resolved in $resolvedLayers) {
    foreach ($component in $resolved.Components) {
        $key = "$($component.componenttype):$($component.objectid)"
        if (-not $ownersByComponent.ContainsKey($key)) { $ownersByComponent[$key] = [System.Collections.Generic.List[string]]::new() }
        $ownersByComponent[$key].Add($resolved.Name)
    }
}
$duplicates = $ownersByComponent.GetEnumerator() | Where-Object { $_.Value.Count -gt 1 }
if (@($duplicates).Count -eq 0) {
    Write-Host "  (no component found in more than one monitored layer)"
}
else {
    foreach ($dup in $duplicates) {
        $parts = $dup.Key -split ':', 2
        $typeName = Get-DataverseSolutionComponentTypeName -ComponentType ([int]$parts[0])
        Write-Host "  DUPLICATE  $typeName $($parts[1]) is owned by more than one layer: $($dup.Value -join ', ')"
    }
}

# --- 3. Publisher consistency ------------------------------------------------------

Write-Host ""
Write-Host "== Publisher consistency =="
$anyMismatch = $false
foreach ($resolved in $resolvedLayers) {
    $publisherUniqueName = $resolved.Solution.publisherid.uniquename
    if ($publisherUniqueName -ne $layout.publisherUniqueName) {
        $anyMismatch = $true
        Write-Host "  MISMATCH   $($resolved.Name) resolves to publisher '$publisherUniqueName', expected '$($layout.publisherUniqueName)'"
    }
    else {
        Write-Host "  ok       $($resolved.Name) -> publisher '$publisherUniqueName'"
    }
}
if ($anyMismatch) {
    Write-Host ""
    Write-Host "  A publisher mismatch means a component genuinely cannot be shared between the affected layer and the rest of the topology without being deleted and recreated - treat this as the highest-priority finding above, not equal weight with component-type drift."
}

Write-Host ""
Write-Host "== Done =="
Write-Host "Nothing above was created, updated, or moved - this is a read-only report. See ../references/checks.md for what each finding means and what it doesn't check."
