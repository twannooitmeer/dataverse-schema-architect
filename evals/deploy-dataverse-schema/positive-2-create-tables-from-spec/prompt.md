---
name: "Create tables from an approved spec"
tags: [positive, deploy-dataverse-schema]
plugins: ["../../.."]
runs: 1
max_turns: 3
timeout_seconds: 120
---
Create the tables and columns defined in this approved Dataverse spec file against our dev environment.
