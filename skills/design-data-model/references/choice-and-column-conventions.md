# Choice and column conventions

These are not stylistic preferences — each one traces back to a real problem hit building the reference implementation this plugin generalizes from.

## Global choices by default, local picklists only when specifically requested

**Always propose a global choice set for a Choice column** — never suggest a local picklist unprompted. A global choice can be reused across tables and can be inspected and reasoned about consistently across a growing schema; a local picklist can't be reused, full stop, and only ever exists because someone deliberately wanted this one column's options scoped to this one table.

**If the human explicitly asks for a local picklist on a specific column** — "make that a local option set," "I don't want this one reusable" — go with it rather than talking them out of it; it's their call to make once they've said so. Still apply the rest of this convention exactly as if it were a global choice: explicit sequential values, never the publisher's auto-derived prefix (see below), and still flag the cross-environment portability risk in the moment, since a local picklist gets none of a global choice's reuse benefit and the caller should be choosing that trade-off knowingly, not by default.

**Every option's value is explicit**, starting from a fixed base such as `100000000` and incrementing sequentially — for both global choices and any requested local picklist. Never let the value default to the publisher's auto-derived prefix (Dataverse computes one from a hash of the publisher name, which looks like `100000000`-ish but isn't guaranteed identical across environments or across a publisher rename). A schema redeployed to a second environment — a second `TT-TEST`, a client's own environment, anywhere — must produce the *same* option values, and only explicit values guarantee that.

**If a choice's values are ever consumed by code that isn't Dataverse metadata itself** — a plugin, a Custom API, a Power Automate flow comparing a raw integer — treat those values as a contract. Confirm the exact values against whatever already-written code references them, rather than assuming a value scheme. A silent mismatch there produces wrong behavior with nothing to catch it at compile or run time.

## Business dates are Date Only, Time Zone Independent

Any date representing a calendar fact — something achieved, something expiring, something targeted for a date — uses **Date Only** format with **Time Zone Independent** (`DateOnly`) behavior, never `UserLocal`. A date stored as user-local shifts by time zone; someone traveling, or a scheduled process running in a different region, produces an off-by-one-day value that is silent until someone notices a date is wrong — the worst kind of bug, because nothing errors.

Reserve `UserLocal`/timestamp behavior for genuine moments-in-time (when a record was actually modified, when an event actually fired) — not for what this convention covers.

## Reserved view names — don't propose these exact names for a custom view

Dataverse auto-generates a small set of default views the moment a table is created, using the table's own display names:

- `Active {Plural}` — a record-state (active/inactive) view, not a business-status view
- `Inactive {Plural}`
- `My {Plural}` — a personal/"records I own" view

**If a proposed custom view's name exactly matches one of these patterns, it will silently create nothing** — an idempotency check that only compares names sees "already exists" (the platform's own view) and skips, and the intended business-filtered view never gets created. This was hit directly building the reference implementation: two of five intended views for a certification table came back "skip" on the very first deploy run, and only querying the live environment's actual views (not just trusting the tool's own log) revealed why.

Name custom views to describe what they actually filter on (e.g. "Achieved & Expiring Soon" rather than "Active Certifications") — this both avoids the collision and is a more honest name anyway, since "Active" is ambiguous between record state and business status.

## Column type reference

| Concept | Dataverse type | Notes |
|---|---|---|
| Short text | String | Set `maxLength` deliberately, not to whatever the deploy skill defaults to (100) |
| Long text | Memo | The deploy skill defaults `maxLength` to 2000 if left unset, but treat that as a fallback, not a real answer — a `Memo` column meant to hold actual prose (a disclaimer, a description) should almost always get an explicit `maxLength` sized to what the content genuinely needs |
| Whole number | Integer | Set explicit Min/Max where the domain has real bounds |
| Precise decimal | Decimal | Set `Precision` explicitly |
| Currency amount | Money | |
| Calendar date | DateTime, `DateOnly` behavior | See above — never `UserLocal` for these |
| Yes/No flag | Boolean (Two Options) | Not a Choice column — Two Options is a distinct type in Dataverse's own terminology, and this plugin's global-choice-by-default rule applies to Choice columns specifically |
| Single-select category | Choice, backed by a global choice set by default (local only if specifically requested) | See above |
| Image | Image | |
| Attachment | File | Set `MaxSizeInKb` deliberately |
| Reference to another row | Lookup (1:N relationship) | See the cascade-behavior guidance in the main SKILL.md — named presets only |

## Alternate keys

Propose an alternate key wherever there's a natural business-unique identifier (an external system's code, a combination that shouldn't legitimately repeat). Two things worth stating explicitly when proposing one:

- **Alternate key creation is asynchronous** server-side — Dataverse builds a unique index in the background. A deploy script that checks "does this key exist" immediately after creating a batch of them can get a false "not found" for a key that was already successfully queued moments earlier. The deploy skill's `New-DataverseAlternateKey` already handles this, and also polls the key to `Active` (or a bounded timeout, for a table with enough existing data that the index build genuinely takes a while) before returning — so a caller downstream of the deploy doesn't need to separately account for the key not being usable yet.
- Don't propose a key on a column where legitimate re-use of the same value combination is expected (e.g. someone re-certifying in a later year with the same exam code — the key should include the date to keep that combination unique, not exclude the date and block legitimate re-certification).
