# Main form field support

`deploy-dataverse-schema` can add columns and lookups to a table's existing **Main** form (`systemform` type `2`). It never builds a form from scratch, and it doesn't touch any other form type.

## Why this mutates a live template instead of building a form

Every table already has an auto-generated Main form the moment it's created — Dataverse makes one automatically, with the primary name column already on it. Rather than hand-author a `<form>` XML root and its full `tabs`/`columns`/`sections`/`rows`/`cells` envelope, `Add-DataverseFormFields` (in `Dataverse.psm1`) retrieves that live form, parses its `formxml`, and appends one `<row><cell><control></cell></row>` per requested field into its first `<section>`.

**This traces to a specific, citable source**: Microsoft's own [`dataverse-skills`](https://github.com/microsoft/dataverse-skills) repo — a Microsoft-authored reference for exactly this kind of automated Dataverse tooling — states plainly that "a hand-authored `<form>` root is the #1 cause of 'required id' / schema-rejection errors," and recommends retrieving a live form as a template and mutating it instead. This module follows that guidance directly rather than reinventing the form-XML envelope from first principles.

## The control classid table

Every `<control>` element needs a `classid` GUID identifying which UI control renders that field. These are **not published in Microsoft's current Form XML Schema reference** (confirmed by reading it in full before writing any code) — the table below is sourced from the same `microsoft/dataverse-skills` repo's [`forms-and-views.md`](https://github.com/microsoft/dataverse-skills/blob/main/.github/plugins/dataverse/skills/dv-metadata/references/forms-and-views.md) reference, not guessed:

| Column `-Type` (or `Lookup`) | Control | classid |
|---|---|---|
| `String` | Text | `{4273EDBD-AC1D-40d3-9FB2-095C621B552D}` |
| `Memo` | Multiline Text | `{E0DECE4B-6FC8-4a8f-A065-082708572369}` |
| `Integer` | Whole Number | `{C6D124CA-7EDA-4a60-AEA9-7FB8D318B68F}` |
| `Decimal` | Decimal | `{C3EFE0C3-0EC6-42be-8349-CBD9079C5A6F}` |
| `Money` | Currency | `{533B9108-5A8B-42cb-BD37-52D1B8E7C741}` |
| `DateOnly` / `DateTime` | Date/Time | `{5B773807-9FB2-42db-97C3-7A91EFF8ADFF}` |
| `Boolean` | Toggle | `{67FAC785-CD58-4f9f-ABB3-4B7DDC6ED5ED}` |
| `Choice` | Picklist | `{3EF39988-22BB-4f0b-BBBE-64B5A3748AEE}` |
| `Lookup` | Lookup | `{270BD3DB-D9AF-4782-9025-509E298DEC0A}` |

`Image` and `File` columns have **no verified classid** and are deliberately unsupported on forms — `Get-DataverseFormControlClassId` throws rather than guessing one.

## Idempotency

Adding the same field twice is a no-op: `Add-DataverseFormField` checks for an existing `<control datafieldname="...">` anywhere on the form before adding anything. `Add-DataverseFormFields` (plural) only `PATCH`es the form and publishes if at least one field genuinely needed adding — an unmodified form is left alone entirely, matching this module's create-if-missing philosophy everywhere else.

Per the safety rule already established for `Set-DataverseFieldSecured` (see `safety-rules.md`), an **update** to an already-existing solution component needs an explicit publish — creates are auto-published, updates aren't. The form `PATCH` here is exactly that case, so it calls `Publish-DataverseEntity` right after, scoped to just the one table that changed.

## What's not supported yet

- **Quick Create, Quick View, and Card forms.** Only the Main form (`type = 2`). Extending to other form types is a reasonable future addition — the same retrieve-template-and-mutate approach should generalize — but hasn't been built or tested.
- **Custom tab/section layout.** Every field lands in the template's first (and normally only) section, in the order given. No control over tabs, multiple sections, or column count.
- **Reordering or removing existing fields.** This module only ever adds; it never repositions or deletes a control already on the form.
- **Image and File fields**, for the reason above.

## Spec format

See `spec-format.md`'s `tables[].mainForm.fields` field notes. In short: an array of column/lookup schema names already declared elsewhere in the same table — the display name and type are looked up from there, not repeated.
