# Overlap analysis: dataverse-schema-architect vs. microsoft/power-platform-skills

**Assessed:** 31 August 2026, re-checked 17 September 2026
**Upstream reviewed:** [`microsoft/power-platform-skills`](https://github.com/microsoft/power-platform-skills) at commit `b869e5f` (16 September 2026): 8 plugins, 113 skills, 1,315 files. Originally reviewed at `d1c1e71` (31 August 2026): 8 plugins, ~90 skills, 1,210 files.
**Question asked:** where do the two libraries overlap, and could part of this plugin live as a fork of Microsoft's repository?
**Verdict:** unchanged. Do not fork. Keep the standalone repository, narrow the positioning to three defensible areas, and stop pursuing schema-creation parity.

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

## 4a. Re-check at `b869e5f` (17 September 2026)

25 commits landed upstream between `d1c1e71` and `b869e5f`, touching 358 files (+55,926/-7,253 lines). None of it changes the verdict above.

**No plugin added or removed.** Still the same eight: `power-pages`, `model-apps`, `canvas-apps`, `code-apps`, `mobile-apps`, `mcp-apps`, `power-automate`, `power-apps-mobile-extension`.

**Three new skills:**

- `mcp-apps/generate-codeful-mcp-tool`: codeful (JS) MCP tool generation, alongside the existing `generate-mcp-app-ui`.
- `mobile-apps/setup-app-insights`: wires Application Insights telemetry into a mobile app.
- `power-pages/migrate-webapi-selectall`: migrates a site off unbounded Web API `$select`-all calls to an explicit column allowlist.

**Everything else is depth, not breadth**, concentrated in two plugins:

- `mobile-apps` (≈20 `SKILL.md` files touched, plus `hooks/hooks.json`, `hooks/run-telemetry.js`, `hooks/validate-navigation-idempotency.js`, `hooks/validate-protected-paths.js`, three new `agents/*.md` revisions, and a new `scripts/lib/telemetry/` region-resolution subsystem): mostly telemetry, offline-profile, and native-capability hardening.
- `model-apps` (`app-builder/SKILL.md`, `genpage/SKILL.md`, `telemetry/SKILL.md`, `report-issue/SKILL.md`, six `genpage-*` agents, a new `lint-app-spec.js`, and ~25 new test files under `scripts/tests/`): mostly App Spec linting and genpage agent refinement.
- `power-pages` (`add-ai-webapi`, `audit-permissions`, `integrate-webapi`, `test-site` `SKILL.md` files, plus the new `migrate-webapi-selectall` skill and a new `references/webapi-field-allowlist.md`).
- `canvas-apps/canvas-app` and `mcp-apps/generate-mcp-app-ui` each had their `SKILL.md` touched once.

**The claims this doc already made were re-verified line-for-line, not just assumed to still hold:**

- Solution targeting: `plugins/mobile-apps/skills/add-dataverse/SKILL.md` still carries the same `SolutionUniqueName`/`MSCRM.SolutionUniqueName` HARD rule (the file changed, 65 insertions and 27 deletions, but this rule did not).
- Global choices: `plugins/model-apps/scripts/lib/entity-provision.js` still assigns `value: 100000000 + i`, unchanged.
- Auth: still `az account get-access-token` only, no client-secret path anywhere upstream. Differentiator #3 stands.

**Trip-wire checked directly, not inferred: column-level field security has *not* shipped.** All three places that said "tracked follow-up" at `d1c1e71` still say it verbatim at `b869e5f`:

- `plugins/model-apps/references/app-spec-schema.md:1202`: *"Not yet supported (tracked follow-up): column-level (field) security and access teams / hierarchy [security]."*
- `plugins/model-apps/references/app-spec-schema-advanced.md:359`: same sentence.
- `plugins/model-apps/skills/app-builder/SKILL.md:611`: same sentence, referenced as **"column-level (field) security"** and **"access teams / hierarchy security"**.
- `plugins/model-apps/references/authoring-flow.md:669` also newly (re-)states: *"Column-level security and access teams are not yet supported."*

Differentiator #1 (§4) stands unchanged. No follow-up action triggered.

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

> [!decision] Resolved 2026-09-02
> Locked in the niche road: this plugin stops pursuing schema-creation parity with `model-apps`. Reasoning given at decision time — Microsoft moves faster on app-surface schema creation than this repo can keep pace with, so the durable value is the narrower, defensible ground (§4), not a race to match a faster-moving team on their own turf. `deploy-dataverse-schema` will not grow rollups, quick-create/quick-view/card forms, custom tab/section layout, subgrids, or role/profile membership assignment — see README's "Out of scope by design" section, which replaces the old "Not yet supported" framing now that these are a deliberate boundary, not a backlog.

- Re-run this comparison when Microsoft ships column-level security — it is their stated follow-up and would remove differentiator #1. **No automated trigger for this** (deliberately, per Twan 2026-09-02) — checked manually, on no fixed schedule.
- **Re-checked 2026-09-17 against `b869e5f`** (see §4a): trip-wire not tripped, column-level field security still explicitly "not yet supported" upstream. All other claims re-verified. Next re-check remains unscheduled, on no fixed cadence, checked manually whenever Twan next looks.

> [!decision] Resolved 2026-09-02
> `check-version.js` adopted, CI skill lint evaluated and deferred:
> - **Plugin-version drift check** ported as a `SessionStart` hook (`hooks/check-plugin-version.js`) rather than a per-SKILL.md instruction line — this repo's own stated principle is enforcement belongs in hooks, not in something the model has to remember to run. Fires once per session, silent on any error, never blocks.
> - **CI added**: a `version-bump` check (`.github/workflows/ci.yml`) fails a PR that touches `skills/`, `hooks/`, or a `.psm1`/`.ps1` without bumping `.claude-plugin/plugin.json`'s version — directly targets the 2026-07-28 incident where the version sat unbumped for weeks and Claude Code's marketplace update never noticed.
> - **A PSScriptAnalyzer lint job was evaluated and *not* added.** Run cold against this repo it reports 123 warnings, overwhelmingly `PSAvoidUsingWriteHost`, a rule this project already knowingly violates on purpose. Gating CI on a ruleset the project doesn't hold itself to would contradict its own "a rule must name its incident" standard. Left as a separate future decision (pick a ruleset that fits, or clean up and suppress) rather than bundled in here. Re-run with a curated second ruleset and exact warning locations in [`docs/psscriptanalyzer-options.md`](psscriptanalyzer-options.md); still no decision made, just the numbers for whoever picks.
