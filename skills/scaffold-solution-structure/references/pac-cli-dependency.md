# Why this skill requires PAC CLI, unlike the rest of this plugin

Every other skill in this plugin works with nothing beyond PowerShell 7+ and, optionally, Azure CLI or PAC CLI as one of several interchangeable auth/discovery conveniences (see `deploy-dataverse-schema/references/safety-rules.md`) — never a hard requirement. This skill breaks that pattern deliberately.

## The reason: unpacking a solution into git-trackable source is `pac`'s own job

`pac solution clone` (and the YAML source-control format it produces) is a mature, actively-maintained Microsoft capability — turning a live Dataverse solution's components into a correct, packable, human-reviewable folder structure (`solutions/<name>/solution.yml`, `publishers/<name>/publisher.yml`, per-component-type folders, dependency manifests). Reimplementing that via raw Web API calls would mean rebuilding a meaningful slice of SolutionPackager's own logic — a large, high-risk undertaking with no benefit over the tool that already does it correctly and stays current as Dataverse's component model grows. This plugin's own "no external CLI required" default exists for the parts of the job (table/column/relationship/role creation) that are simple enough to get right in a few hundred lines of REST calls; solution packaging isn't that.

## What this means in practice

- `Sync-DataverseSolutionLayout.ps1` checks for `pac` first, before validating anything else, and fails with a clear, actionable message if it's missing — never partway through, after a publisher or solution may already have been created live.
- `pac` needs its **own, separate authentication** against the target environment (`pac auth create --environment <url>`) before `pac solution clone` will work. This is genuinely independent from this plugin's own `Get-DataverseToken` auth chain used for the REST calls that create the publisher/solution — the script warns (doesn't block) if PAC CLI's active auth profile doesn't appear to match the target environment, since a mismatch there means `pac solution clone` would silently target the wrong org.
- Nothing about this changes the rest of the plugin. `design-data-model`, `deploy-dataverse-schema`, and `validate-solution-structure` still work with zero external CLI dependency beyond PowerShell itself.
