---
name: "Check TypeScript lint status"
tags: [negative, validate-solution-structure]
plugins: ["../../.."]
runs: 1
max_turns: 3
timeout_seconds: 120
---
Check whether my TypeScript project passes lint before I open the PR.
