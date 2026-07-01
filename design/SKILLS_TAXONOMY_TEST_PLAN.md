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

`test/data/skill_taxonomy/csv_importer_test.exs`:

- A valid single-role row (all seven guide sections populated) parses
  into one `Role` document map and N `RoleRelation` document maps, one
  per listed relationship, with `relation_type` set correctly per column.
- A file with multiple primary-role rows parses into distinct, correctly
  separated `Role`/`RoleRelation` sets — no cross-contamination between
  rows.
- List-columns (`synonyms`, `supporting`, `type_of`, `sibling`,
  `hard_negatives`, `easy_negatives`, `exclusions`) split on `;`,
  trimmed, empty entries dropped.
- Missing `primary` column/value → import error for that row, not a
  crash of the whole file.
- Fewer than 2 synonyms, or 0 hard negatives → **warning**, not a
  rejection (the guide's minimums are contributor guidance, not a system
  invariant) — assert the parsed result carries a warnings list alongside
  the data.
- An unrecognized value in a relation-type column (e.g. a typo'd header)
  → explicit error naming the bad column, not a silently dropped
  relationship.
- `confidence` defaults to `:guess` when the column is blank; explicit
  `sure`/`guess` values pass through unchanged; anything else → error.
- `weight` is always `1.0` on import — there is no CSV column for it (per
  design doc §2, it's system-computed, never contributor-set); assert the
  importer doesn't even look for a `weight` column if one happens to be
  present in a malformed file, rather than accidentally trusting it.
- A row with blank `context` produces a `Role` identified by `primary`
  alone.
- A row with a non-blank `context` produces a `Role` identified by
  `primary` + `context`, distinct from the blank-context row for the
  same `primary`, plus an auto-generated `type_of` `RoleRelation`
  pointing at that blank-context row — assert this relation is present
  even though it's absent from the row's own `type_of` column.
- A `context` row whose `primary` has no corresponding blank-context row
  anywhere in the file → import error for that row (the base role must
  exist first).
- Two rows with the same `primary` and the same `context` (both blank,
  or both the same non-blank value) → import error (duplicate role
  identity), not a silent overwrite.
- `description` passes through as free text on the `Role` document,
  unvalidated beyond "present or blank" — this field is documentation,
  not something the importer should try to parse or constrain.
- Round-trip: parsed documents passed through
  `TerminusDB.Document.insert/3` with a stubbed `adapter:` (per the
  `terminusdb_client` doctest pattern) produce the expected request
  bodies — no network required for this test.

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
