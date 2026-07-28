# Safety rules — why each one exists

Every rule here traces back to something that actually broke while building the reference implementation this plugin generalizes from, not a hypothetical. Two of the highest-value ones are also enforced by hooks in this plugin (`../../hooks/`), not just documented here — see `hooks/hooks.json`.

## Solution targeting is mandatory on every create call

Every `New-Dataverse*` / `Add-Dataverse*` function in `Dataverse.psm1` requires `-SolutionUniqueName` and sends it as the `MSCRM.SolutionUniqueName` request header. There is no code path that creates something without it.

**Why:** without an explicit target, a component lands in whatever solution the environment currently has selected as default — which can silently be the wrong one, and is exactly the kind of mistake that's invisible until someone goes looking for a component and can't find it in the solution they expected.

**Enforced by:** the mandatory PowerShell parameter (fails immediately if omitted, not just documented as required) and `hooks/validate-solution-targeting.js`.

## Cascade behavior is one of three named presets — never raw flags

`Add-DataverseLookup -Cascade` accepts only `Referential`, `ReferentialRestrictDelete`, or `Parental` via a `ValidateSet`. There is no parameter that accepts a raw cascade-configuration object.

**Why:** "Referential" and "Parental" differ *only* in Delete behavior — Assign, Share, Unshare, and Reparent are `NoCascade` for both. Building a "Referential" relationship by hand and getting even one of those four wrong (setting it to Cascade) produces something Dataverse treats as parental-equivalent. Dataverse allows **at most one parental-like relationship per entity, full stop** — and the platform doesn't ask permission before enforcing it: the very next lookup created on that entity, however correctly configured, fails outright with "is parented to X, cannot create another parental relation." This happened for real, on the second lookup created on a table, and took real time to diagnose because the failing call looked completely unrelated to the one that actually caused it.

**Enforced by:** the `ValidateSet` (a raw cascade object literally cannot be passed) and `hooks/validate-cascade-config.js` as a second layer, in case something outside this module's own functions tries to hand-construct a relationship request.

## Global choices by default, local picklists only on explicit request

`Add-DataverseColumn -Type Choice` requires exactly one of `-GlobalChoiceName` or `-LocalOptions` and throws immediately if neither (or both) is given. `design-data-model` always proposes a global choice; a local picklist only ever appears in a spec because a human specifically asked for one on that column — this module doesn't default to it, but it isn't forbidden either.

**Why:** a local picklist's option values default to the publisher's auto-derived prefix, which is not guaranteed identical across environments or across a publisher rename — the same schema deployed twice can end up with different underlying integers for "the same" option. Anything downstream that compares a raw option value (a plugin, a flow, a report) then silently breaks with no compile-time or runtime error to catch it. Explicit, sequential values (from a fixed base such as `100000000`) sidestep this entirely regardless of global-vs-local, and a global choice additionally makes the values inspectable and reusable across tables — the reason it stays the recommended default rather than an equally-weighted option. `-LocalOptions` exists so the tool still says yes to a deliberate, informed choice rather than blocking it outright.

## Alternate keys are retried past "already exists," and polled to Active before returning

`New-DataverseAlternateKey` catches an "already exists" error on the create call itself, in addition to checking beforehand — and, on every path (create, skip, or the "already exists" catch), calls `Wait-DataverseAlternateKeyActive` before returning, which polls `EntityKeyIndexStatus` (a named enum: `Pending`/`InProgress`/`Active`/`Failed` — confirmed against Microsoft's own Web API reference before writing this, not assumed) until it reaches `Active`, throws if it reaches `Failed`, or logs a warning and returns after a bounded `-MaxWaitSeconds` (default 60) if it's still building.

**Why:** alternate key creation is asynchronous server-side (Dataverse builds a unique index as a background job). An existence check run immediately after a prior key was created can report "not found" for a key that's already successfully queued — the metadata hasn't caught up yet. Without the create-time catch, re-running a deploy in quick succession throws an unhandled fault on a key that isn't actually missing. The polling closes the remaining half of this gap: previously, this module returned as soon as the *create call* succeeded, before the key was necessarily *usable* — a caller that immediately upserts against it could hit a transient failure indistinguishable from a real bug. The wait is bounded rather than indefinite because index build time scales with existing row count, per Microsoft's own docs, so an already-large table could legitimately outlast any reasonable script timeout — a timeout warning is a status report, not a deploy failure, since the key genuinely was created and will finish on its own.

## View names are checked against Dataverse's own reserved patterns

`New-DataverseView` refuses (with a loud warning, not a silent no-op) to create a view whose name matches `Active {Plural}`, `Inactive {Plural}`, or `My {Plural}` for that table.

**Why:** Dataverse auto-generates views with exactly these names the moment a table is created — before this plugin, or any tool, ever touches it. A same-name check alone can't distinguish "this view already exists because I created it on a prior run" from "this view already exists because it's the platform's own default and has nothing to do with what I actually wanted to filter on." Two of five intended views for a real certification table were silently never created this way — discovered only by querying the live environment's actual views directly, not by trusting a tool's own "skip" log at face value.

## `IsSecured` is set automatically before any field permission

`Add-DataverseFieldPermission` calls `Set-DataverseFieldSecured` on the target column itself, before creating the permission record — the caller never has to remember this as a separate step.

**Why:** Dataverse rejects `FieldPermission` creation outright for a column that isn't marked `IsSecured = true`. This is easy to hit because nothing about *creating* a column implies it should be secured later — the two are genuinely separate operations, and forgetting the first produces a create-time error on the second that doesn't obviously point back at the real cause.

## Token reuse, not a fresh sign-in every run

`Get-DataverseToken` (called by `Connect-Dataverse`) tries, in order: PAC CLI's own token cache (best-effort, unsupported — see below), client secret (from `DATAVERSE_TENANT_ID`/`DATAVERSE_CLIENT_ID`/`DATAVERSE_CLIENT_SECRET`), then `az account get-access-token` (reuses whatever Azure CLI login session already exists), then device code — and device code itself is now cached and silently refreshed across runs (see below), not just within one run. Only a genuinely fresh device-code sign-in (no usable cached refresh token yet) requires a human at a browser.

**Why:** the alternative (a fresh interactive or device-code sign-in on every single run) is exactly the kind of friction that makes people avoid re-running a tool when they should — including re-running it to verify idempotency, which is how the alternate-key race above was actually caught in the first place.

## Auth provider priority is fixed: PAC cache, client secret, Azure CLI, device code — never reordered per-environment

`Get-DataverseToken` always tries PAC CLI's cache first, then checks for the three client-secret environment variables, before ever looking at whether Azure CLI is installed or logged in.

**Why:** locked-down customer tenants (the real case: a consultancy running this against many customers' Dataverse environments) routinely block the Azure CLI's first-party app, or require per-customer consent and an application user that isn't set up yet — `az login --tenant <customer>` failing with a non-obvious error was the original P1 finding this closes. PAC CLI's cache comes first specifically because this module already assumes PAC CLI is in place for environment discovery — when a token is already sitting there for the target environment, that's genuinely nothing new to set up, ahead of even a client secret. An explicit client-secret configuration is still a deliberate, unattended-use signal (three specific env vars, all required) and must win over whatever ambient `az` session happens to also exist on the same machine — an `az` login being present is coincidental, not evidence the caller wants it used.

## PAC CLI token-cache reuse is a documented, unsupported workaround — not an official mechanism

`Get-DataverseTokenFromPacCache` reads `%LOCALAPPDATA%\Microsoft\PowerAppsCli\tokencache_msalv3.dat` directly and unprotects it via Windows DPAPI (`CurrentUser` scope), rather than shelling out to `pac` — because `pac auth` has no public command that exports a token the way `az account get-access-token` does (confirmed against Microsoft's own CLI reference: `create`/`list`/`select`/`who` only manage which cached profile *other pac commands* use internally).

**Why this is safe to attempt, and why it's still labeled unsupported:** DPAPI `CurrentUser` protection can only be unprotected by the same Windows user account that protected it — the same account this process already runs as, and the same guarantee `pac` itself relies on to read its own cache. Nothing here decrypts anything this user couldn't already decrypt by running `pac` directly. It's labeled unsupported because the cache's file location, format, and protection scheme are undocumented implementation details of the `Microsoft.PowerApps.CLI` package, not a published contract — a future PAC CLI version could change any of them without notice. Every failure mode (wrong OS, missing file, DPAPI failure, unexpected JSON shape, no unexpired entry for this host) returns `$null`, never throws, so `Get-DataverseToken` always has three working fallbacks regardless of whether this one keeps working.

## Device-code sign-in is cached and silently refreshed — not repeated on every run

`Get-DataverseDeviceCodeAccessToken` persists the device-code flow's access and refresh token to a per-environment cache file (DPAPI-protected on Windows), and on a later call, uses the cached access token directly if still valid, or silently exchanges the refresh token for a new one if not — only falling to an actual interactive device-code prompt when neither works.

**Why:** without this, every single script run that fell back to device code (no Azure CLI, no client secret configured) would force a fresh browser sign-in, defeating the same "don't make re-running painful" reasoning the Azure CLI token-reuse rule above already exists for. A device-code refresh token is long-lived by design (the same trade Azure CLI itself makes for its own cached login) — reusing it is not a weaker security posture, just extending the same reasoning to the one auth path that didn't have it yet.

## Environment discovery never overrides an explicit `-EnvironmentUrl`

`Resolve-DataverseEnvironmentUrl` only calls out to `pac auth list --json` when `-EnvironmentUrl` is omitted entirely, and refuses to guess (throws with the full candidate list) when PAC CLI reports more than one environment and none is marked active.

**Why:** a pasted URL was always the actual mechanism, and pasted free text has no protection against a typo or a copied wrong URL — discovery exists to make the common single-environment case require zero typing, not to introduce a second, less certain way to pick a target when more than one environment is genuinely in play. `pac` not being installed, or not being logged into anything, silently falls back to requiring `-EnvironmentUrl` rather than turning into a harder error.

## Environment allowlist — refuses a write to a URL outside the configured list, unless forced

`Assert-DataverseEnvironmentAllowed` runs right before `Connect-Dataverse`. With no `-AllowedEnvironmentUrls` and no `DATAVERSE_ALLOWED_ENVIRONMENTS` set, it blocks nothing — this is opt-in, not a default behavior change for anyone already using this module against one environment. Once configured, a target host outside the list throws immediately, before any API call is made; `-Force` bypasses it deliberately.

**Why:** this is the actual prod-safety hole a free-text `-EnvironmentUrl` had from the start — nothing previously stopped a copy-pasted or mistyped URL from directing real create calls at the wrong environment. An allowlist configured once per machine or CI job (dev/test URLs only, say) turns that class of mistake into a loud failure instead of a live write.

## Publish is only needed - and only called - after the one UPDATE this module makes

`Set-DataverseFieldSecured` calls `Publish-DataverseEntity` (the Web API's `PublishXml` action, scoped to the one entity that changed) immediately after its `PUT`. Nothing else in this module calls it.

**Why:** confirmed against Microsoft's own docs before writing this, not assumed — "Solution components are published automatically when they are created or deleted. You must publish changes when solution components are updated." Every other function here (`New-DataverseTable`, `Add-DataverseColumn`, `New-DataverseGlobalChoice`, `Add-DataverseLookup`, `New-DataverseAlternateKey`, `New-DataverseView`, `New-DataverseSecurityRole`, `New-DataverseFieldSecurityProfile`, `Add-DataverseFieldPermission`) only ever creates — auto-published per that rule, so a blanket `PublishAllXml` at the end of every deploy would publish things this module never even touched, for no benefit. `Set-DataverseFieldSecured`'s `PUT` against an already-existing column is the sole exception, so that's the only call site that needs one — scoped to just that entity, not the whole organization's pending customizations, since Microsoft's own admin guidance warns that publishing "can interfere with normal system operation."

## `-WhatIf` is a structurally separate read-only path, not a flag threaded through every create call

`Deploy-DataverseSchema.ps1 -WhatIf` calls `Show-DataverseWhatIfPlan`, which only ever calls `Test-Dataverse*`/read (`GET`) functions — never any `New-Dataverse*`/`Add-Dataverse*` function.

**Why:** `$WhatIfPreference` does not propagate into an `Import-Module`'d module's own scope (confirmed by testing before writing this, not assumed) unless every function in the call chain re-declares `SupportsShouldProcess` and forwards it explicitly — a much larger surface than this feature is worth, and several of those functions (`New-DataverseSecurityRole`'s `roleId`, `New-DataverseFieldSecurityProfile`'s `fieldsecurityprofileid`) return an ID a later step depends on. Skipping the create but not the dependent lookup that follows it would hit a genuine null-reference failure under this module's `Set-StrictMode` — precisely on a first-ever deploy of a brand-new schema, the case a preview is most useful for. A structurally separate read-only path sidesteps this entirely rather than trying to fake IDs for items that were never actually created. The trade-off, stated plainly rather than hidden: security-role and field-security-profile items are previewed by existence only, not diffed at the privilege/permission level, since that would need to resolve privilege IDs from tables that may not exist yet either.

## Existing columns are checked for type drift, never silently trusted

When `Add-DataverseColumn` skips a column because it already exists, it calls `Test-DataverseColumnDrift`, which compares the live column's `AttributeTypeName` against what the spec's `-Type` should produce (confirmed against Microsoft's own column-type reference table — `StringType`, `MemoType`, `PicklistType`, and so on — not guessed) and warns, loudly, on a mismatch.

**Why:** create-if-missing means a column that's the wrong type stays the wrong type forever unless something says so — the "skip" log line otherwise reads identically whether the existing column matches the spec or not. This module deliberately never changes an existing column's type itself (that's a real migration decision, not something to do implicitly on a routine re-run), so a warning is the ceiling of what it can responsibly do here — surfacing the mismatch to a human is still strictly better than the previous silence. The check fails open: an unmapped `-Type`, an unreadable live attribute, or a read error all return quietly rather than raising a false positive.
