# Reuse, Extend, or Create

Before proposing a new table, check whether an existing one already fits — either a Dataverse standard table or something already custom in this environment. Creating a table that duplicates an existing concept is harder to undo than checking first.

## Standard tables worth checking before anything else

| Table | Logical name | Reuse when | Don't reuse when |
|---|---|---|---|
| Contact | `contact` | The entity is a person external to the organization (a customer, a client contact) | The entity is an internal team member with employment attributes, cost rates, or certifications — that's a licensing and modeling mismatch, not just semantics |
| Account | `account` | The entity is an organization (a customer company, a partner, a vendor) | The entity needs highly specific attributes that would clutter a shared standard table used across every other integration |
| System User | `systemuser` | You need to reference "the licensed user who operates this system" | You need to reference "a person the business has a relationship with" regardless of whether they have a license — that's `contact` or a custom people table, not `systemuser` |
| Team | `team` | You need Dataverse's built-in ownership/security team concept | You need a business grouping concept unrelated to record ownership (e.g. a project team with a start/end date and members — that's usually better as a custom table with its own relationships) |

## Restricted and complex tables to avoid extending

Some tables require a Dynamics 365 application license to create/update/delete records, or carry complex server-side logic installed by a Dynamics 365 app. Check `EntityDefinitions(LogicalName='...')?$select=IsCustomEntity` and cross-reference the [restricted tables list](https://learn.microsoft.com/power-apps/maker/data-platform/data-platform-restricted-entities) before proposing to reuse or extend anything unfamiliar — `incident`, `sla`, `goal`, `knowledgearticle`, `entitlement`, and the `msdyn_*` Field Service/Project Service tables are the common ones.

**A related trap**: `bookableresource` and `bookableresourcebooking` are unrestricted *today* in a plain Dataverse environment, but installing Field Service or Project Service Automation later gives them server-side scheduling logic outside your control. If resource/booking concepts are part of the requirements and there's any chance those apps get installed later, prefer a custom table over these two specifically.

## Scoring existing custom tables in this environment

For each custom table discovered, decide:

- **Reuse** — the table's existing purpose, as evidenced by its columns and relationships, already covers what's needed. Confirm by actually reading its column list, not just its name — a table called `project` might already have everything a "project" concept needs, or might be a completely different shape than assumed.
- **Extend** — the table's core purpose matches, but it's missing columns the new requirements need. List exactly which columns to add.
- **Create** — nothing existing fits. Propose a new table, and check the proposed logical name doesn't collide with anything already in the environment (`EntityDefinitions(LogicalName='proposed_name')` — a 404 means it's clear).

## Collision handling

If a proposed new table's logical name already exists as something unrelated, don't silently pick a different name — surface the collision explicitly and either propose an alternative name or ask whether the existing table should be reused/extended instead. A discovered naming collision is exactly the kind of thing a design pass exists to catch before it becomes a deploy-time failure.
