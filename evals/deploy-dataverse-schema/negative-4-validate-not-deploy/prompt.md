---
name: "Check solution structure, not deploy"
tags: [negative, deploy-dataverse-schema]
plugins: ["../../.."]
runs: 1
max_turns: 3
timeout_seconds: 120
---
Check whether my solution structure matches the declared topology before I touch anything.
