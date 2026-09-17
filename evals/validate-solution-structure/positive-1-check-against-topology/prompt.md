---
name: "Check structure against topology"
tags: [positive, validate-solution-structure]
plugins: ["../../.."]
runs: 1
max_turns: 3
timeout_seconds: 120
---
Check my solution structure against the declared topology in solution-layout.json, don't fix anything, just report.
