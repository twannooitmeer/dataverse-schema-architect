# Schema spec format

The JSON file `design-data-model` writes and `deploy-dataverse-schema` reads. One file describes one deployable schema increment — a full new model, or an addition to an existing one.

```json
{
  "solutionUniqueName": "TTSchema",
  "solutionFriendlyName": "TT Schema",
  "publisherUniqueName": "ttdev",
  "publisherFriendlyName": "Tacstone Technology B.V.",
  "publisherPrefix": "ttdev",
  "globalChoices": [
    {
      "name": "ttdev_resourcetype",
      "displayName": "Resource Type",
      "options": [
        { "value": 100000000, "label": "Employee" },
        { "value": 100000001, "label": "Contractor" }
      ]
    }
  ],
  "tables": [
    {
      "logicalName": "ttdev_resource",
      "displayName": "Resource",
      "pluralDisplayName": "Resources",
      "description": "A consultant, decoupled from their systemuser licence.",
      "ownership": "UserOwned",
      "primaryAttribute": { "schemaName": "ttdev_name", "displayName": "Full Name", "maxLength": 100 },
      "columns": [
        { "schemaName": "ttdev_email", "displayName": "Email", "type": "String", "maxLength": 100, "format": "Email" },
        { "schemaName": "ttdev_resourcetype", "displayName": "Resource Type", "type": "Choice", "globalChoiceName": "ttdev_resourcetype" },
        { "schemaName": "ttdev_quotestatus", "displayName": "Quote Status", "type": "Choice", "localOptions": [{ "value": 100000000, "label": "Draft" }, { "value": 100000001, "label": "Sent" }] },
        { "schemaName": "ttdev_costrate", "displayName": "Cost Rate", "type": "Money", "secured": true }
      ],
      "lookups": [
        {
          "relationshipSchemaName": "ttdev_role_ttdev_resource_defaultrole",
          "referencedEntity": "ttdev_role",
          "lookupSchemaName": "ttdev_defaultroleid",
          "lookupDisplayName": "Default Role",
          "cascade": "Referential",
          "required": false
        }
      ],
      "alternateKeys": [
        { "schemaName": "ttdev_resource_afascode", "displayName": "AFAS Employee Code", "keyAttributes": ["ttdev_afasemployeecode"] }
      ],
      "mainForm": { "fields": ["ttdev_email", "ttdev_resourcetype", "ttdev_defaultroleid"] }
    }
  ],
  "views": [
    {
      "entityLogicalName": "ttdev_certification",
      "name": "Achieved & Expiring Soon",
      "attributes": ["ttdev_name", "ttdev_certificationstatus"],
      "orderAttribute": "ttdev_expirydate",
      "filterXml": "<filter type=\"or\"><condition attribute=\"ttdev_certificationstatus\" operator=\"eq\" value=\"100000000\" /><condition attribute=\"ttdev_certificationstatus\" operator=\"eq\" value=\"100000001\" /></filter>"
    }
  ],
  "securityRoles": [
    {
      "name": "TT Consultant",
      "grants": [
        { "entity": "ttdev_resource", "type": "Read", "depth": "Global" },
        { "entity": "ttdev_resource", "type": "Write", "depth": "Basic" }
      ]
    }
  ],
  "fieldSecurityProfiles": [
    {
      "name": "TT Rate Visibility",
      "permissions": [
        { "entityLogicalName": "ttdev_resource", "attributeLogicalName": "ttdev_costrate", "attributeType": "MoneyAttributeMetadata", "canRead": true, "canCreate": true, "canUpdate": true }
      ]
    }
  ]
}
```

## Field notes

- **`solutionUniqueName`** — required at the top level. Every create call in the deploy run targets this solution. There is deliberately no per-table or per-column override; a schema increment belongs to one solution.
- **`publisherUniqueName` / `publisherFriendlyName` / `publisherPrefix`** — all optional, but required together (specifying one without the others fails validation before any API call). Omit all three when the publisher and `solutionUniqueName`'s solution already exist — this is the default assumption, and the only behavior a spec written before this feature existed ever had. Declare all three to opt into automatic publisher and solution creation, for a first deploy to a brand-new environment that has neither yet — see `New-DataversePublisher`/`New-DataverseSolution` in `Dataverse.psm1`.
- **`solutionFriendlyName`** — optional, only used when `publisherUniqueName` is also declared and the solution doesn't exist yet. Defaults to `solutionUniqueName` itself if omitted.
- **`tables[].ownership`** — `UserOwned` or `OrganizationOwned` only, matching Dataverse's own two options for a custom table.
- **`columns[].type`** — one of `String`, `Memo`, `Integer`, `Decimal`, `Money`, `DateOnly`, `DateTime`, `Image`, `File`, `Boolean`, `Choice`. `Choice` requires exactly one of `globalChoiceName` (recommended default — see `choice-and-column-conventions.md`) or `localOptions` (only when a local picklist was specifically requested for this column). `DateOnly` is for calendar facts (Time Zone Independent); `DateTime` is for genuine moments — when something actually happened (a sync timestamp, an error time) — and uses `UserLocal` behavior. Swapping these is exactly the mistake the project's date convention exists to prevent.
- **`columns[].maxLength`** — only meaningful for `String`/`Memo`. Omit it and the deploy skill picks a type-aware default (100 for `String`, 2000 for `Memo`, matching Dataverse's own maker-portal defaults) rather than one shared number — a `Memo` column holding real prose (a disclaimer, a description) should nearly always set this explicitly anyway, since even 2000 is a guess about what the content actually needs.
- **`columns[].localOptions`** — array of `{ value, label }`, same shape and same explicit-sequential-value convention as `globalChoices[].options`. Only used when `type` is `Choice` and `globalChoiceName` is absent; mutually exclusive with `globalChoiceName` on the same column.
- **`columns[].autoNumberFormat`** — only valid with `type: "String"`. A Dataverse autonumber format string (e.g. `"QUO-{SEQNUM:5}"` → `QUO-00001`); see Microsoft's `AutoNumberFormat` placeholder reference (`SEQNUM`, `RANDSTRING`, `DATETIMEUTC`). Requires `format` to be the default `Text` — Dataverse doesn't support autonumber on `Email`/`Url`/`TextArea`.
- **`tables[].primaryAttribute.autoNumberFormat`** — same mechanism, for the table's own primary name column (a quote or project number is typically the primary name itself, not a secondary column).
- **`columns[].secured`** — set `true` for any column a field security profile will later reference. The deploy skill sets `IsSecured` on the column automatically wherever this is `true`, before any `fieldSecurityProfiles[].permissions` entry referencing it is processed.
- **`lookups[].cascade`** — one of the three named presets only: `Referential`, `ReferentialRestrictDelete`, `Parental`. Never a raw cascade configuration object.
- **`tables[].mainForm.fields`** — optional array of column/lookup schema names, in display order, to add to the table's existing Main form. Each name must already be declared in that table's own `columns[]` or `lookups[]` — display name and type are resolved from there, never repeated. See `form-support.md` for what this does and doesn't support (Main form only, no custom tab/section layout, no `Image`/`File` fields).
- **Table order in the `tables` array is the creation order.** `design-data-model` is responsible for placing tables in dependency order (a table referenced by a lookup must appear before the table containing that lookup) — the deploy skill processes the array in the order given and does not re-sort it.
- **`securityRoles[].grants[].depth`** — one of `Basic` (a user's own records), `Local` (business unit), `Deep` (business unit + children), `Global` (organization-wide) — Dataverse's own four depths. Append/AppendTo are derived automatically for every `Read` grant at the same depth; don't list them explicitly.
- **`fieldSecurityProfiles[].permissions[].attributeType`** — the concrete Dataverse attribute metadata type name (e.g. `MoneyAttributeMetadata`, `StringAttributeMetadata`), required to address the typed update endpoint the Web API needs for setting `IsSecured`.

## What the deploy skill does with this file

1. Validates the file against this shape (required top-level keys, valid enum values) before making any API call — a malformed spec should fail fast with a clear message, not partway through a deploy.
2. Connects once (`Connect-Dataverse`), reusing the token for the whole run.
3. Processes in this fixed order, regardless of array order elsewhere: publisher & solution (only if `publisherUniqueName` is declared) → global choices → tables + their primary attribute → columns → lookups → main form fields → alternate keys → views → security roles → field security profiles. This mirrors the validated order from the reference implementation (the publisher and solution must exist before anything can target them; global choices and tables must exist before anything can reference them; a form field needs its column/lookup to exist first; alternate keys need their columns to exist; views need their table; security roles need target tables to resolve privilege IDs from).
4. Every step is create-if-missing — safe to re-run the same spec file after fixing one failure partway through, without recreating what already succeeded. A skipped column that doesn't match the spec's type is flagged with a `drift` warning rather than silently trusted; a skipped or newly-created alternate key is polled to `Active` (or a bounded timeout) rather than assumed usable the instant the create call returns.
5. Prints a summary at the end: created vs. skipped counts per category, and anything deliberately not handled (see the main SKILL.md's "Not handled yet" section).
