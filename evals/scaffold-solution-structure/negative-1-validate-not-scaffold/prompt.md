---
name: "Check drift, don't scaffold"
tags: [negative, scaffold-solution-structure, near-miss]
plugins: ["../../.."]
runs: 1
max_turns: 3
timeout_seconds: 120
---
Check for solution component drift in my environment against solution-layout.json, don't change anything.
