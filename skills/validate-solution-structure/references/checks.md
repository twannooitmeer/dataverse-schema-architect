# Checks — what each one catches and why

This skill is read-only. Every check below reports drift for a human to act on; none of them move, reassign, or delete a component. Reassigning a component's owning solution isn't always even possible without recreating it (a component created under one publisher can't be shared with a solution under a different publisher), so silently "fixing" drift isn't a safe default this skill could offer even if it wanted to.

## Component-type drift — borrowed directly from Microsoft's own tool

For each layer, every `solutioncomponent` actually in that layer's solution is checked against its declared `allowedComponentTypes`. Anything present whose type isn't allowlisted is reported.

**Why:** this is the exact mechanism Microsoft's own [Solution Component Validation Tool](https://learn.microsoft.com/dynamics365/guidance/resources/solution-component-validator) (a FastTrack-published managed solution) uses — an allowlist of component object type codes per monitored solution, checked against live `solutioncomponent` rows, with anything outside the allowlist reported. That tool ships as an installed, always-on watcher (an entity, a security role, and a Power Automate flow that emails a report). This skill reproduces the same check on demand, through the same `Invoke-DataverseApi` this project already uses for everything else, rather than requiring a second managed solution installed into the environment. Microsoft's own guidance is explicit about the cost of not catching this: teams that don't follow horizontal segmentation hit "solution layering problems and dependency conflicts [that] take significant time to resolve."

## Cross-layer duplicate ownership — not in Microsoft's own tool

After every layer's components are fetched, every component's `objectid` is checked across *all* layers together. A component appearing under more than one layer's solution is flagged, regardless of whether its type is separately allowlisted in each.

**Why this is checked in addition to type drift, not folded into it:** Microsoft's own tool checks each monitored solution independently — an allowlist violation is scoped to one solution at a time, and it has no mechanism to notice the same component sitting in two solutions it separately monitors. But a component landing in more than one solution is a materially different, and generally worse, failure: on managed import, the last-imported layer's copy silently wins, producing exactly the kind of hard-to-diagnose layering drift horizontal segmentation exists to prevent in the first place. The rule this closes is as simple as it is easy to violate by accident: **every component has exactly one owning solution.**

## Publisher consistency across layers

Every layer's resolved solution has its publisher's unique name compared against the topology file's single `publisherUniqueName`.

**Why this runs before, not alongside, component-type checking:** a publisher mismatch invalidates the premise of the whole topology, not just one layer's compliance with it. A component can't be shared between two solutions registered under different publishers — it would have to be deleted and recreated under the correct one, which is exactly the kind of irreversible, expensive mistake horizontal segmentation is meant to make structurally hard, not something a later component-type fix could paper over. Confirming every layer resolves to the same publisher first means a real component-type finding can be trusted at face value, instead of being downstream of a wrong-publisher layer that shouldn't have existed as configured.

## Dependency-graph sanity (topology file only, no API calls)

`dependsOn` values are checked for internal consistency before any Dataverse call is made: every referenced layer name must resolve to a real layer in the same file, and the graph must not contain a cycle.

**Why this is deliberately limited to the file itself:** Dataverse's actual import-order constraint is enforced entirely through `dependency` records, and those are only created once a real cross-layer reference exists — a form referencing a PCF control, a plugin step registered on a table, a flow calling a Custom API. With zero components anywhere, or components that don't yet reference each other across layers, there is nothing for an import-order violation to attach to; any of the layers would import cleanly in any sequence at that stage. Verifying the *actual*, enforced dependency graph would mean exporting and unpacking each solution to inspect `Solution.xml`'s `<MissingDependencies>`, a materially heavier operation than a read-only Web API check and out of scope here. What this check *can* catch cheaply and cheaply only — a self-contradictory topology declared by a human, before it's ever tested against a real environment — is worth doing anyway, since it costs nothing and a cyclic or dangling `dependsOn` is a pure authoring mistake, not something Dataverse itself would ever need to be consulted about.

## What this skill deliberately does not check

- **Whether declared dependency order is actually enforced on import.** See above — this needs a real export/import cycle, not a live read-only query.
- **Privilege- or permission-level content** of Role/Field Permission components that happen to be correctly placed — this skill checks *placement* (which solution owns a component), not the component's own configuration correctness. `deploy-dataverse-schema`'s own `-WhatIf` drift detection is the place for spec-vs-live content comparison, for the narrower set of components it creates.
- **Solution version or managed/unmanaged state** beyond what's needed to resolve a solution by name. A topology check is orthogonal to where each layer is in its own release lifecycle.
