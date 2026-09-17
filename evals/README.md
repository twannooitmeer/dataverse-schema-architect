# Skill-trigger evals

Checks that each skill's `description` field triggers on the prompts it
should, and stays quiet on the prompts it shouldn't, run via `claude plugin
eval`, Claude Code's own eval harness. This is not a test of what a skill
*does*; it is a test of whether Claude picks the right skill (or correctly
picks none of them) for a given request, which is the only thing a
`description` field actually controls.

## Layout

```
evals/
├── design-data-model/
│   ├── positive-1-sales-pipeline/
│   ├── ...
│   ├── negative-1-postgres-near-miss/
│   └── ...
├── deploy-dataverse-schema/
├── scaffold-solution-structure/
├── validate-solution-structure/
└── report-issue/
```

One case per directory. Each case has:

- `prompt.md`: YAML frontmatter (`name`, `tags`, `plugins`, `runs`,
  `max_turns`, `timeout_seconds`) plus the prompt text itself. `plugins:
  ["../../.."]` points the case back at this repo's own plugin root, three
  levels up from `evals/<skill>/<case>/`.
- `graders/*.md`: one `tool_used` grader checking whether the `Skill` tool
  was invoked with this skill's name.

`runs: 1` and `max_turns: 3` keep each case cheap. The grader only needs to
see whether the skill got invoked, not watch a full deploy run play out
against a live (nonexistent, in CI) Dataverse environment.

## Coverage

Five skills, ten cases each: five prompts that should trigger the skill,
five that should not. Every skill's negative set includes at least one
**near-miss**, a prompt that shares surface vocabulary with the skill's own
trigger phrases but is a different task entirely:

| Skill | Near-miss negative(s) |
|---|---|
| `design-data-model` | "design a data model" for **PostgreSQL**, not Dataverse; "design a data model" for a **REST API** payload shape |
| `deploy-dataverse-schema` | "what tables should I create" (sounds like deploy, is actually a design request) |
| `scaffold-solution-structure` | "check for solution component drift" (structure-flavored, but read-only, `validate-solution-structure`'s job); "scaffold a **React** project" |
| `validate-solution-structure` | "scaffold the solution structure" (structure-flavored, but a creation request, `scaffold-solution-structure`'s job); "validate my **JSON schema file's syntax**" (validate-flavored, nothing to do with Dataverse) |
| `report-issue` | "report an issue" against a **different repo** (a company Jira board, or `microsoft/power-platform-skills` itself) |

50 cases total (5 skills times 10). See each skill's own directory for the
exact prompts and the reasoning captured in its case names.

## Running locally

`claude plugin eval` is an early-access feature, gated per organization. If
it isn't enabled for your account yet, `claude plugin eval` prints
`` `plugin eval` is currently in early access `` and exits. That's expected,
not a bug in this suite.

Once enabled:

```bash
# From the repo root
claude plugin eval .

# A single skill's cases
claude plugin eval . --case 'design-data-model/*'

# Only the near-miss negatives, across every skill
claude plugin eval . --tag near-miss

# Machine-readable report, for scripting against
claude plugin eval . --json eval-results.json --no-publish
```

Exit code `0` means every case scored at or above the `--threshold` (default
`1.0`, meaning every grader in every case must pass). A failing case usually
means one of two things: a skill's `description` picked up a phrase generic
enough to fire on a near-miss prompt, or a genuine trigger phrase drifted out
of the description during an edit and a positive case stopped matching.

## Running in CI

`.github/workflows/ci.yml` has an `evals` job that runs this suite on every
PR, but only when the `ANTHROPIC_API_KEY` repository secret is set. Without
it, the job is skipped outright (not failed) so a fork or an outside
contributor's PR isn't blocked by a credential they can't have. When the
secret is present but the organization doesn't have early access yet, the
job detects that ("early access" in the CLI's own output) and exits `0` with
a notice rather than failing the PR over a feature gate outside the
contributor's control. When both the secret and early access are present,
the job enforces the full `1.0` threshold and uploads `eval-results.json`
plus the harness's own `evals/results/` report as build artifacts.

## Adding a case

1. Pick the skill and whether the new prompt is a positive or a negative.
2. Create `evals/<skill>/<positive|negative>-<n>-<slug>/prompt.md` following
   an existing case's frontmatter shape.
3. Add `graders/skill-should-trigger.md` (positive, `min: 1`) or
   `graders/skill-should-not-trigger.md` (negative, `min: 0, max: 0`). Copy
   an existing grader and swap the skill name in `input_match`.
4. If the new case is a near-miss, tag it `near-miss` and add a row to the
   coverage table above. The whole point of a near-miss case is that its
   reasoning is visible, not just its pass/fail result.
