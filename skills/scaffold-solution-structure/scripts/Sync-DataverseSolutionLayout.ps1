#Requires -Version 7.0
<#
.SYNOPSIS
    Scaffolds a horizontal-segmentation solution topology (see
    ../../validate-solution-structure/references/solution-layout-format.md) -
    ensures every layer's publisher and solution exist live, then pulls each
    one down as a git-trackable local folder via `pac solution clone`.
.DESCRIPTION
    Works identically whether a layer's solution is brand-new (an empty org)
    or already has real content (an existing org used ad hoc without ever
    getting a local repo) - `pac solution clone` produces a correct result
    either way. See ../references/pac-cli-dependency.md for why this script
    - unlike the rest of this plugin - has a hard, required PAC CLI
    dependency: unpacking a solution into git-trackable source is `pac
    solution clone`'s own core competency, not something reimplemented here
    via raw REST.

    Every step is create-if-missing / clone-if-not-already-local - safe to
    re-run after fixing one failure partway through. A layer whose local
    folder already exists is skipped outright, never re-cloned over -
    re-cloning could silently discard local uncommitted edits a developer
    made since the last clone.
.PARAMETER LayoutPath
    Path to the solution layout JSON file.
.PARAMETER EnvironmentUrl
    Dataverse environment URL. Optional - if omitted, resolved via
    Resolve-DataverseEnvironmentUrl (PAC CLI's own auth cache), same as
    deploy-dataverse-schema.
.PARAMETER RepoRoot
    Local directory the solutions are cloned into (default: current
    directory). All layers share one root - `pac solution clone` supports
    multiple solutions under one repository root natively.
.EXAMPLE
    ./Sync-DataverseSolutionLayout.ps1 -LayoutPath ./solution-layout.json -EnvironmentUrl https://your-org.crm.dynamics.com
#>
[CmdletBinding()]
param(
    [string] $LayoutPath = 'solution-layout.json',
    [string] $EnvironmentUrl,
    [string] $RepoRoot = '.'
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '../../deploy-dataverse-schema/scripts/Dataverse.psm1') -Force

# --- Preflight: this skill has a hard pac CLI dependency, unlike the rest --------
# of this plugin. Fail fast and clearly here rather than partway through,
# after publishers/solutions may already have been created live.

$pac = Get-Command pac -ErrorAction SilentlyContinue
if (-not $pac) {
    throw "This skill requires PAC CLI ('pac') to be installed - it does the actual solution-unpacking work (pac solution clone), which this plugin doesn't reimplement via raw REST. Install it (see Microsoft's Power Platform CLI docs) and run 'pac auth create --environment <url>' before re-running this script."
}

# --- Validate layout shape before making any API call ----------------------------

$resolved = Get-DataverseSolutionLayout -LayoutPath $LayoutPath
$layout = $resolved.Layout

Write-Host "Layout validated: $($layout.layers.Count) layers, publisher '$($layout.publisherUniqueName)', no dependency cycle."
Write-Host ""

$EnvironmentUrl = Resolve-DataverseEnvironmentUrl -EnvironmentUrl $EnvironmentUrl
Connect-Dataverse -EnvironmentUrl $EnvironmentUrl | Out-Null

# --- Preflight: warn (don't block) if pac's own auth doesn't look pointed --------
# at the same environment. pac solution clone uses PAC CLI's OWN auth
# profile, entirely separate from Get-DataverseToken's - this module
# creating a publisher/solution successfully via REST proves nothing about
# whether `pac` itself is authenticated against the same org.

$pacEnvironments = Get-DataverseEnvironmentsFromPac
if ($pacEnvironments) {
    $targetHost = ([Uri]$EnvironmentUrl).Host
    $activeMatches = @($pacEnvironments | Where-Object { $_.IsActive -and ([Uri]$_.EnvironmentUrl).Host -eq $targetHost })
    if ($activeMatches.Count -eq 0) {
        Write-Warning "PAC CLI's active auth profile doesn't appear to point at $EnvironmentUrl - 'pac solution clone' below may target the wrong environment. Run 'pac auth create --environment $EnvironmentUrl' (or 'pac auth select') first if this isn't intentional."
    }
}
else {
    Write-Warning "Could not confirm PAC CLI's active auth profile (pac auth list returned nothing readable). Proceeding - 'pac solution clone' will use whatever pac's own current profile is."
}
Write-Host ""

# --- 1. Publisher (once, shared by every layer) -----------------------------------

Write-Host "== Publisher =="
$publisherId = Get-DataversePublisherId -UniqueName $layout.publisherUniqueName
if ($publisherId) {
    Write-Host "  ok       publisher $($layout.publisherUniqueName) already exists"
}
else {
    $publisherFriendlyName = Get-DataverseOptionalValue $layout 'publisherFriendlyName'
    $publisherPrefix = Get-DataverseOptionalValue $layout 'publisherPrefix'
    if (-not $publisherFriendlyName -or -not $publisherPrefix) {
        throw "Publisher '$($layout.publisherUniqueName)' doesn't exist yet in this environment, and the layout is missing 'publisherFriendlyName'/'publisherPrefix' needed to create it. Add both to $LayoutPath, or point -EnvironmentUrl at an environment where this publisher already exists."
    }
    $publisherId = New-DataversePublisher -UniqueName $layout.publisherUniqueName -FriendlyName $publisherFriendlyName -Prefix $publisherPrefix
}

# --- 2. Solution + local clone, per layer -----------------------------------------

Write-Host ""
Write-Host "== Layers =="
foreach ($layer in $layout.layers) {
    Write-Host "-- $($layer.name) ($($layer.solutionUniqueName)) --"

    $solution = Get-DataverseSolutionByUniqueName -UniqueName $layer.solutionUniqueName
    if ($solution) {
        Write-Host "  ok       solution $($layer.solutionUniqueName) already exists"
    }
    else {
        $solutionFriendlyName = Get-DataverseOptionalValue $layer 'solutionFriendlyName'
        if (-not $solutionFriendlyName) { $solutionFriendlyName = $layer.solutionUniqueName }
        New-DataverseSolution -UniqueName $layer.solutionUniqueName -FriendlyName $solutionFriendlyName -PublisherId $publisherId
    }

    $localPath = Join-Path $RepoRoot "solutions/$($layer.solutionUniqueName)"
    if (Test-Path $localPath) {
        Write-Host "  skip     local clone already exists at $localPath - not re-cloning (would risk discarding local edits)"
    }
    else {
        Write-Host "  clone    $($layer.solutionUniqueName) -> $RepoRoot"
        & pac solution clone --name $layer.solutionUniqueName --outputDirectory $RepoRoot
        if ($LASTEXITCODE -ne 0) {
            throw "pac solution clone failed for '$($layer.solutionUniqueName)' (exit code $LASTEXITCODE) - see its output above. Fix the underlying issue and re-run; layers already cloned are skipped, not repeated."
        }
    }
}

Write-Host ""
Write-Host "== Done =="
Write-Host "Re-run any time - publisher/solution creation is create-if-missing, and an already-cloned layer is never re-cloned automatically."
