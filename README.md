# Dataverse Schema Architect

A Claude Code plugin that designs and deploys Dataverse tables, global choices, relationships, alternate keys, views, and security roles — with the safety defaults that a real deployment surfaced the hard way, not just documented advice.

## Why this exists

Built by generalizing a real Power Platform project's Dataverse schema work into something reusable. Along the way, several non-obvious pitfalls surfaced — a cascade-configuration near-miss that made a relationship "almost Parental" and blocked the next lookup outright, alternate keys that build asynchronously and can produce a false "not found" on a quick re-run, view names that silently collide with Dataverse's own auto-generated defaults, field permissions that fail unless the target column is explicitly marked secured first. This plugin makes those lessons the default behavior, not something the next person has to rediscover.

Checked against [microsoft/power-platform-skills](https://github.com/microsoft/power-platform-skills) for structure and quality bar before building. Two gaps found in their own reference along the way, which this plugin fixes rather than imitates:

- Their table-management reference documents **local picklists only** — this plugin never creates one; every Choice column is a global choice with explicit, sequential option values.
- Their reference **doesn't explicitly address solution targeting** — this plugin requires it as a mandatory parameter on every single create call, so a component can never silently land in whatever solution happens to be the environment's default.

## What's included

| Component | Purpose |
|---|---|
| `skills/design-data-model` | Conversational, read-only design: discovers existing tables, scores each proposed entity Reuse/Extend/Create with collision detection, orders tables by dependency, produces a Mermaid ER diagram, writes an approved spec file. Never creates anything. |
| `skills/deploy-dataverse-schema` | Idempotently creates everything in the approved spec, via a PowerShell module hitting the Dataverse Web API directly. Safe to re-run — every step is create-if-missing. |
| `skills/report-issue` | Files a bug report against this repo's own GitHub issues. |
| `hooks/` | Two `PostToolUse` guardrails that scan newly-written PowerShell for the two costliest mistakes this plugin exists to prevent: missing solution targeting, and hand-built cascade configuration objects. |

## How it works

No .NET SDK, no NuGet restore. Every Dataverse call is `Invoke-RestMethod` against the Web API, authenticated via `az account get-access-token` — this reuses an existing Azure CLI login with no extra sign-in step. A device-code fallback covers the case where Azure CLI isn't installed or logged in.

```
design-data-model  →  writes dataverse-schema.json  →  human reviews & approves
                                                              ↓
                                            deploy-dataverse-schema  →  live Dataverse environment
```

See [`skills/deploy-dataverse-schema/references/spec-format.md`](skills/deploy-dataverse-schema/references/spec-format.md) for the exact spec file shape, and [`skills/deploy-dataverse-schema/references/safety-rules.md`](skills/deploy-dataverse-schema/references/safety-rules.md) for why each safety rule exists — every one traces back to something that actually broke, not a hypothetical.

## Prerequisites

- PowerShell 7+ (`pwsh`)
- Azure CLI (`az`), logged in via `az login` — or accept the device-code fallback prompt
- A Dataverse environment where you hold System Administrator or System Customizer

## Getting started

```
"Design a data model for <describe what you're building>"
```

Review the proposed model and the generated spec file, then:

```
"Deploy the schema from dataverse-schema.json to <your environment URL>"
```

## Not yet supported

- Rollup columns (need a FetchXML aggregate definition — different mechanism than the rest of column creation)
- Custom forms (Dataverse's auto-generated main form is left as-is)
- Security role / field security profile membership (creating the role or profile is supported; assigning users or teams to it is a separate, deliberate step)

## License

MIT — see [LICENSE](LICENSE).
