# Skills Taxonomy — Test Plan

Tests to write **before** implementation for
[`SKILLS_TAXONOMY.md`](SKILLS_TAXONOMY.md), organized by the same phased
roadmap (§8 there). Each phase's tests should exist and fail (red) before
that phase's code is written, matching how `Data.Reasoning.Catalogs.Rbac`
was validated against `test/data/reasoning/catalogs/rbac_test.exs` and
`test/data/reasoning/store_test.exs` before it was declared done.

No test code is written yet — this is the plan for what those files will
contain.

---

## Phase 1 — TerminusDB schema

`test/data/terminus_db/schema_test.exs` (extends existing coverage):

- `classes/0` includes `Role`, `Skill`, and `RoleRelation`, each with the
  field set from the design doc §3.
- Every class has a distinct `@id` and valid TerminusDB type syntax
  (structural check — a malformed class map should be caught here, not
  discovered against the live server).

Integration (against the real `mark-i5.mediazu.org` instance, same
pattern as the existing `mix terminus.setup` verification):

- `mix terminus.setup` run twice back-to-back is a no-op the second time
  (idempotency — already proven for the general mechanism; re-verify with
  these three classes specifically since `Document.replace` schema sync
  is new territory for embedded subdocument types like `Role.synonyms`).

## Phase 2 — CSV importer

Split into two functions, because `RoleRelation.from`/`to` must hold the
exact `@id` TerminusDB assigns a `Role`/`Skill` — and that can only be
learned from TerminusDB's own insert response, not predicted (its
Lexical-key percent-encoding doesn't match Elixir's `URI.encode/2`; e.g.
it leaves `&` unescaped where `URI.encode/2` would not — confirmed
against `Banquet and Event F&B Supervisor`). So `parse/1` is pure and
produces `Role`/`Skill` documents plus *pending* relations addressed by
natural key, not yet a real `@id`; `import/2` does the actual TerminusDB
round trip — insert roles/skills, read the `@id` each insert response
returns, then build and insert `RoleRelation` documents from those.

### `parse/1` — pure, no network

`test/data/skill_taxonomy/csv_importer_test.exs`:

- A valid single-role row (all seven guide sections populated) parses
  into one `Role` document map and N pending-relation entries, one per
  listed relationship, with `relation_type` set correctly per column,
  and any `supporting` targets also producing a `Skill` document.
- A file with multiple primary-role rows parses into distinct, correctly
  separated `Role`/pending-relation sets — no cross-contamination
  between rows. `Skill` documents are deduplicated across rows (the same
  skill named in two different roles' `supporting` column produces one
  `Skill` document, not two).
- List-columns (`synonyms`, `supporting`, `type_of`, `sibling`,
  `hard_negatives`, `easy_negatives`, `exclusions`) split on `;`,
  trimmed, empty entries dropped.
- Missing `primary` column/value → import error for that row, not a
  crash of the whole file — and that row contributes no `Role`, `Skill`,
  or pending relations to the result (errors and success are exclusive
  per row).
- A malformed header (missing or misnamed column, e.g. `hard_negative`
  singular instead of `hard_negatives`) → a single top-level error for
  the whole file, not a per-row one — a header mismatch invalidates
  every row's column interpretation, not just one row's.
- Fewer than 2 synonyms, or 0 hard negatives → **warning**, not a
  rejection (the guide's minimums are contributor guidance, not a system
  invariant) — assert the parsed result carries a warnings list alongside
  the data.
- `confidence` defaults to `"guess"` when the column is blank; explicit
  `"sure"`/`"guess"` values pass through unchanged; anything else →
  row-level error.
- `weight` is never read from a column — there isn't one (per design doc
  §2, it's system-computed, never contributor-set) — assert a
  pending-relation entry has no `weight` key at all (it's set later, at
  `import/2` time, not by `parse/1`).
- A row with blank `context` produces a `Role` identified by `primary`
  alone (`context: ""`).
- A row with a non-blank `context` produces a `Role` identified by
  `primary` + `context`, distinct from the blank-context row for the
  same `primary`, plus an auto-generated pending `type_of` relation
  pointing at that blank-context role — assert this pending relation is
  present even though it's absent from the row's own `type_of` column.
- A `context` row whose `primary` has no corresponding blank-context row
  anywhere in the file → import error for that row (the base role must
  exist first). The base-role check considers *every* blank-context row
  in the file, even one that itself separately errors as a duplicate
  (§ below) — one row's problem shouldn't cascade into rejecting an
  unrelated variant row.
- Two rows with the same `primary` and the same `context` (both blank,
  or both the same non-blank value) → import error for both rows
  (duplicate role identity), not a silent overwrite of one by the other.
- `description` passes through as free text on the `Role` document,
  unvalidated beyond "present or blank" — this field is documentation,
  not something the importer should try to parse or constrain.
- Each synonym's `locale` is inherited from the row's own `locale`
  column (the CSV format has no per-synonym locale column) — documented
  as a known simplification, not silently assumed.

### `import/2` — the TerminusDB round trip

`test/data/skill_taxonomy/csv_importer_import_test.exs`, using a stubbed
`TerminusDB.Config` `adapter:` (per the `terminusdb_client` doctest
pattern — no real network needed to test the *wiring*, since we're not
testing TerminusDB's own encoding behavior here, only that this code
correctly threads an insert response's `@id` into the next request):

- Given a `parse/1` result with one role and one pending relation to
  itself... (use two distinct roles in practice) — the stub returns a
  fixed fake `@id` for each role/skill insert; assert the subsequent
  `RoleRelation` insert request body's `from`/`to` fields match those
  stubbed ids exactly, not a locally-reconstructed guess.
- Role/skill insert requests happen before any relation insert request
  (order matters — a relation can't be built until its endpoints' real
  ids are known).
- An insert failure partway through (stubbed error response) surfaces
  as `{:error, _}` from `import/2` rather than silently continuing with
  a partial import.
- Writes go through `Document.replace(create: true)`, not
  `Document.insert` — verified as a `:put` request in the stub. Found
  during implementation: `insert/3` errors if the Lexical-keyed id
  already exists, which would make re-importing the same CSV fail
  instead of updating in place, defeating the whole point of Lexical
  keys giving idempotent re-import for free (Phase 1). Matches how
  `Data.TerminusDB.Setup.ensure_schema!/2` already handles this
  elsewhere in the app.

### Integration check (against the real `mark-i5.mediazu.org` instance)

Not a permanent automated test — a one-off `mix run` verification, same
pattern used to validate the Phase 1 schema — running `import/2` against
a small real CSV excerpt and confirming the resulting `RoleRelation`
documents' `from`/`to` actually resolve to real `Role`/`Skill` documents
when read back. **Done** — verified with a self-contained two-role
excerpt (Bartender/Bar Back, all four symmetric-shaped relation types),
including running `import/2` twice to confirm the second run doesn't
duplicate relations (8 both times). All verification documents deleted
afterward; nothing left on the live server from this phase.

**Known limitation, not yet decided:** a relation target not present in
the *same* import batch (e.g. `Bartender`'s `sibling` column naming a
role that isn't itself a row in this file, and wasn't imported in an
earlier run either) fails with `{:unresolved_reference, key}` —
`import/2` only resolves against ids from documents it just wrote in
this call, not against anything already in TerminusDB from a prior
import. `seed_roles.csv` doesn't hit this (every relation target in it
is also a primary role somewhere else in the same file), but any future
incremental/partial import could. Needs a decision before that's a real
workflow: either look up existing documents too (a live query, not just
this batch's insert responses), or treat cross-batch references as
out of scope and require every file to be self-contained.

## Phase 3 — LiveView entry form

`test/data_web/live/skill_taxonomy/role_live_test.exs`:

- Mount renders all seven guide sections as distinct form blocks.
- Each dynamic list (synonyms, supporting, etc.) supports add/remove via
  its own LiveView event, independently of the others.
- Submitting a valid form calls the same document-building function as
  the CSV importer (assert via a stubbed TerminusDB adapter that the
  resulting `insert` payload matches what Phase 2's importer would
  produce for equivalent input — proves the two entry paths stay in
  sync).
- Submitting with `primary` blank shows a validation error and does not
  call `TerminusDB.Document.insert`.
- Editing an existing role pre-fills every section correctly from a
  stubbed `Document.get` response, including list-valued fields.

## Phase 4 — Reasoning catalog and loader

`test/data/reasoning/catalogs/skill_taxonomy_test.exs` (mirrors
`rbac_test.exs`):

- Catalog declares exactly the relations listed in design doc §5, at
  arity 3 (`{from, to, weight}`) for every base relation.
- `hard_negative_sym/3`: a fact authored as `hard_negative(A, B, W)`
  derives `hard_negative_sym(A, B, W)` **and** `hard_negative_sym(B, A,
  W)` — same weight, both directions.
- Same symmetric-closure check for `sibling_sym/3` and `exclusion_sym/3`.
- `related/2` transitive closure spans multiple `type_of`/`sibling` hops
  correctly (multi-level chain, same shape as the RBAC
  ancestor-inheritance test).
- `excluded/2` fires for a pair connected by `hard_negative`, by
  `easy_negative`, and by `exclusion` alike (confirms the "folds into one
  gate" design decision from §5), regardless of the weight value stored
  on the underlying fact — with every relation defaulting to `weight:
  1.0`, this must produce identical `excluded/2` results to the
  pre-weight design (regression guard: adding the column must not
  silently change gating behavior).
- An `exclusion` fact with a low weight (e.g. `0.1`, simulating a future
  Nx-computed value) still fires `excluded/2` — confirms `exclusion`
  ignores weight as designed in §2, rather than accidentally being
  thresholded by a later change to the gating rule.
- `eligible/2` = `candidate/2` minus `excluded/2`: given one candidate
  pair with a hard negative and one without, only the clean pair is
  eligible.
- `ExDatalog.validate/1` succeeds on the full catalog (no unstratifiable
  negation) — a regression guard, since this is exactly the failure mode
  stratification exists to catch.
- `Data.Reasoning.Catalog.merge/2` combining `SkillTaxonomy` with `Rbac`
  does not raise — regression test guarding against accidental relation
  name collisions now that two real catalogs coexist in the app.

`test/data/reasoning/loaders/skill_taxonomy_test.exs`:

- Given stubbed `Role`/`Skill`/`RoleRelation` documents (via a
  `TerminusDB.Config` `adapter:` stub), `facts/0` returns the correct
  fact tuple for each relation, dispatched by `relation_type`.
- A `RoleRelation` document with an unrecognized `relation_type` raises
  clearly at load time (bad data reaching this point means the
  TerminusDB schema and the loader have drifted out of sync — a bug to
  surface loudly, not swallow).

`test/data/reasoning/store_test.exs` (extend existing file):

- Materializing `SkillTaxonomy` under its own name doesn't disturb an
  already-materialized `Rbac` group (same independence guarantee already
  proven, re-verified with two *real* catalogs instead of a catalog +
  an inline test double).

## Phase 5 — Measurement (not automated)

No new tests — this phase is manual: run the Phase 4 pipeline against a
real 5–10 role dataset entered through Phase 3, and inspect
`eligible/2` results by hand against what a human would expect. The
outcome of this phase (proceed to Phase 6 or not) is a judgment call, not
a test result.

## Phase 6 — Nx contrastive projection (conditional)

Not planned in detail until Phase 5 concludes it's warranted. When it is,
this section gets filled in before any Nx code is written, per the same
test-first rule as every other phase.

## Phase 7 — Choreo visualization

`test/data/skill_taxonomy/graph_test.exs` (the canonical builder, tested
independent of any specific lens):

- `Data.SkillTaxonomy.Graph.build/1` on a known `Knowledge`/document set
  produces the expected node list (correct `kind` per node) and edge
  list (correct `type`/`weight` per edge) — no relation type dropped,
  no duplicate nodes for a role that appears in multiple relations.
- Building from an empty dataset returns `%{nodes: [], edges: []}`, not
  an error.

`test/data/skill_taxonomy/views/` (one file per lens actually built —
only write these once a given lens from §7's candidate list is decided
worth building):

- **`Confusability`**: given a graph with all six relation types, the
  filtered output contains only `hard_negative`/`exclusion` edges and
  only the nodes those edges touch — no orphaned `supporting`/`type_of`
  nodes leak through.
- **`MindMap`**: given a graph with a `type_of`/`sibling` chain plus
  unrelated `hard_negative` edges, the transform's output has one root,
  every `type_of` as `:branch`, every `sibling` as `:associates`, and
  confirms the lossy drop — `hard_negative`/`supporting` edges are
  absent from the result, not mapped to some approximation.
- Each lens transform is tested purely on the canonical shape (no
  `Knowledge`/TerminusDB involved) — proving the assembly/render seam
  actually holds, i.e. a lens test never needs to know where the graph
  came from.

`test/data/skill_taxonomy/graph_view_test.exs` (rendering, once a lens
is wired to an actual Choreo call):

- Given a small canonical graph, the generated diagram has matching node
  and edge counts (a structural smoke test, not a rendering/pixel test).
- Each relation type maps to a distinct, stable edge style (assert on
  the metadata passed to the renderer, not the rendered DOT/Mermaid text
  itself, to avoid brittle string-matching tests).
- A `Viewable` zoom level filter (e.g. "roles only") returns exactly the
  role nodes and none of the skill/relation nodes.
