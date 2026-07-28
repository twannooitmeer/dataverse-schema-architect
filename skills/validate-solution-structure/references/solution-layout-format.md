# Solution layout format

The JSON file this skill reads (default: `solution-layout.json` in the current working directory) describes a **horizontal-segmentation topology** — one entry per layer solution, each declaring which `solutioncomponent` types it's allowed to own. This mirrors the configuration shape Microsoft's own FastTrack Solution Component Validation Tool uses (a per-solution allowlist of component object type codes), adapted to a file a human writes once instead of Dataverse records created through a model-driven app.

```json
{
  "publisherUniqueName": "ttdev",
  "layers": [
    {
      "name": "Controls",
      "solutionUniqueName": "TTControls",
      "allowedComponentTypes": [66, 90, 91, 92, 93],
      "dependsOn": []
    },
    {
      "name": "Schema",
      "solutionUniqueName": "TTSchema",
      "allowedComponentTypes": [1, 2, 3, 9, 14, 18, 20, 21, 24, 26, 59, 60, 70, 71],
      "dependsOn": ["Controls"]
    },
    {
      "name": "Config",
      "solutionUniqueName": "TTConfig",
      "allowedComponentTypes": [],
      "dependsOn": []
    },
    {
      "name": "Logic",
      "solutionUniqueName": "TTLogic",
      "allowedComponentTypes": [90, 91, 92, 93, 95],
      "dependsOn": ["Schema"]
    },
    {
      "name": "Flows",
      "solutionUniqueName": "TTFlows",
      "allowedComponentTypes": [29],
      "dependsOn": ["Schema", "Config", "Logic"]
    },
    {
      "name": "Apps",
      "solutionUniqueName": "TTApps",
      "allowedComponentTypes": [62],
      "dependsOn": ["Schema", "Logic", "Flows"]
    }
  ]
}
```

The example above is illustrative (six layers, matching the common Controls → Schema → Config → Logic → Flows → Apps split some medium-to-large engagements use) — **this skill doesn't assume any fixed number of layers or names.** A two-layer split (`Core` + `Feature`) or a single monitored solution is exactly as valid a topology file.

## Field notes

- **`publisherUniqueName`** — required at the top level. Every layer's solution is expected to share this one publisher; a layer resolving to a different publisher is flagged (see `checks.md` for why this is checked ahead of component-type drift, not alongside it).
- **`layers[].name`** — a friendly label used only in this skill's own report; never sent to Dataverse. Referenced by other layers' `dependsOn`.
- **`layers[].solutionUniqueName`** — the actual Dataverse solution unique name, resolved via `Get-DataverseSolutionByUniqueName` in `Dataverse.psm1`. A layer whose solution doesn't exist yet in the target environment is reported, not treated as an error that stops the whole run — a topology can legitimately describe a solution that hasn't been created yet.
- **`layers[].allowedComponentTypes`** — array of raw `solutioncomponent.componenttype` integers (Dataverse's own `Object Type Code` values — see [Microsoft's `solutioncomponent` reference](https://learn.microsoft.com/power-apps/developer/data-platform/reference/entities/solutioncomponent) for the full list this project's own `Get-DataverseSolutionComponentTypeName` table was built from). Raw integers, not names, deliberately — this is what Microsoft's own tool's "Allowlist Component Object Code" field takes too, and it sidesteps ever needing to keep a name-to-code mapping perfectly in sync with a global choice Microsoft itself keeps extending. An empty array means "this solution shouldn't own any components directly" — legitimate for something like a pure configuration container.
- **`layers[].dependsOn`** — array of other layers' `name` values this layer is declared to depend on. Checked for internal consistency only (every name resolves to a real layer in this file, and the graph has no cycle) — this skill does **not** verify against Dataverse's own actual import-dependency records, which only exist once a real cross-layer reference is created (a form referencing a PCF control, a flow calling a Custom API). Confirming *that* requires a real solution export/import, out of scope for a read-only Web API check — see `checks.md`.

## What the skill does with this file

1. Validates the file's shape before making any API call (same "fail fast on a malformed input" discipline as `deploy-dataverse-schema`'s spec validation) — required fields present, `dependsOn` names all resolve, no dependency cycle.
2. Connects once (`Connect-Dataverse`), reusing the token for the whole run.
3. For each layer: resolves the solution (skipping with a clear note if it doesn't exist yet), fetches every `solutioncomponent` via `Get-DataverseSolutionComponents`, and diffs the actual component-type set against `allowedComponentTypes`.
4. After all layers are checked: cross-references every component's `objectid` across *all* layers to flag any component owned by more than one solution, and confirms every resolved layer's publisher matches `publisherUniqueName`.
5. Prints a structured report — nothing in this skill ever creates, updates, or reassigns a component.
