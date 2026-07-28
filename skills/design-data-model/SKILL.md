---
name: design-data-model
description: Designs a Dataverse data model collaboratively — tables, columns, global choices, relationships, alternate keys, security roles, and views — before anything is created. Discovers existing tables first and scores each proposed entity as Reuse, Extend, or Create with collision detection, produces a dependency-ordered build plan and a Mermaid ER diagram, and writes an approved spec file for the deploy-dataverse-schema skill to consume. Triggers on: "design a dataverse data model", "plan my dataverse schema", "what tables do I need", "propose a data model", "design my power apps data model", "create an ER diagram for dataverse".
user-invocable: true
model: opus
---

Read-only against Dataverse. This skill never creates, modifies, or deletes anything — it produces a written spec that a human approves and `deploy-dataverse-schema` later executes. Never skip straight to creating tables because the conversation feels far enough along; the spec file and the human's explicit approval are the only handoff to the deploy skill.

**Every single Dataverse Web API call anywhere in this workflow — the initial access check, the publisher lookup, table discovery, every later re-query — goes through `Connect-Dataverse` (once) and `Invoke-DataverseApi` in `../deploy-dataverse-schema/scripts/Dataverse.psm1`. Never hand-roll `curl` / `az account get-access-token` / `python3` (or any other ad hoc HTTP client) for any of these calls, not even a single one-off "just checking" query.** That module is the one place this project's auth-provider chain lives (PAC CLI's own cache → client secret → Azure CLI → device code, itself cached and silently refreshed across runs) and where header/error handling is already correct — bypassing it for even one query loses all of that and reintroduces exactly the kind of raw, confusing failure this project's engineering discipline exists to prevent (e.g. a stray `az` stderr line merged into a captured token variable producing an invalid Bearer header, or a `curl -o` output path not resolving the way a later read step expects it to). If a query this skill needs doesn't have a dedicated helper yet, call `Invoke-DataverseApi -Method Get -Path '<path>'` directly — it's generic enough for arbitrary reads — rather than reaching for a shell HTTP client.

## Workflow

### 1. Resolve the environment and verify access

Ask for the Dataverse environment URL if not already known. Verify read access with `Invoke-DataverseApi -Method Get -Path 'EntityDefinitions?$top=1'` after `Connect-Dataverse` (see the rule above — this applies starting here, not just for this one call).

Also resolve and record the **publisher** already in use in this environment (unique name, prefix, display name) via `Invoke-DataverseApi -Method Get -Path 'publishers?...'`. Every schema name proposed later uses this exact prefix — never invent one, and flag it clearly if more than one custom publisher exists, since that's the kind of ambiguity that caused real casing/naming mistakes in the project this plugin was generalized from (a `TT_DEV` vs `TT_Dev` mismatch cost real time to find and fix).

**If no custom publisher exists at all** (a brand-new environment), don't fail or ask the human to go create one manually first. Ask what publisher unique name, display name, and prefix they want, and write `publisherUniqueName`/`publisherFriendlyName`/`publisherPrefix` (plus `solutionFriendlyName` if the solution doesn't exist yet either) into the spec — see `../deploy-dataverse-schema/references/spec-format.md`. This lets `deploy-dataverse-schema` create both automatically rather than the deploy failing outright on the first table with "solution unique name is not valid," which is what happens if these fields are silently left out of a spec for an environment that genuinely has neither yet.

### 2. Gather requirements

Ask what the user is building and what data it needs to hold. Don't ask about implementation details (choice values, cascade behavior) yet — that comes after entities are identified.

### 3. Discover existing tables

Query `EntityDefinitions` for custom tables already in the environment (`Invoke-DataverseApi -Method Get -Path "EntityDefinitions?`$filter=IsCustomEntity eq true"`), plus check whether any of the standard tables relevant to the requirements already fit (`contact`, `account`, `systemuser`, `team`) — see `references/reuse-extend-create.md`.

### 4. Score each proposed entity: Reuse, Extend, or Create

For every entity the requirements imply, classify it:

- **Reuse** — an existing table (standard or custom) already models this concept adequately as-is
- **Extend** — an existing table models the right concept but needs additional columns
- **Create** — no existing table fits; a new one is warranted

Never silently create a table whose proposed logical name collides with something that already exists — if a collision is found, downgrade to Reuse or Extend, or propose a different name, and say so explicitly. See `references/reuse-extend-create.md` for the full decision criteria and worked examples.

### 5. Build the dependency order

Arrange every table marked Create or Extend into tiers: Tier 0 has no dependencies on other new tables, Tier 1 depends only on Tier 0, and so on. This is not optional — a lookup relationship cannot be created before both tables it connects exist, and the deploy skill executes tiers in order. Self-referential relationships (a table looking up to itself, e.g. a "superseded by" pattern) belong in the tier where the table itself lands, not a later one.

### 6. Apply the column and choice conventions

For every column proposed, see `references/choice-and-column-conventions.md` before finalizing type choices. The two rules that matter most and are easy to skip past:

- **Always propose a global choice for a Choice column, with explicit sequential option values starting from a fixed base (e.g. 100000000) — never left to the publisher's auto-derived value prefix**, which produces unpredictable numbers that differ across environments the same schema is deployed to. Only use a local picklist when the human specifically asks for one on that column; even then, keep the values explicit and sequential, and say plainly that it won't be reusable the way a global choice would be.
- **Every date that represents a calendar fact rather than a moment in time (an achievement date, an expiry date, a target date) uses Date Only / Time Zone Independent behavior.** User-local date/time behavior produces off-by-one-day errors that only surface when someone is in a different time zone — the worst kind of bug to diagnose later, because it's silent until it isn't.

### 7. Propose relationships with named cascade behavior only

For every lookup, recommend one of exactly three named behaviors — never raw cascade flags:

- **Referential** — the default. Deleting the referenced record just clears the link (RemoveLink).
- **Referential, Restrict Delete** — the referenced record can't be deleted while anything still references it. Use for reference/lookup data that other records depend on for integrity (a certification type, a role).
- **Parental** — deleting the parent cascades delete to the child. Use only for genuine part-of relationships (an intersect/child table that has no independent meaning without its parent).

Flag explicitly: **an entity can have at most one Parental-equivalent relationship as the referencing side.** This includes any lookup to `systemuser`, `team`, or another entity where Assign/Share/Unshare/Reparent are set to Cascade even if Delete isn't — Dataverse allows only one such relationship per entity regardless of which specific behaviors triggered the classification. This exact mistake — defining "Referential" with those four wrongly set to Cascade, making it near-indistinguishable from Parental — caused a real relationship-creation failure in the project this plugin generalizes from. Never propose a cascade configuration built from individual flags; only ever the three named presets above.

### 8. Sketch security roles and field-level security

Propose at least one role per user type implied by the requirements, expressed as a table: for each table, whether the role can Create/Read/Write/Delete, and at what depth (their own records only, or the whole organization). Flag any column that should be field-level secured (commonly: cost rates, salaries, anything with a legal or competitive sensitivity) — this determines whether `deploy-dataverse-schema` needs to mark that column `IsSecured` before creating any field permission on it.

### 9. Sketch views

Propose a small number of views per table that matter for daily use — not one per possible filter combination. **Before finalizing a view's name, check it against the reserved-pattern list in `references/choice-and-column-conventions.md`** ("Active {Plural}", "Inactive {Plural}", "My {Plural}") — Dataverse auto-generates views with these exact names the moment a table is created, and a same-name custom view silently never gets created if it collides. This was hit directly building the reference implementation for this plugin.

### 10. Produce the ER diagram and write the spec

Render a Mermaid ER diagram of the full proposed model (`erDiagram` syntax) so the human can review the shape before approving anything.

Write the complete design — tables, columns (with types, global choice references, required/optional), relationships (with cascade behavior), alternate keys, security role table, and views — to a spec file (default: `dataverse-schema.json` in the current working directory; ask if the user wants a different name or location). JSON, not YAML: PowerShell parses it with zero extra modules (`ConvertFrom-Json` is built in), which matters since this whole plugin avoids external dependencies deliberately. Use the structure documented in `../deploy-dataverse-schema/references/spec-format.md` exactly — the deploy skill parses this file and expects that shape.

**Optional, opt-in cross-check:** if a `solution-layout.json` file (see `../validate-solution-structure/references/solution-layout-format.md`) exists in the working directory, read it — it's a local file, no Dataverse call needed — and find the layer whose `allowedComponentTypes` includes `1` (Entity, i.e. the layer meant to own tables). If that layer's `solutionUniqueName` doesn't match the `solutionUniqueName` you're about to write into this spec, flag the mismatch and ask which one is actually intended before writing the file — don't silently pick one. If no such file exists, say nothing and proceed exactly as before; this check only ever engages for someone who has already declared a layered-solution topology, and never changes behavior otherwise. This is the only place this skill touches solution-layout awareness — the deeper structural checks (drift, cross-layer duplicates, publisher consistency) are `validate-solution-structure`'s job, not this skill's.

### 11. Get explicit approval before ending

State plainly that nothing has been created yet, that the spec file is ready for review, and that running `deploy-dataverse-schema` is the next step once the human is satisfied. Do not suggest the deploy skill runs automatically — that transition is always a separate, deliberate action.
