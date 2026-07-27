# Safety rules — why each one exists

Every rule here traces back to something that actually broke while building the reference implementation this plugin generalizes from, not a hypothetical. Two of the highest-value ones are also enforced by hooks in this plugin (`../../hooks/`), not just documented here — see `hooks/hooks.json`.

## Solution targeting is mandatory on every create call

Every `New-Dataverse*` / `Add-Dataverse*` function in `Dataverse.psm1` requires `-SolutionUniqueName` and sends it as the `MSCRM.SolutionUniqueName` request header. There is no code path that creates something without it.

**Why:** without an explicit target, a component lands in whatever solution the environment currently has selected as default — which can silently be the wrong one, and is exactly the kind of mistake that's invisible until someone goes looking for a component and can't find it in the solution they expected. Microsoft's own `add-dataverse` reference doesn't explicitly address this at all, which is the specific gap this plugin closes rather than inherits.

**Enforced by:** the mandatory PowerShell parameter (fails immediately if omitted, not just documented as required) and `hooks/validate-solution-targeting.js`.

## Cascade behavior is one of three named presets — never raw flags

`Add-DataverseLookup -Cascade` accepts only `Referential`, `ReferentialRestrictDelete`, or `Parental` via a `ValidateSet`. There is no parameter that accepts a raw cascade-configuration object.

**Why:** "Referential" and "Parental" differ *only* in Delete behavior — Assign, Share, Unshare, and Reparent are `NoCascade` for both. Building a "Referential" relationship by hand and getting even one of those four wrong (setting it to Cascade) produces something Dataverse treats as parental-equivalent. Dataverse allows **at most one parental-like relationship per entity, full stop** — and the platform doesn't ask permission before enforcing it: the very next lookup created on that entity, however correctly configured, fails outright with "is parented to X, cannot create another parental relation." This happened for real, on the second lookup created on a table, and took real time to diagnose because the failing call looked completely unrelated to the one that actually caused it.

**Enforced by:** the `ValidateSet` (a raw cascade object literally cannot be passed) and `hooks/validate-cascade-config.js` as a second layer, in case something outside this module's own functions tries to hand-construct a relationship request.

## Global choices only, explicit sequential values

`Add-DataverseColumn -Type Choice` requires `-GlobalChoiceName` and throws immediately if it's missing. There is no local-picklist code path anywhere in this module.

**Why:** a local picklist's option values default to the publisher's auto-derived prefix, which is not guaranteed identical across environments or across a publisher rename — the same schema deployed twice can end up with different underlying integers for "the same" option. Anything downstream that compares a raw option value (a plugin, a flow, a report) then silently breaks with no compile-time or runtime error to catch it. Explicit, sequential values (from a fixed base such as `100000000`) sidestep this entirely, and a global choice at least makes the values inspectable and reusable across tables — Microsoft's own reference documents local picklists only, so this is a genuine improvement, not a stylistic preference.

## Alternate keys are retried past "already exists," not just pre-checked

`New-DataverseAlternateKey` catches an "already exists" error on the create call itself, in addition to checking beforehand.

**Why:** alternate key creation is asynchronous server-side (Dataverse builds a unique index as a background job). An existence check run immediately after a prior key was created can report "not found" for a key that's already successfully queued — the metadata hasn't caught up yet. Without the create-time catch, re-running a deploy in quick succession throws an unhandled fault on a key that isn't actually missing.

## View names are checked against Dataverse's own reserved patterns

`New-DataverseView` refuses (with a loud warning, not a silent no-op) to create a view whose name matches `Active {Plural}`, `Inactive {Plural}`, or `My {Plural}` for that table.

**Why:** Dataverse auto-generates views with exactly these names the moment a table is created — before this plugin, or any tool, ever touches it. A same-name check alone can't distinguish "this view already exists because I created it on a prior run" from "this view already exists because it's the platform's own default and has nothing to do with what I actually wanted to filter on." Two of five intended views for a real certification table were silently never created this way — discovered only by querying the live environment's actual views directly, not by trusting a tool's own "skip" log at face value.

## `IsSecured` is set automatically before any field permission

`Add-DataverseFieldPermission` calls `Set-DataverseFieldSecured` on the target column itself, before creating the permission record — the caller never has to remember this as a separate step.

**Why:** Dataverse rejects `FieldPermission` creation outright for a column that isn't marked `IsSecured = true`. This is easy to hit because nothing about *creating* a column implies it should be secured later — the two are genuinely separate operations, and forgetting the first produces a create-time error on the second that doesn't obviously point back at the real cause.

## Token reuse, not a fresh sign-in every run

`Connect-Dataverse` tries `az account get-access-token` first, which reuses whatever Azure CLI login session already exists — no separate sign-in flow at all if `az login` has already happened. The device-code fallback only engages when Azure CLI genuinely isn't available.

**Why:** the alternative (a fresh interactive or device-code sign-in on every single run) is exactly the kind of friction that makes people avoid re-running a tool when they should — including re-running it to verify idempotency, which is how the alternate-key race above was actually caught in the first place.
