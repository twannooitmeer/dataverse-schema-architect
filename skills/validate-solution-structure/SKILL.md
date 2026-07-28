---
name: validate-solution-structure
description: Checks whether Dataverse solution components actually match a declared horizontal-segmentation topology — every component in the layer that's supposed to own its type, no component owned by more than one solution, every layer's publisher consistent. Read-only; reports drift, never moves or reassigns a component. Borrows its core check from Microsoft's own FastTrack Solution Component Validation Tool. Triggers on: "check solution structure", "validate solution layering", "is my solution segmented correctly", "check for solution component drift", "audit solution layers", "check horizontal segmentation", "did anything land in the wrong solution".
user-invocable: true
model: sonnet
---

Read-only against Dataverse. This skill never creates, moves, reassigns, or deletes a solution component — it reports where the live environment's actual `solutioncomponent` placement disagrees with a declared topology, and leaves the fix to a human. Reassigning a component's owning solution isn't always even possible without recreating it (a component under one publisher can't be shared with a solution under a different publisher), so there's no safe "just fix it" mode this skill could offer even if it wanted to.

**Every Dataverse Web API call in this workflow goes through `Connect-Dataverse`/`Invoke-DataverseApi` in `../deploy-dataverse-schema/scripts/Dataverse.psm1` — never hand-roll `curl`/`az`/`python3` for any of it.** Same rule as `design-data-model`, same reasons.

## What this borrows from Microsoft, and what it adds

The core check — an allowlist of `solutioncomponent` type codes per monitored solution, checked against live components — is the same mechanism Microsoft's own [Solution Component Validation Tool](https://learn.microsoft.com/dynamics365/guidance/resources/solution-component-validator) uses (a FastTrack-published managed solution: an entity, a security role, and a Power Automate flow that emails a report). This skill reproduces that check on demand through this plugin's own PowerShell module instead of requiring a second managed solution installed into the environment — see `references/checks.md` for the exact reasoning, cited.

Two checks beyond what Microsoft's own tool does: **cross-layer duplicate ownership** (a component owned by more than one monitored solution — worse than type drift, and not something a per-solution allowlist check can ever notice on its own) and **publisher consistency across layers** (a mismatch here invalidates the whole topology, not just one layer's compliance with it). Both are cheap, and both trace to real, named failure modes — see `references/checks.md`.

## Workflow

### 1. Get or write the topology file

Ask for the path to a solution-layout JSON file if one isn't already known (default: `solution-layout.json` in the working directory) — see `references/solution-layout-format.md` for the exact shape. If the user doesn't have one yet, help them write it: ask what solutions exist (or should exist) and which component types each is meant to own. Don't invent a topology from nothing — a horizontal-segmentation plan is the user's own architectural decision, not something to assume on their behalf. A common six-layer shape (components split by type: code components, schema, configuration, business logic, flows, apps) is one well-known pattern worth mentioning if they're starting from scratch, but never assume it's the right one for their case.

### 2. Resolve the environment

Ask for the Dataverse environment URL if not already known (or let `Test-SolutionStructure.ps1` resolve it via PAC CLI discovery — see `deploy-dataverse-schema/references/safety-rules.md` for how that works). This is a read-only check, not a deploy — it doesn't carry the same "explicit permission required" weight `deploy-dataverse-schema` does, but still state plainly which environment is being checked before running, since the result is only meaningful for that one environment.

### 3. Run the check

```powershell
./scripts/Test-SolutionStructure.ps1 -LayoutPath <path-to-solution-layout.json> -EnvironmentUrl <environment-url>
```

The script validates the layout file's own shape first (required fields, `dependsOn` names all resolve, no dependency cycle) and fails fast with a specific message before making any API call — same discipline as `deploy-dataverse-schema`'s spec validation.

### 4. Reading the output

Four sections, in this order:

- **Resolving layers** — a layer whose solution doesn't exist yet in the target environment is reported as `missing`, not treated as a fatal error; a topology can legitimately describe a solution that hasn't been created.
- **Component-type drift** — grouped by component type, per layer. A component type this module doesn't have a human-readable name for prints as `Component Type <n> (unmapped — see Microsoft's solutioncomponent reference)` rather than a guessed name; look it up before dismissing it as noise.
- **Cross-layer duplicate ownership** — treat any finding here as more urgent than a same-section type-drift finding: it means the *last managed import wins* silently for that component, which is exactly the failure horizontal segmentation exists to prevent.
- **Publisher consistency** — a mismatch here means the affected layer's components genuinely can't be reconciled with the rest of the topology without deletion and recreation. Surface this first if it appears alongside other findings; it's the reason a lower-priority finding might not even be trustworthy yet.

Report what was actually found, grouped the way the script already grouped it — don't flatten "3 drift findings, 1 duplicate, 1 publisher mismatch" into a single "some issues found" sentence. Each finding implies a different next step (rename an allowlist entry vs. plan a recreation), and collapsing them loses that.

### 5. After reporting

Don't propose fixes as if they're always safe. A component-type drift finding might mean the topology's allowlist is wrong (add the type) or the component is genuinely misplaced (needs to move — which may mean recreating it under the right solution/publisher, a real, disruptive action, not a quick edit). Ask which one applies before suggesting next steps; don't assume the live environment is wrong just because it disagrees with the file.

## Not handled — say so rather than pretending otherwise

- **Actual Dataverse-enforced import order.** `dependsOn` is checked only for internal consistency in the topology file (no cycle, all names resolve) — verifying the real, enforced dependency graph needs a solution export/unpack to inspect `Solution.xml`, out of scope for a read-only Web API check. See `references/checks.md`.
- **Fixing drift.** This skill never moves, reassigns, or deletes a component. It reports; a human decides and acts.
