---
name: report-issue
description: >
  Use this skill when the user wants to "report a bug", "file an issue",
  "report an issue", "submit a bug report", or report any problem
  with the dataverse-schema-architect plugin to its GitHub repository.
user-invocable: true
argument-hint: "[optional: brief description of the bug]"
allowed-tools: Read, Bash, Glob, Grep, AskUserQuestion, TaskCreate, TaskUpdate, TaskList
model: sonnet
---

Follow the complete workflow in `report-issue-workflow.md`, in this same directory, exactly as written. Do not skip phases or shortcut the preview step — the target repository is public, and the preview-before-create phase exists specifically to catch anything sensitive (a real environment URL, a tenant ID, a token) before it becomes a public GitHub issue.
