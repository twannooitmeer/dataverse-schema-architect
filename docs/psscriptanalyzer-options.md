# PSScriptAnalyzer options

Not a decision, just the numbers. `docs/microsoft-power-platform-skills-overlap.md`
and `.github/workflows/ci.yml` both note that a PSScriptAnalyzer lint job was
evaluated on 2026-09-02 and deliberately not added, because the default
ruleset reports 123 warnings cold, almost all of them a rule this project
already knowingly violates on purpose. That evaluation is re-run here against
the current tree with `PSScriptAnalyzer 1.25.0`, and a second, curated
ruleset is added so there is an actual choice to make rather than a single
number to accept or reject.

Scanned: everything under `skills/` and `hooks/` (`Dataverse.psm1`,
`Deploy-DataverseSchema.ps1`, `Sync-DataverseSolutionLayout.ps1`,
`Test-SolutionStructure.ps1`, and the two hook scripts).

```powershell
Import-Module PSScriptAnalyzer
Invoke-ScriptAnalyzer -Path "skills" -Recurse
Invoke-ScriptAnalyzer -Path "hooks" -Recurse
```

## Option A: default ruleset (every built-in rule, no exclusions)

**123 warnings, 0 errors.**

| Rule | Count | What it flags |
|---|---:|---|
| `PSAvoidUsingWriteHost` | 101 | Any `Write-Host` call |
| `PSUseShouldProcessForStateChangingFunctions` | 11 | A function with a state-changing verb (`New-`, `Set-`, `Add-`) that doesn't implement `ShouldProcess`/`-WhatIf`/`-Confirm` the PowerShell-native way |
| `PSUseSingularNouns` | 4 | A function noun that's plural (e.g. `-Columns`, `-Roles`) |
| `PSAvoidAssignmentToAutomaticVariable` | 2 | Assigning to a name PowerShell reserves for itself (`$profile`, both in `Dataverse.psm1:2124` and `Deploy-DataverseSchema.ps1:301`) |
| `PSReviewUnusedParameter` | 2 | A declared function parameter that's never read in its body |
| `PSUseDeclaredVarsMoreThanAssignments` | 2 | A variable assigned once and never read again |
| `PSAvoidUsingEmptyCatchBlock` | 1 | A `catch {}` with no body (`Dataverse.psm1:164`) |

101 of 123 warnings (82%) are the one rule this project already holds a
written, deliberate exception for: `Write-Host` is how these scripts talk to
a human running them interactively, not a bug (see the "if a rule cannot
name its incident, it does not belong here" standard in
`skills/deploy-dataverse-schema/references/safety-rules.md`, and the CI
comment this doc supersedes with real numbers). Gating CI on this ruleset
as-is means CI is red from the first commit over something the project
doesn't actually consider wrong.

## Option B: curated ruleset (`PSAvoidUsingWriteHost` excluded, everything else default)

**22 warnings, 0 errors.**

```powershell
Invoke-ScriptAnalyzer -Path "skills" -Recurse -ExcludeRule PSAvoidUsingWriteHost
Invoke-ScriptAnalyzer -Path "hooks" -Recurse -ExcludeRule PSAvoidUsingWriteHost
```

| Rule | Count | Locations |
|---|---:|---|
| `PSUseShouldProcessForStateChangingFunctions` | 11 | `Dataverse.psm1:913, 948, 1011, 1066, 1431, 1502, 1538, 1550, 1766, 1815, 1902` |
| `PSUseSingularNouns` | 4 | `Dataverse.psm1:1684, 1886, 2219, 2271` |
| `PSAvoidAssignmentToAutomaticVariable` | 2 | `Dataverse.psm1:2124`, `Deploy-DataverseSchema.ps1:301` |
| `PSReviewUnusedParameter` | 2 | `Dataverse.psm1:928, 1079` |
| `PSUseDeclaredVarsMoreThanAssignments` | 2 | `Dataverse.psm1:1825, 1944` |
| `PSAvoidUsingEmptyCatchBlock` | 1 | `Dataverse.psm1:164` |

This is the same 22 warnings that survive Option A once the one excluded
rule is removed; nothing else changes between the two options. Unlike
`PSAvoidUsingWriteHost`, none of these six rules have a written exception
anywhere in this repo today, so each one is either a real (if minor) issue
to fix, or a rule that would need its own named exception the same way
`Write-Host` has one, not a blanket exclude.

A rough read of what's actually behind each remaining rule, for whoever
picks:

- **`PSUseShouldProcessForStateChangingFunctions` (11)**: every `New-Dataverse*`/`Add-Dataverse*`/`Set-Dataverse*` function in the module. This project already has its own state-change safety mechanism (create-if-missing idempotency, the environment allowlist, `-WhatIf` on the top-level deploy script), built independently of PowerShell's `ShouldProcess` convention. Adopting this rule as-is would mean either suppressing it with the same kind of named exception `Write-Host` has, or retrofitting `ShouldProcess` onto eleven functions that already have a different, working safety story.
- **`PSUseSingularNouns` (4)**: naming only, no behavior change. Cheapest of the six to actually fix, at the cost of a breaking rename if anything outside this repo calls these functions by name.
- **`PSAvoidAssignmentToAutomaticVariable` (2)**: both are `$profile`, not the built-in `$PROFILE`, so this is very likely a real, worth-fixing shadowing risk rather than noise.
- **`PSReviewUnusedParameter` (2)**: worth a look each; could be dead parameters or could be a hook for a case that's genuinely not implemented yet.
- **`PSUseDeclaredVarsMoreThanAssignments` (2)**: usually a genuine leftover from a refactor.
- **`PSAvoidUsingEmptyCatchBlock` (1)**: worth checking specifically, an empty catch is exactly the shape of bug this project's own incident list (silent failures, masked errors) already warns about elsewhere in the codebase.

## For Twan to decide

- **Option A (default, unmodified)**: matches Microsoft's own upstream CI approach most literally, but starts red and stays red until `Write-Host` itself is reworked or the rule is suppressed some other way.
- **Option B (`PSAvoidUsingWriteHost` excluded)**: starts at 22 warnings, all of them real candidates for either a fix or an explicit named suppression, none of them contradicting a standing decision this project has already made.
- **Neither, yet**: leave CI as it is today (`version-bump` only) until there's time to actually clear or suppress the 22, so a lint job's first day isn't spent red over a backlog rather than new code.

Whichever is picked, `docs/microsoft-power-platform-skills-overlap.md` and
the comment block in `.github/workflows/ci.yml` should be updated to point
at this doc instead of repeating the "123 warnings, evaluated and deferred"
summary on their own.
