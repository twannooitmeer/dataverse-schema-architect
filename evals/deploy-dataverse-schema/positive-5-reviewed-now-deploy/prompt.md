---
name: "Deploy after review"
tags: [positive, deploy-dataverse-schema]
plugins: ["../../.."]
runs: 1
max_turns: 3
timeout_seconds: 120
---
I've reviewed the spec and it looks right, now deploy it to our Dataverse environment.
