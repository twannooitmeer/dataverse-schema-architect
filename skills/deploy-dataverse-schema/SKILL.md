---
name: deploy-dataverse-schema
description: Idempotently creates Dataverse tables, columns, global choices, relationships, alternate keys, views, and security roles from an approved spec file produced by design-data-model. Use when deploying, creating, or building Dataverse schema, tables, or a data model that has already been designed and approved. Never invoked to design a model from scratch — that's design-data-model's job.
user-invocable: true
model: sonnet
---

This skill executes an **already-approved** spec file. It never designs anything itself — if there's no spec file yet, or the user is still describing what they want rather than pointing at a reviewed spec, redirect to `design-data-model` first.

## Before running anything

1. Confirm the spec file exists and the user has actually reviewed it — don't assume a spec file found in the working directory was necessarily approved for *this* environment. Ask which environment to deploy to if it isn't obvious from context. `-EnvironmentUrl` is optional — if omitted, the script resolves it internally from PAC CLI's own auth cache; only fills in what the user didn't say. State which URL will actually be used either way, once the script has told you (see the next point) — don't try to determine it yourself in advance.
2. State plainly which environment this will create real, live components in, and that solution imports/schema changes are visible to everyone else using that environment. This is squarely in the "explicit permission required" category of actions — always confirm before running, even if the spec itself was already approved. Approving a design is not the same as approving *when* and *where* to deploy it.
3. **Don't independently probe for `pac`, `az`, or any auth provider yourself before running the script** — no `pac auth list`, no `az account show`, no "checking what's available" as a separate step. `Get-DataverseToken` already tries every provider in order (PAC CLI's cache, client secret, Azure CLI, device code) and fails through silently when one isn't installed or isn't logged in — that silence is deliberate, not a gap for you to fill by shelling out and re-checking the same things yourself. A tool genuinely missing from `PATH` produces a raw "term not recognized" error if *you* invoke it directly, which is exactly the confusing failure the module's own `Get-Command ... -ErrorAction SilentlyContinue` guards were written to avoid — don't reintroduce it. Just run the script (below); if it needs a device-code sign-in, it prints the URL and code itself, and that's the point where you tell the user to complete it.
4. If an environment allowlist is configured (`-AllowedEnvironmentUrls` or `DATAVERSE_ALLOWED_ENVIRONMENTS`) and the target isn't on it, the script refuses to run rather than asking here — that's deliberate, since it exists precisely to catch a wrong URL before this step's confirmation even happens. `-Force` bypasses it when the user genuinely intends to deploy outside the allowlist.

## Running the deploy

```powershell
./scripts/Deploy-DataverseSchema.ps1 -SpecPath <path-to-spec.json> -EnvironmentUrl <environment-url>
```

`-EnvironmentUrl` can be omitted to use PAC CLI-based discovery instead. `-AllowedEnvironmentUrls <url[], url[]>` and `-Force` control the environment allowlist guard — see `references/safety-rules.md`. Add `-WhatIf` to preview create/skip decisions against the live environment without creating, updating, or deleting anything — security roles and field security profiles are previewed by existence only, not privilege/permission-level diffing (see `references/safety-rules.md` for why).

The script validates the spec's shape before making any API call (required fields, valid enum values for ownership/column types/cascade names) and fails fast with a specific message rather than partway through a partially-applied deploy.

Processing order is fixed regardless of the spec file's own array ordering — see `references/spec-format.md` for exactly why: global choices → tables → columns → relationships → alternate keys → views → security roles → field security. Every step is create-if-missing, so re-running the same spec after fixing one failure is always safe — nothing gets recreated, and the run picks up wherever it left off.

## Reading the output

Every line is either `create` (something new was made) or `skip` (it already existed — expected and fine on a second run). Read `references/safety-rules.md` before troubleshooting anything that doesn't fit that pattern; most failures map directly onto one of the documented lessons rather than being novel.

**A `Rename this view` warning is not an error** — it means a proposed view name collides with one of Dataverse's own auto-generated defaults for that table, and creating it would silently do nothing. Go back to `design-data-model` (or the spec file directly) and pick a name that describes the actual filter rather than "Active"/"Inactive"/"My".

**A `drift` warning on a skipped column is worth surfacing to the user, not quietly passing over** — it means the live column's type doesn't match what the spec asks for. This module never changes an existing column's type on its own; flag it and let the human decide whether the spec or the live environment is the one that's wrong.

**Alternate keys may log `active`, or a "still building" warning** — the latter means the index is still building in the background (expected for a table with a lot of existing data) and is not a deploy failure; re-running later will confirm it reached `Active`.

**A `publish` line only appears when a field-level security change happened.** Every create call in this module is auto-published by Dataverse itself (confirmed against Microsoft's own docs); the one exception is marking a column `IsSecured`, an update to something that already existed, which this module explicitly publishes right after making it. No other step needs this, and none of them call it.

## After a successful run

Report what was actually created vs. skipped — don't just say "done." If security roles were created, remind the user that role membership (which users/teams hold each role) still needs to be assigned separately; this skill creates the roles and their privileges, not user assignments. If any field security profile was created, remind them the same applies to profile membership.

## Not handled yet — say so rather than pretending otherwise

- **Rollup columns.** These need a FetchXML aggregate definition, a different mechanism than the rest of column creation, and aren't in `Dataverse.psm1` yet. If the spec calls for one, flag it explicitly as unsupported rather than silently skipping it.
- **Custom forms.** Only Dataverse's auto-generated main form exists after this runs. Form layout is a separate, presentation-focused pass.
- **Security role / field security profile membership** (which users or teams hold a role or profile) — creating the container is this skill's job; populating its membership is a deliberate follow-up step, usually because the relevant teams don't exist as real records yet at design time.
