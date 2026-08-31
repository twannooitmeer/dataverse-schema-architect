# Dataverse Schema Architect

A Claude Code plugin that designs and deploys Dataverse tables, global choices, relationships, alternate keys, views, and security roles — with the safety defaults that a real deployment surfaced the hard way, not just documented advice.

## Why this exists

Built by generalizing a real Power Platform project's Dataverse schema work into something reusable. Along the way, several non-obvious pitfalls surfaced — a cascade-configuration near-miss that made a relationship "almost Parental" and blocked the next lookup outright, alternate keys that build asynchronously and can produce a false "not found" on a quick re-run, view names that silently collide with Dataverse's own auto-generated defaults, field permissions that fail unless the target column is explicitly marked secured first. This plugin makes those lessons the default behavior, not something the next person has to rediscover.

Checked against [microsoft/power-platform-skills](https://github.com/microsoft/power-platform-skills) — re-checked at commit `d1c1e71` (Aug 2026). Microsoft's eight plugins are each organized around an **app surface** (Power Pages, model-driven, canvas, code, mobile, MCP, Power Automate); Dataverse schema work appears only as a sub-step of building one of them. There is no standalone Dataverse plugin, which is the gap this one fills. Where the two do overlap on schema creation, Microsoft's `model-apps` builder is ahead — it already covers rollups, quick-create/quick-view forms, explicit form layout, subgrids, and role membership assignment.

What this plugin has that no skill in that repository does:

- **Column-level (field) security** — `fieldSecurityProfiles` and `secured: true` columns. Microsoft lists column-level security as an unimplemented follow-up.
- **Solution-structure governance** — `validate-solution-structure` and `scaffold-solution-structure` check and scaffold a horizontal-segmentation topology. Microsoft's solution skills are Power Pages site packaging only; nothing there validates layering, cross-layer duplicate ownership, or publisher consistency.
- **An auth chain that works unattended** — PAC CLI cache → client secret → Azure CLI → cached device code. Every Dataverse path in Microsoft's repo is `az account get-access-token` and nothing else, so it has no CI story.
- **Deployment guardrails** — an environment allowlist and `-WhatIf` preview, neither of which has an equivalent there.
- **PowerShell, no Node toolchain** — one module over the Web API, versus a vendored bundled SDK.

Two conventions this plugin holds that Microsoft's skills now share rather than contradict: mandatory solution targeting on every create call (`mobile-apps/add-dataverse` enforces the same rule via the same `MSCRM.SolutionUniqueName` header), and explicit sequential option values on global choices. This plugin still defaults *every* Choice column to a global choice, where Microsoft's is per-column opt-in — a preference difference, not a capability gap.

Full comparison, with citations: [`docs/microsoft-power-platform-skills-overlap.md`](docs/microsoft-power-platform-skills-overlap.md).

## Installation

```
/plugin marketplace add twannooitmeer/dataverse-schema-architect
/plugin install dataverse-schema-architect@dataverse-schema-architect
```

Restart Claude Code (or reload plugins) afterward. This installs the five skills below (`design-data-model`, `deploy-dataverse-schema`, `validate-solution-structure`, `scaffold-solution-structure`, `report-issue`) and the two enforcement hooks.

## What's included

| Component | Purpose |
|---|---|
| `skills/design-data-model` | Conversational, read-only design: discovers existing tables, scores each proposed entity Reuse/Extend/Create with collision detection, orders tables by dependency, produces a Mermaid ER diagram, writes an approved spec file. Never creates anything. |
| `skills/deploy-dataverse-schema` | Idempotently creates everything in the approved spec, via a PowerShell module hitting the Dataverse Web API directly. Safe to re-run — every step is create-if-missing. |
| `skills/validate-solution-structure` | Read-only check of a declared horizontal-segmentation topology against live `solutioncomponent` placement — component-type drift, cross-layer duplicate ownership, publisher consistency. Borrows its core check from Microsoft's own FastTrack Solution Component Validation Tool; reports drift, never moves or reassigns anything. |
| `skills/scaffold-solution-structure` | Ensures a topology's publisher/solutions exist live (creating them if missing) and pulls each one down locally via `pac solution clone` — for a brand-new environment, or retroactively for one that already has real components but no local repo yet. The only skill in this plugin with a hard PAC CLI dependency. |
| `skills/report-issue` | Files a bug report against this repo's own GitHub issues. |
| `hooks/` | Two `PostToolUse` guardrails that scan newly-written PowerShell for the two costliest mistakes this plugin exists to prevent: missing solution targeting, and hand-built cascade configuration objects. |

## How it works

No .NET SDK, no NuGet restore. Every Dataverse call is `Invoke-RestMethod` against the Web API. Authentication tries, in order: PAC CLI's own token cache (best-effort, unsupported — reads its local MSAL cache directly since `pac` has no command to export a token, DPAPI-decrypted the same way `pac` itself would read it), a client secret (for unattended/CI use), `az account get-access-token` (reuses an existing Azure CLI login), then device code as the last resort — and device-code sign-in is itself cached and silently refreshed on later runs, so it only prompts for a fresh interactive sign-in once.

```
design-data-model  →  writes dataverse-schema.json  →  human reviews & approves
                                                              ↓
                                            deploy-dataverse-schema  →  live Dataverse environment
```

See [`skills/deploy-dataverse-schema/references/spec-format.md`](skills/deploy-dataverse-schema/references/spec-format.md) for the exact spec file shape, and [`skills/deploy-dataverse-schema/references/safety-rules.md`](skills/deploy-dataverse-schema/references/safety-rules.md) for why each safety rule exists — every one traces back to something that actually broke, not a hypothetical.

`validate-solution-structure` runs independently of this pipeline — an on-demand health check against a declared solution-layout file (see [`skills/validate-solution-structure/references/solution-layout-format.md`](skills/validate-solution-structure/references/solution-layout-format.md)), not a required step before or after a deploy.

## Prerequisites

- PowerShell 7+ (`pwsh`)
- One of: an existing PAC CLI sign-in (best-effort, unsupported — see below); Azure CLI (`az`) logged in via `az login`; a client secret for unattended/CI use (`DATAVERSE_TENANT_ID`/`DATAVERSE_CLIENT_ID`/`DATAVERSE_CLIENT_SECRET`); or accept the interactive device-code fallback prompt (cached and silently refreshed after the first sign-in). See `Get-DataverseToken` in [`Dataverse.psm1`](skills/deploy-dataverse-schema/scripts/Dataverse.psm1) for the exact priority order.
- A Dataverse environment where you hold System Administrator or System Customizer
- Optional: PAC CLI (`pac`) logged in via `pac auth create --url <environment-url>` — lets you skip passing `-EnvironmentUrl` explicitly at deploy time, and (best-effort, unsupported) may also let this module reuse its cached sign-in directly, skipping Azure CLI/device-code entirely.

## Getting started

```
"Design a data model for <describe what you're building>"
```

Review the proposed model and the generated spec file, then:

```
"Deploy the schema from dataverse-schema.json to <your environment URL>"
```

`-EnvironmentUrl` can be omitted if PAC CLI already knows the target environment. If you've configured an environment allowlist (`-AllowedEnvironmentUrls` or `DATAVERSE_ALLOWED_ENVIRONMENTS`), a target outside it is refused unless you pass `-Force` — see [`safety-rules.md`](skills/deploy-dataverse-schema/references/safety-rules.md). Add `-WhatIf` to preview what would be created or skipped against the live environment, without creating, updating, or deleting anything.

## Not yet supported

- Rollup columns (need a FetchXML aggregate definition — different mechanism than the rest of column creation)
- Quick Create, Quick View, and Card forms, and custom tab/section layout on the Main form (a table's `mainForm.fields` adds columns/lookups to its existing auto-generated Main form only — see [`form-support.md`](skills/deploy-dataverse-schema/references/form-support.md))
- Subgrid form controls (a child collection shown on its parent's form) — needs relationship/view resolution the current scalar-field-only form support doesn't do; see `form-support.md`
- Security role / field security profile membership (creating the role or profile is supported; assigning users or teams to it is a separate, deliberate step)

## License

MIT — see [LICENSE](LICENSE).
