# Overlap analysis: dataverse-schema-architect vs. microsoft/power-platform-skills

**Assessed:** 31 August 2026
**Upstream reviewed:** [`microsoft/power-platform-skills`](https://github.com/microsoft/power-platform-skills) at commit `d1c1e71` — 8 plugins, ~90 skills, 1,210 files
**Question asked:** where do the two libraries overlap, and could part of this plugin live as a fork of Microsoft's repository?
**Verdict:** do not fork. Keep the standalone repository, narrow the positioning to three defensible areas, and stop pursuing schema-creation parity.

---

## 1. What the Microsoft library actually is

Eight plugins, each organized around an **app surface** rather than around Dataverse:

`power-pages` · `model-apps` · `canvas-apps` · `code-apps` · `mobile-apps` · `mcp-apps` · `power-automate` · `power-apps-mobile-extension`

There is **no standalone Dataverse or schema plugin**. Schema work is always a sub-step on the way to building something — a site, a model-driven app, a mobile app. That is the structural gap `dataverse-schema-architect` occupies, and it is a real one.

## 2. Overlap map

| This plugin | Closest Microsoft equivalent | Overlap |
|---|---|---|
| `design-data-model` | `mobile-apps/setup-datamodel`, `power-pages/setup-datamodel`, `code-apps/add-dataverse` (step 1) | **High.** Same shape: discover → propose → ER diagram → approve → write spec → hand to an executor. |
| `deploy-dataverse-schema` | `model-apps/app-builder` + the vendored `cds-maker-sdk` (`entity-provision.js`, `sdk-build.js`) | **Very high — and Microsoft is ahead.** |
| `validate-solution-structure` | *nothing* | **None.** |
| `scaffold-solution-structure` | `power-pages/setup-solution`, `power-pages/plan-alm` | **Partial.** Theirs is Power Pages-scoped and site-component-specific. |
| `report-issue` | `report-issue` in five Microsoft plugins | **Total.** It is their boilerplate. |

### The App Spec is structurally near-identical to our schema spec

Microsoft's `model-apps` App Spec (`references/app-spec-schema.md`) top-level shape is `solution` (with `publisherPrefix`) · `entities` · `relationships` · `globalChoices` · `views` · `forms` · `personas` — the same decomposition as `dataverse-schema.json`, with an added `app` / `appShell` layer. Their builder can run schema-only via `--stage data`, so the app layer is not a hard requirement.

## 3. Two positioning claims that no longer held

The README previously claimed two deliberate differences from Microsoft. Both have since been overtaken upstream and have now been corrected in the README.

**Solution targeting.** `plugins/mobile-apps/skills/add-dataverse/SKILL.md:687` reads: *"Solution targeting (HARD): every Step 5 / 5b POST MUST pass `--solution <uniquename>` … Without this flag, multi-project environments end up with cross-solution leakage and the foreign-collision class of bug returns."* Same rule, same rationale, same `MSCRM.SolutionUniqueName` header. `model-apps` scopes all artifacts to a dedicated solution as well.

**Global choices with explicit sequential values.** `plugins/model-apps/scripts/lib/entity-provision.js:391` creates option sets with `value: 100000000 + i`, and `createGlobalOptionSet` is idempotent (probe-then-reuse). Our stance is still stronger — we default *every* Choice column to a global choice, where Microsoft's is per-column opt-in via `globalChoice` — but that is a preference difference, not a capability gap.

### Every item on our "Not yet supported" list is supported upstream

| Our documented gap | Microsoft's `model-apps` coverage |
|---|---|
| Rollup columns | `source: "Rollup"` + `formula` on a column |
| Quick Create / Quick View / Card forms | `forms[].formType`, plus `forms[].quickViews[]` placement |
| Custom tab/section layout on the Main form | explicit `tabs` layout (`app-spec.project-tracker.json`) |
| Subgrid form controls | `forms[].subgrids[]`, 1:N and N:N auto-resolved |
| Security role membership assignment | `personas[].assignTo.{teams,users}` (grant-only) |

Their `personas[]` model — jobs-to-be-done → declared privileges → unioned into one role per persona with replace semantics — is also more sophisticated than our `securityRoles[].grants[]`.

## 4. What this plugin has that Microsoft's does not

1. **Column-level (field) security.** Explicitly out of scope upstream, stated twice: `model-apps/references/app-spec-schema.md:835` and `model-apps/skills/app-builder/SKILL.md:546` both list *"column-level (field) security"* as a tracked follow-up. Our `fieldSecurityProfiles` and `secured: true` are unmatched anywhere in the repository.
2. **Solution-structure governance.** Nothing in 1,210 files performs horizontal-segmentation checking, cross-layer duplicate ownership detection, or publisher-consistency validation. Microsoft's solution work is entirely Power Pages site packaging (`AddSolutionComponent`, `.solution-manifest.json`, pipelines).
3. **An auth chain that works unattended.** Every Microsoft Dataverse path is `az account get-access-token` and nothing else (`model-apps/scripts/lib/dataverse-auth.js:4`, `power-pages/scripts/dataverse-request.js`). No client-secret path, therefore no CI or unattended story. Ours is PAC CLI cache → client secret → Azure CLI → cached device code.
4. **Deployment guardrails.** An environment allowlist (`-AllowedEnvironmentUrls` / `DATAVERSE_ALLOWED_ENVIRONMENTS`) and `-WhatIf` preview. No equivalent guard exists upstream.
5. **PowerShell, no Node toolchain.** One module over the Web API, versus a vendored bundled SDK and a Node dependency.
6. **Schema as the product**, rather than as a step toward an app module and sitemap.

## 5. The fork question

**Legally permitted, practically inadvisable.**

- The upstream `LICENSE` is MIT, so a fork is allowed with attribution.
- `CONTRIBUTING.md` is a single sentence: *"This project is not currently accepting contributions."* A fork would therefore be a **permanent hard fork with no merge-back path**.
- A fork inherits 1,210 files and eight unrelated plugins we do not maintain, against a repository that moves quickly.
- Their `marketplace.json` lists all eight plugins; there is no supported way to publish a slice of it.

### Recommended course instead

- **Keep the standalone repository and marketplace.** It is the right container for a Dataverse-first plugin, which is precisely the shape Microsoft does not ship.
- **Narrow the positioning to the defensible three:** field security, solution-structure governance, and CI-capable authentication.
- **Stop growing `deploy-dataverse-schema` toward parity.** Subgrids, quick-create forms, and rollups would mean reimplementing `cds-maker-sdk` in PowerShell against a faster-moving team. Either have `design-data-model` emit an App Spec and delegate, or explicitly own the "schema without an app" niche and leave app surfaces alone.
- **Borrow freely (MIT, with attribution).** Worth adopting from upstream: the `check-version.js` plugin-version gate, the `report-issue` pattern, the `spec-lint` → `preview` → plan-mode approval → `--apply --verify` pipeline, teardown that is dry-run by default, and the CI skill-linting workflows. Their engineering scaffolding is stronger than ours; their Dataverse governance is weaker.

## 6. Open items

- Decide between the two roads in §5: delegate schema creation to Microsoft's engine, or formally own the "schema without an app" niche. This is the one decision the rest of the roadmap depends on.
- Re-run this comparison when Microsoft ships column-level security — it is their stated follow-up and would remove differentiator #1.
- Evaluate adopting `check-version.js` and a CI skill lint, which are cheap and independent of that decision.
