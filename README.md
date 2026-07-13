# Data — Heeero Skills Taxonomy

A Phoenix app for capturing, storing, and reasoning over a curated
industry skill/role taxonomy for Heeero — which roles are synonyms of
each other, which skills support a role, which roles look similar but
must never be confused ("hard negatives"), and which are excluded from
matching for compliance reasons.

The problem it solves: matching workers to jobs on raw semantic
similarity (embeddings) reliably finds roles that are lexically or
contextually close, but can't be told "these two look alike but are
different jobs." This app stores that explicit, curated negative
knowledge — sourced from domain-expert-filled spreadsheets — durably and
versioned, and reasons over it symbolically so a match/exclusion
decision is explainable ("why was this pair excluded?"), not a black
box.

This app is **standalone** — it does not modify `heeero_core`'s live
Skills-matching system. It's an exploration of whether this
curated-taxonomy approach improves match quality; if it does, the
expected integration shape is this app exposing itself as an API
service `heeero_core` calls into, not a code merge.

Full design doc, including what's built vs. still open:
[`design/SKILLS_TAXONOMY.md`](design/SKILLS_TAXONOMY.md).

## How the parts fit together

```
Spreadsheet/CSV (domain experts)          LiveView forms
        │                                       │
        ▼                                       ▼
  CsvImporter / XlsxImporter  ──┐      RoleLive (new/edit)
        (parsing)               │              │
                                 ▼              ▼
                          RowBuilder (shared validation/document-building)
                                 │
                                 ▼
                        Importer.import/2
                                 │
                                 ▼
                        TerminusDB (versioned document store)
                         Role · Skill · RoleRelation
                                 │
                    ┌────────────┴────────────┐
                    ▼                          ▼
      Reasoning.Loaders.SkillTaxonomy    XlsxExporter
      (facts) → Reasoning.Catalogs       (TerminusDB → readable
      .SkillTaxonomy (ExDatalog rules)    spreadsheet, for review)
                    │
                    ▼
       eligible/2, excluded/2, flagged_for_review/2
       (explainable match/exclusion decisions)
```

- **Data entry** — three paths write the same underlying documents:
  CSV import (`Data.SkillTaxonomy.CsvImporter`), XLSX import
  (`Data.SkillTaxonomy.XlsxImporter`, for the Heeero Role
  Differentiation Template), and a LiveView form
  (`DataWeb.SkillTaxonomy.RoleLive`, at `/skill_taxonomy/roles/new`).
  All three build documents through the shared
  `Data.SkillTaxonomy.RowBuilder`, then persist through
  `Data.SkillTaxonomy.Importer.import/2`, so validation and write logic
  live in one place regardless of entry path.
- **Storage** — [TerminusDB](guides/terminusdb.md), a versioned
  document database, holds three document classes: `Role`, `Skill`,
  and `RoleRelation` (the typed edge between them — `supporting`,
  `type_of`, `sibling`, `hard_negative`, `easy_negative`, `exclusion`,
  `manual_review`). Every write is a commit, so provenance ("who added
  this hard negative, and when") is queryable.
- **Reconciliation** — imports can auto-create placeholder "stub"
  roles for cross-referenced targets that don't have their own entry
  yet; a fraction of these turn out to be the same real-world role
  spelled differently. `DataWeb.SkillTaxonomy.ReconciliationLive`
  (`/skill_taxonomy/reconciliation`) surfaces name-clustered stubs for
  a human to merge, keep separate (with a weight), or mark unrelated.
- **Export** — `Data.SkillTaxonomy.XlsxExporter` reads the current
  TerminusDB state back out into the same template shape, so anyone
  can review the live data as a spreadsheet, including edits made only
  through the LiveView.
- **Reasoning** — `Data.Reasoning.Catalogs.SkillTaxonomy` loads
  `RoleRelation` facts (`Data.Reasoning.Loaders.SkillTaxonomy`) into
  [`ExDatalog`](https://hexdocs.pm/ex_datalog) and derives
  `eligible/2`/`excluded/2`/`flagged_for_review/2` — a role pair is
  excluded if a symmetric hard-negative, easy-negative, or exclusion
  relation connects them, regardless of embedding similarity.
- **Planned, not yet built** — an Nx-based similarity layer to sharpen
  embedding-space separation using the curated pairs as training
  signal, and Choreo-based graph visualization. See §7–8 of the design
  doc.

## Running it

* Copy `.env.example` to `.env` and set `TERMINUSDB_ADMIN_PASS` (see
  [`guides/terminusdb.md`](guides/terminusdb.md) for all connection
  settings)
* `mix setup` — install and set up dependencies
* `mix terminus.setup` — create the TerminusDB database and sync the
  document schema (idempotent, safe to re-run after schema changes)
* `mix phx.server` (or `iex -S mix phx.server`) — start the app at
  [`localhost:4000`](http://localhost:4000)

Key routes: `/skill_taxonomy/roles/new` (add a role),
`/skill_taxonomy/reconciliation` (resolve duplicate stubs).

Run `mix precommit` before committing — compiles with warnings as
errors, checks formatting, and runs the test suite.

## Learn more

* Design doc: [`design/SKILLS_TAXONOMY.md`](design/SKILLS_TAXONOMY.md)
* TerminusDB integration: [`guides/terminusdb.md`](guides/terminusdb.md)
* Official Phoenix docs: https://phoenix.hexdocs.pm
