# Bug report workflow

Track all 5 phases with TaskCreate/TaskUpdate as you go.

## Phase 1: Identify plugin and version

Read `${PLUGIN_ROOT}/.plugin/plugin.json` and extract `name` and `version`. If either field can't be determined, ask the user directly rather than guessing.

## Phase 2: Gather bug details

Extract anything already given in the initial request (the `argument-hint` text, if present). Then, across a small number of focused questions rather than one long form:

1. Which skill or script was involved (`design-data-model`, `deploy-dataverse-schema`, a specific PowerShell function), and a description of the problem.
2. Reproduction steps, expected behavior, actual behavior.
3. Offer to auto-collect environment info — OS, PowerShell version (`$PSVersionTable.PSVersion`), Azure CLI version (`az version`), Claude Code version — or let the user skip this.
4. Ask if they want to include logs or command output. If yes, get them to paste the relevant portion — never read arbitrary log files yourself without being shown what's in them first, since this becomes a public issue.

## Phase 3: Preview before creating anything

**This is the phase that matters most for this plugin specifically.** Warn plainly that the target repository is public, and that a spec file, an environment URL, a tenant ID, or a solution name could all be sensitive depending on context. Show the exact formatted issue body before creating anything, and scan it yourself for anything that looks like a real credential, a real tenant/org identifier, or a real customer name — flag it back to the user rather than silently including it.

Confirm approval, or revise and preview again, before Phase 4. Never proceed to creating the issue without an explicit yes on the preview.

## Phase 4: Create the issue

Format the issue body:

```
## Environment
- Plugin version: <from Phase 1>
- OS / PowerShell / Azure CLI: <from Phase 2, if collected>

## Skill/script
<from Phase 2>

## Description
<bug description>

## Steps to reproduce
<from Phase 2>

## Expected behavior
<from Phase 2>

## Actual behavior
<from Phase 2>

## Logs
<if provided>
```

Verify `gh` CLI is authenticated (`gh auth status`) before attempting anything. Then:

```bash
gh issue create --repo twannooitmeer/dataverse-schema-architect \
  --title "<short title from the description>" \
  --label bug \
  --body "<formatted body above>"
```

Capture the resulting issue URL from the command output.

## Phase 5: Summarize

Show the created issue URL and tell the user they can track progress on GitHub. Don't say more than that — this phase is a confirmation, not a new conversation.
