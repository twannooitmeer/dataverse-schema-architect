---
name: scaffold-solution-structure
description: Scaffolds a horizontal-segmentation solution topology — ensures every layer's publisher and solution exist live (creating them if this is a fresh environment), then pulls each one down as a git-trackable local folder via `pac solution clone`. Works whether the target is a brand-new empty org or an existing one that already has real components (e.g. deployed ad hoc through chat, with no local repo yet). Triggers on: "scaffold the solution structure", "set up my solution repo", "create the solution layers", "I don't have a repo for this environment yet", "clone my solutions locally", "set up segmented solutions".
user-invocable: true
model: sonnet
---

Creates real, live publishers and solutions, and writes real files to disk via `pac solution clone`. This is squarely in the "explicit permission required" category — always confirm the plan (which publisher/solutions get created, which get cloned where) before running anything, the same standard `deploy-dataverse-schema` holds itself to.

**This is the one skill in this plugin with a genuine, required PAC CLI dependency** — see `references/pac-cli-dependency.md` for why. Confirm `pac` is installed and authenticated against the target environment before going further; the script itself also checks and fails clearly if it isn't, but don't wait for that to discover it.

**Every Dataverse Web API call in this workflow goes through `Connect-Dataverse`/`Invoke-DataverseApi` in `../deploy-dataverse-schema/scripts/Dataverse.psm1`** — same rule as `design-data-model` and `validate-solution-structure`, same reasons. `pac solution clone` itself is the one exception, invoked directly as an external command — that's its whole reason for existing here.

## Workflow

### 1. Resolve the environment

Ask for the Dataverse environment URL if not already known (or let the script resolve it via PAC CLI discovery). State plainly this step creates real, live components — do this before anything else, not after a plan is already half-built.

### 2. Discover what already exists

Query existing custom solutions via `Get-DataverseCustomSolutions` in `Dataverse.psm1` — **always do this, even if the user says it's a fresh org.** An empty result confirms that; a non-empty result is exactly the situation this skill exists for (a schema built ad hoc, with real live components and no local repo yet), and skipping discovery risks creating a second, redundant solution instead of adopting the one that already has the user's actual work in it.

### 3. Get or build the topology

If a `solution-layout.json` already exists (see `../validate-solution-structure/references/solution-layout-format.md`), read it as the starting point. Otherwise, ask the user to describe their layers — don't assume any fixed number or the common Controls/Schema/Config/Logic/Flows/Apps split unless they actually want it.

**Reconcile every declared layer against what discovery found in step 2:**

- A layer whose `solutionUniqueName` matches an already-live solution — confirm with the user this is the right one, then it'll just be resolved and cloned, not created.
- A layer with no live match — will be created fresh. Needs `publisherFriendlyName`/`publisherPrefix` (once, for the shared publisher) and optionally `solutionFriendlyName` — ask if not already known.
- A live solution discovery found that the user hasn't assigned to any layer — surface it and ask whether it belongs in the topology (as a new layer, or folded into an existing one) or is genuinely unrelated. Don't silently ignore it.

Write the reconciled topology to `solution-layout.json` before running anything, so `validate-solution-structure` has something correct to check against afterward — that's the whole reason this skill was asked for.

### 4. Confirm the plan, then run it

State plainly what will happen: which publisher/solutions get created (new) vs. adopted (already live), and which layers get a local `pac solution clone` vs. are skipped because a local folder already exists there. Get explicit confirmation — this is real, live creation plus real files written to disk, not a preview.

```powershell
./scripts/Sync-DataverseSolutionLayout.ps1 -LayoutPath <path-to-solution-layout.json> -EnvironmentUrl <environment-url> -RepoRoot <path>
```

`-RepoRoot` defaults to the current directory. All layers clone into the **same** root — `pac solution clone`'s own multi-solution layout supports this natively, so don't create a separate folder per layer yourself.

### 5. Reading the output

- **`ok` / `create` for the publisher and each layer's solution** — mirrors `deploy-dataverse-schema`'s own create-if-missing reporting.
- **`clone` / `skip` for each layer's local folder** — `skip` means a folder already exists there and was deliberately **not** re-cloned, to avoid silently discarding local uncommitted edits. If the user genuinely wants a fresh clone, they need to remove or rename the existing folder themselves first — this skill won't do that for them.
- **A PAC CLI auth-profile warning** is not fatal but should be taken seriously — it means `pac solution clone` may be about to target a different environment than the one this run just created components in. Resolve it (`pac auth create --environment <url>` or `pac auth select`) before re-running if it appears.

## After a successful run

Remind the user this repo isn't source-controlled yet unless they already have git set up here — offer to help with `git init`/`.gitignore` if they want it, but don't do it unprompted; that's a separate, deliberate decision. Mention that `validate-solution-structure` can now be pointed at the same `solution-layout.json` to check for drift going forward.

## Not handled — say so rather than pretending otherwise

- **Re-syncing an already-cloned layer to pick up live drift.** This skill only clones once per layer, the first time. A later re-sync (pulling live changes into an existing local folder) is a separate, deliberate `pac solution clone`/`sync` the user runs themselves — this skill won't overwrite local folders it didn't just create.
- **Verifying `pac`'s own auth is correct beyond a best-effort check.** The auth-profile warning is exactly that — a warning, not a guarantee. `pac solution clone` failing with an auth or permission error still means the wrong thing was checked, not that this skill checked wrong.
