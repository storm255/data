# Skills Taxonomy — Design

Consolidated design for capturing, storing, reasoning over, and visualizing
the industry skill/role relationship data described by
`SKILL_SAMPLE_GUIDE.pdf`, using the TerminusDB connection and ExDatalog
reasoning scaffold already in this app.

Cross-reference: [`guides/terminusdb.md`](../guides/terminusdb.md),
`lib/data/reasoning/` (catalog/store/loader scaffold, validated against
RBAC), `../heeero_core/ARCHITECTURE.md` § Skills Matching Pipeline (the
existing embedding-based system this explores an addition to, not a
replacement for).

**Status:** design only. No implementation yet — see
[`SKILLS_TAXONOMY_TEST_PLAN.md`](SKILLS_TAXONOMY_TEST_PLAN.md) for the
tests to write before any of this is built, and
[`seed_roles.csv`](seed_roles.csv) for a draft 23-role launch dataset (in
the §4 CSV column shape) covering the hospitality launch role list —
**every row is `confidence: guess`**, generated without a domain expert
reviewing it, and needs human review before it's treated as real curated
data. See the file's companion notes below for known gaps.

### Seed dataset gaps to resolve before treating `seed_roles.csv` as real

- **"Housekeeper"** appeared twice in the source role list (Semi-Skilled
  and Casual tiers) — collapsed to one role here since the taxonomy has
  no seniority/tier field. Confirm whether two distinct roles were
  intended (e.g. Housekeeping Supervisor vs. Housekeeping Attendant).
- **"Dessert"** interpreted as Pastry Chef.
- **`locale: th`** not populated anywhere — needs a local-language
  reviewer, per the guide's own tagging guidance.
- **`exclusions`** populated for two illustrative pairs only —
  `Bartender`↔`Bar Back` (rationale: RSA/alcohol-service certification
  gap) and `Cleaner`↔`Room Attendant` (rationale: guest-room-access
  background-check gap) — specifically so the exclusion pathway has
  something real to materialize and test against (§5's
  `excluded`/`eligible` gate, and the `exclusion_sym` closure). Both are
  **invented examples demonstrating the mechanism, not verified
  compliance policy** — the `Bartender`/`Bar Back` pair is also useful
  as a worked example of a role that's `sibling`-related *and*
  `hard_negative`-gated *and* `exclusion`-gated simultaneously, each for
  a different reason (conceptual closeness, matching-quality, and
  compliance respectively). Replace with real policy input, or confirm
  and keep, before this data is treated as real.
- Several `type_of` targets (`Chef`, `F&B Supervisor`) aren't primary
  roles in this list themselves — fine structurally, but worth adding as
  their own rows later if hierarchy depth matters for matching.
- **Out of date against §4's column shape** — written before `description`
  and `context` existed, so it has neither. Regenerate (or hand-add both
  columns) before using it as import test data; a natural place to
  exercise `context` would be splitting `Waiter` into a blank-context
  base row and a `context: fine_dining` variant with its own additive
  supporting-skill list, per §2.

---

## 1. Problem and goals

Workers are matched to jobs on a *primary skill* (the role applied for)
surrounded by *supporting skills* that strengthen the match. Raw semantic
similarity (embeddings, cosine distance) reliably finds roles that are
lexically or contextually close, but cannot be told "these two look alike
but are different jobs" — that requires curated, explicit negative
knowledge. `SKILL_SAMPLE_GUIDE.pdf` defines exactly that curation format:
for each primary role, contributors supply synonyms, supporting skills,
type-of/sibling roles, **hard negatives** (the valuable part — confusable
but wrong), easy negatives, and exclusions, each tagged with locale,
industry, and confidence.

Goals, in order:

1. Store this curated data durably and versioned (TerminusDB).
2. Reason over it symbolically with an explainable result — *why* was a
   pair included or excluded (ExDatalog, building on the scaffold already
   validated with the RBAC catalog).
3. Optionally sharpen embedding-space separation using the curated
   positive/negative pairs (Nx) — deferred until (1)–(2) show where the
   symbolic layer alone falls short.
4. Visualize the resulting graph, with different filtered views (Choreo).

**Non-goal:** this does not modify `heeero_core`'s live `Skills` GenServer
or its Postgres-backed catalog. This app is standalone for now.
`heeero_core` is a plausible *later* target, gated on whether this
approach actually performs well enough to matter — and if it is pursued,
the expected shape is this app exposing itself as an **API service**
`heeero_core` calls into, not a code port/merge into that codebase. Kept
deliberately undecided until there's a performance result to decide from
(see §10, and the `candidate/2` note in §5).

---

## 2. Data model

Reading the guide precisely: **synonyms are alternate names for the same
role**, not links to other role entities ("You are not writing a
dictionary"). Everything else in the guide *is* a relationship between two
distinct entities. That gives two node kinds and six relation kinds:

### Node kinds

- **Role** — a job title. `slug`, `primary_name`, `locale` (of
  `primary_name`), `industry`, `description` (free-text semantic summary
  of the role — human documentation today, candidate embedding input for
  the Nx layer later), `synonyms: [{term, locale}]` (an attribute list,
  not edges).
- **Skill** — a capability, cert, or ability; not itself a job.
  `slug`, `name`.

### Context-dependent variants (e.g. a 5-star-hotel Waiter vs. a diner Waiter)

Not a new relation kind — venue-tier/setting differences that change
which supporting skills matter are modeled as a **separate Role**,
`type_of` the general one (`Waiter (Fine Dining) type_of Waiter`), the
same mechanism already used for `Sous Chef type_of Chef`. The variant's
own `supporting` list is *additive* — only the skills specific to that
context (wine service, formal table etiquette) — not a duplicate of the
base role's list, since `type_of` is what carries the base skills
forward through `related/2` (§5). Two roles at the same tier are `type_of`
the same parent, not `hard_negative` of each other — they're the same
job with different expectations, not roles that get confused.

Deliberately **not** solved by adding a context/threshold field to every
relation: `heeero_core`'s existing job model already separates this
concern at the right layer — `:skill_strictness` and per-requirement
`enforcement: :hard | :soft` are job-level settings, not taxonomy-level
ones. A stricter or laxer posting for the *same* role uses the *same*
taxonomy data; only a genuinely different skill set (not just a
different threshold) earns a new Role variant here.

### Relation kinds (all Role↔Role except `supporting`)

| Relation | Shape | Meaning | Symmetric? |
|---|---|---|---|
| `supporting` | Role → Skill | skill strengthens the role | no |
| `type_of` | Role → Role | child is a kind of parent (`SousChef type_of Chef`) | no |
| `sibling` | Role → Role | close, non-hierarchical (`Barista sibling Bartender`) | yes — see §5 |
| `hard_negative` | Role → Role | looks similar, must not match | yes — see §5 |
| `easy_negative` | Role → Role | obviously unrelated; low value | yes — see §5 |
| `exclusion` | Role → Role | genuinely incompatible (compliance-style hard block) | yes — see §5 |

Every relation instance carries `confidence: :sure | :guess` plus optional
`locale`, `industry`, and `notes`, exactly as the guide's "tag every entry"
section requires.

### Weight

Every relation also carries `weight: float (0.0–1.0), default 1.0`. This is
**not** a contributor-facing field — the guide is explicit that
contributors shouldn't grade relationships ("don't worry about
numbers/scores — just the words and the relationships"), and humans are
unreliable at hand-picking a meaningful decimal anyway. It exists as a
placeholder the Nx layer (§7) fills in later with real similarity/distance
values, once it exists; until then every relationship defaults to `1.0` —
full, undifferentiated weight — which is exactly the current unweighted
boolean behavior, so adding the field changes nothing until something
actually writes a value other than `1.0` to it. `exclusion` ignores this
field at the consumer level regardless of what's stored — it's a
compliance hard-block, not a gradient.

### Two categorically different kinds of "no"

`hard_negative`/`easy_negative` are a **matching-quality** signal (don't
let the matcher confuse these two lexically-similar roles).  `exclusion`
is a **business/compliance rule** (these two must never co-match,
regardless of skill similarity — e.g. a role requiring a clean criminal
record excluded from one that can't have it). They're stored and reasoned
over separately (§4) so exclusions can be audited independently, echoing
`heeero_core`'s existing `:compliance_checks` feature concept.

---

## 3. Storage — TerminusDB schema

Three top-level document classes, plus `Synonym` as an embedded
subdocument of `Role` (four `Class` entries total) — implemented in
`Data.TerminusDB.Schema.classes/0` (`lib/data/terminus_db/schema.ex`) and
synced via `mix terminus.setup`. Verified live against
`mark-i5.mediazu.org`.

```
Role
  @id (Lexical: primary_name + context), primary_name, context, locale, industry, description
  synonyms: {"@type" => "Set", "@class" => "Synonym"}   # embedded subdocuments: {term, locale}

Skill
  @id, name

RoleRelation
  from            # Role or Skill @id
  to              # Role or Skill @id
  relation_type   # "supporting" | "type_of" | "sibling" | "hard_negative" | "easy_negative" | "exclusion"
  confidence      # "sure" | "guess"
  weight          # float, 0.0-1.0, default 1.0 — system-computed (Nx, §7), never contributor-set
  locale          # optional
  industry        # optional
  notes           # optional
```

Modeling every relation as its own `RoleRelation` document (rather than
one document class per relation type) keeps this to three classes and
gives every individual relationship its own commit history in TerminusDB
— useful for auditing "who added this hard negative, and when," which is
exactly the kind of provenance TerminusDB is good at and ExDatalog's
`explain: true` is good at from the reasoning side (§4).

---

## 4. Data entry — LiveView + CSV/spreadsheet import

Two entry paths, sharing one document-building function so validation
rules live in one place — actually `Data.SkillTaxonomy.RowBuilder`, not
either entry-path module itself. `RowBuilder.build/2` is pure and
operates on already-structured fields (real lists, not `;`-delimited
strings), so it doesn't know or care which entry path called it; each
caller only handles what's specific to it (CSV cell-splitting and
cross-row checks for `CsvImporter`; live TerminusDB lookups for
`RoleLive`).

- **CSV/spreadsheet import** — one row per primary role (matching the
  guide's "work one primary role at a time"), columns mirroring the
  guide's blank template plus two additions: `primary, description,
  context, synonyms, supporting, type_of, sibling, hard_negatives,
  easy_negatives, exclusions, locale, industry, confidence`, with
  list-columns delimited (`;`). `Data.SkillTaxonomy.CsvImporter.parse/1`
  splits cells and handles cross-row checks (duplicate role identity,
  whether a `context` row's base role exists elsewhere in the file),
  then calls `RowBuilder.build/2` per row to get `Role`/`Skill` document
  maps plus relations pending resolution against real TerminusDB ids;
  `import/2` performs the actual insert — see §5's note on why
  `RoleRelation.from`/`to` can't be built without a network round trip.

  - `description` — free-text semantic summary of the role (§2).
  - `context` — optional venue-tier/setting qualifier (e.g.
    `fine_dining`, `casual_dining`, `banquet`; blank = the general/base
    row for that `primary` name). When set, the importer derives the
    role's identity from `primary` + `context` (so `Waiter` +
    `fine_dining` becomes its own `Role`, distinct from the blank-context
    `Waiter` row) and auto-adds a `type_of` link back to the
    blank-context row of the same `primary` name — contributors don't
    manually list that link in the `type_of` column too. A `context`
    row with no matching blank-context row for the same `primary` is an
    import error (the base role must exist before a variant of it can).

- **LiveView form** (`DataWeb.SkillTaxonomy.RoleLive`) — one block per
  guide section (Primary, Description, Context, Synonyms, Supporting,
  Type-of/Sibling, Hard Negatives, Easy Negatives, Exclusions), each a
  dynamic add/remove list where relevant, plus locale/industry/confidence
  fields per entry. On save, calls `RowBuilder.build/2` (checking
  `base_role_exists?` via a live `Document.query` when `context` is set)
  then `CsvImporter.import/2` directly — no separate "LiveView import"
  function; a single role is just a `parsed()` result with one `Role` in
  it. Editing an existing role uses `Data.SkillTaxonomy.RoleLoader.fetch/2`,
  `RowBuilder`'s inverse, to pre-fill the form from what's already stored.

Both paths write through `TerminusDB.Document.insert`/`replace` using
`Data.TerminusDB.config/1`, matching the pattern already established for
this project's TerminusDB integration.

### Cross-batch reference resolution + review (scoped, not built)

`import/2` (§4/§5) currently only resolves a relation's `from`/`to`
against documents inserted in the *same* call — a relation naming a
role that isn't a row in the current file, and wasn't imported earlier
either, fails outright (`{:unresolved_reference, key}`). `seed_roles.csv`
never hits this (every relation target is also a row in the same file),
but any future incremental import will. Two distinct risks, needing
different handling:

- **Exact match** — safe to auto-resolve. `Role` is Lexical-keyed on
  `{primary_name, context}`, `Skill` on `name`, so an exact lookup
  against already-imported documents has at most one result. No
  ambiguity possible.
- **Near-miss** — the real danger. A typo (`"Bar-Back"` vs `"Bar
  Back"`) won't exact-match, and auto-creating whatever doesn't resolve
  would silently produce a near-duplicate document instead of linking
  to the one that already exists.

Planned shape: on a failed exact match, search existing `Role`/`Skill`
documents for near-matches (e.g. `String.jaro_distance/2` — built into
Elixir, no new dependency) and return them as **candidates needing
review** rather than writing anything for that relation. The rest of a
batch that *did* resolve (exactly or via the current-batch lookup)
still imports normally — an ambiguous reference blocks only itself, not
the whole file.

This is where it surfaces to a human: the LiveView CSV import flow
(§4's LiveView form section) gets an import-review step between parse
and commit — upload → parse → **show unresolved references with their
candidate matches for review** → human picks the right one, creates a
new document, or corrects the CSV → commit. `import/2`'s contract grows
a third outcome alongside success/hard-failure to carry this: a list of
unresolved references, each with its candidates, written nowhere yet.

Not built — this section exists so the shape is agreed before the
LiveView work (§4, Phase 3) needs it, per `SKILLS_TAXONOMY_TEST_PLAN.md`
Phase 2's note on the same gap.

---

## 5. Reasoning — `Data.Reasoning.Catalogs.SkillTaxonomy`

A new catalog on the existing scaffold (`Data.Reasoning.Catalog`,
`Data.Reasoning.Store`, `Data.Reasoning.Loader` — see
`lib/data/reasoning/`, validated end-to-end with
`Data.Reasoning.Catalogs.Rbac`).

**Weight bumps every base relation to arity 3** (`{from, to, weight}`)
rather than 2. `confidence`, `locale`, `industry`, and `notes` stay
document-only metadata in TerminusDB — they inform *whether* a fact gets
loaded at all (e.g. a loader policy could skip `:guess`-confidence
relations), not reasoning over the fact itself — but `weight` is
reasoning-relevant (thresholding, ranking), so it's the one field that
needs to be a first-class column in the Datalog tuple.

**Symmetric closure.** The guide authors relationships from one role's
perspective ("what gets wrongly suggested for *this* role"), but matching
must gate in both directions. ExDatalog has no built-in symmetry
declaration, so each symmetric relation gets an explicit closure rule,
carrying weight through unchanged:

```
hard_negative_sym(X, Y, W) :- hard_negative(X, Y, W).
hard_negative_sym(X, Y, W) :- hard_negative(Y, X, W).
```

Same pattern for `sibling` and `exclusion`. `type_of` and `supporting`
stay directional (no closure rule).

**Relations:**

- Base (loaded facts): `supporting/3`, `type_of/3`, `sibling/3`,
  `hard_negative/3`, `easy_negative/3`, `exclusion/3` — each
  `{from, to, weight}`.
- Derived, positive: `hard_negative_sym/3`, `sibling_sym/3`,
  `exclusion_sym/3`; `related/2` — transitive closure over `type_of` +
  `sibling_sym`, the basis for a future "domain depth" ranking signal
  (structurally identical to the `ancestor`/`reachable` pattern already
  proven with RBAC). `related/2` stays arity 2 for now — combining
  per-hop weights into a path weight (e.g. via `{:mul, ...}` constraints
  chained across recursive steps) is deferred to whenever §7 actually
  produces non-1.0 weights to combine; no point designing that
  aggregation before there's real data to shape it against.
- Derived, negated: `excluded/2` — true if a candidate pair is caught by
  `hard_negative_sym`, `easy_negative_sym`, or `exclusion_sym`, regardless
  of weight (while every weight defaults to `1.0`, this is equivalent to
  today's boolean gate; once §7 produces real weights, this is the place
  a `{:gte, :W, threshold}` constraint would go — deferred, not designed
  yet). `exclusion_sym` gates `excluded` unconditionally, ignoring
  whatever weight is stored, per §2. `eligible/2` — `candidate/2` (an
  external fact source — see below) minus `excluded/2`, via stratified
  negation. `candidate → excluded → eligible` is a DAG with no cycle
  through the negative edge, so this is trivially stratifiable — no
  different in kind from the RBAC catalog's rules.

Note on scope: `hard_negative` and `easy_negative` feed the same
`excluded` derivation (a deliberate simplification — the guide's
"easy vs hard" distinction is about how much curation effort went into
finding the negative, not a difference in how it should gate matching).
`exclusion` stays a separately queryable relation even though it also
feeds `excluded`, so compliance exclusions remain independently
auditable.

**`candidate/2`** is not defined by this catalog — it's supplied
externally. Two different shapes this could take, not yet decided
between:

- **Batch/materialized** — something (this project's Nx layer, §7, if
  built) produces a `candidate/2` fact set up front, and `eligible/2` is
  materialized over the whole set at once. This is what's stubbed for
  Phase 4 testing today.
- **Point query, if this app ends up serving `heeero_core` over an API**
  (§1) — the caller already knows the specific pair it wants checked (it
  generated the candidate via its own embedding bucket); this app
  wouldn't need a batch `candidate/2` relation at all, just an endpoint
  that checks one `{role_a, role_b}` pair against `excluded/2` and
  returns the answer plus, if `explain: true` was used, *why*. This is
  architecturally simpler and sidesteps candidate generation entirely —
  this app never needs to know how the caller decided the pair was worth
  checking.

Which shape is right depends on whether `heeero_core` integration (§1)
and/or the Nx layer (§7) actually happen — left open until one of those
is decided. This catalog's job, either way, is the gate, not candidate
generation.

**Loader:** `Data.Reasoning.Loaders.SkillTaxonomy` implements
`Data.Reasoning.Loader`, reading `Role`/`Skill`/`RoleRelation` documents
via `TerminusDB.Document.stream/2` and dispatching each `RoleRelation` to
its fact relation by `relation_type`.

**Magic sets note:** `related/2` (positive, recursive) is a legitimate
future magic-sets candidate if the catalog grows large — a goal like
`{"related", [specific_skill, :_]}` would avoid materializing the full
closure. `excluded`/`eligible` cannot use magic sets (ExDatalog's
magic-sets transform excludes programs with negation) — this only matters
at a scale this catalog isn't expected to reach; full semi-naive
materialization is the default and is expected to remain sufficient (see
`heeero_core`'s own note that its embedding catalog, at the same
hospitality scale, is "completely appropriate" in plain memory).

---

## 6. Contributor guidance prose: capture, interpretation, and review

Contributors write two kinds of prose per category per role — "Expanded
Detail" and "Heeero matching logic" (per the Heeero Role Differentiation
Template, §4) — that aren't structured relationship data, but *are*
valuable: they're a domain expert explaining, in plain language, how a
category should actually govern matching for this role (e.g. *"Match
only when guest-room cleaning and hotel room turnover are present"*).
This section covers how that prose is captured, how an LLM's attempt to
structure it is stored alongside the original without replacing it, and
how the result gets surfaced for review before it's trusted.

### Storage: original and interpreted, always both, never merged

A new document class, one per `(role, category)` pair — not folded into
`Role` itself, since it needs its own review lifecycle and audit trail
independent of the role's core data:

```
RoleGuidance
  role                 # Role @id this belongs to
  category             # one of the 8 categories (primary_role, synonyms,
                        # supporting, type_of_sibling, hard_negative,
                        # easy_negative, exclusion, manual_review)
  source_text          # verbatim contributor prose - immutable once written
  interpretation        # optional - the LLM's structured proposal (string; see below)
  interpreted_at         # optional
  interpreter_version     # optional - which prompt/model produced it
  review_status          # "not_interpreted" | "pending_review" | "approved" | "rejected" | "edited"
  reviewed_by / reviewed_at   # optional
```

`source_text` and `interpretation` are separate fields that both
persist — `source_text` is never overwritten by the interpretation
step. Editing `source_text` later resets `review_status` to
`pending_review` and should trigger re-interpretation; an approval is
only valid for the exact text it was approved against.

### What shape the interpretation itself should take

Not free natural-language restatement (safe but doesn't help build
anything), and not a fully-formed `ExDatalog` rule struct directly (a
malformed struct is a worse failure mode than a malformed string).
Middle ground: the LLM produces something close to
`ExDatalog.Program.add_rule/3`'s shorthand notation, as a **string**,
which is then run through `ExDatalog.validate/1` before it's ever shown
to a reviewer — reusing the stratification/safety-checking machinery
already proven with the RBAC catalog (§5) as a first-pass filter, so a
structurally invalid interpretation never reaches the review queue at
all. The prompt itself should constrain the interpretation to only
reference terms already present in that role's own term-level data
(its actual supporting skills, hard negatives, etc.) — bounds
hallucination risk, and keeps the LLM's job "structure what's already
been said" rather than "invent new claims."

### Two different LLM roles — kept conceptually separate

This is the **authoring-time** counterpart to the query-time idea in
§11: authoring-time interpretation happens once per `(role, category)`,
gets human-reviewed, and the result becomes part of the trusted,
deterministic rule base. Query-time translation (a live natural-language
question → a Datalog goal → an answer) happens per-query with no
per-query review — that's only safe *because* it's just
selecting/parameterizing against a rule base that authoring-time review
already vetted, not inventing new reasoning logic live. Skipping
authoring-time review would mean trusting the LLM's reasoning on every
query instead of once, up front.

### Review surface: same shape as two other things already in this doc

Three things already in this design turn out to be the same underlying
pattern — "something produced a candidate; nothing acts on it until a
human confirms, edits, or rejects it":

1. Cross-batch CSV reference resolution (§4) — an item + fuzzy candidate
   matches, needing confirmation.
2. This section — an item + one structured interpretation, needing
   confirmation.
3. The Heeero template's own "Manual Review / Low-Confidence Matches"
   category (row D, §4) — an item a contributor explicitly flagged as
   needing human judgment before it's trusted.

Worth building as one shared reviewable-item concept (`kind`, `subject`,
`proposal`, `status`) feeding one review surface, rather than three
bespoke UIs — flagged here as a real generalization opportunity now that
there are three independent motivating cases, not decided or scheduled.

**Highlighting, concretely:** `source_text` always renders as plain,
trusted prose. `interpretation` renders visually distinct — bordered or
tinted, explicitly labeled ("AI-suggested — not yet confirmed"), never
styled to look like confirmed data, with approve/edit/reject actions
attached. Even after approval, a permanent marker that a rule
originated from an LLM interpretation should stay visible — this
project's whole approach to TerminusDB is traceable provenance (commit
history, `explain: true`), and silently laundering an AI suggestion
into indistinguishable "real" data would work against that.

Not built — this section exists to agree the shape before any of it is
implemented.

---

## 7. Semantic layer (Nx) — deferred, staged

Not built until §4–5 exist and produce real data to evaluate against.

- **Phase A — baseline, no Nx.** `candidate/2` stubbed or hand-seeded;
  correctness of the `excluded`/`eligible` gate is what's under test.
- **Phase B — measurement.** With real curated data, check whether the
  symbolic gate alone is sufficient, or false positives/negatives remain
  that only a similarity signal could catch.
- **Phase C — only if Phase B shows a gap.** A lightweight contrastive
  projection head (`Axon`/`Nx.Defn`, triplet or contrastive loss) trained
  on top of frozen embeddings, using `synonym`/`type_of` pairs as pulls
  and `hard_negative` pairs as pushes. Explicitly not a full embedding
  model fine-tune — the guide's own target size ("20 well-negated roles")
  is too small a labeled set for that without overfitting.
  `exclusion` never participates in embedding training — it's a business
  rule, not a similarity signal, and stays in the Datalog gate regardless
  of what Phase C produces.

---

## 8. Visualization — Choreo

Sequenced last, once real data and reasoning output exist to visualize.
The goal isn't one fixed diagram — it's being able to look at the same
underlying graph through several lenses (a hierarchy view, a
"confusability" view of just the negatives, the full multi-relation
picture) without re-deriving data for each one. That means the design
needs a seam between *assembling* the graph and *rendering* it a
particular way.

### Canonical graph representation

One function, `Data.SkillTaxonomy.Graph.build/1`, assembles the full
graph once from `Knowledge` (post-materialization) or directly from
TerminusDB documents, into a plain, vocabulary-agnostic shape:

```elixir
%{
  nodes: [%{id: ..., kind: :role | :skill, label: ..., meta: %{...}}],
  edges: [%{from: ..., to: ..., type: :synonym | :supporting | :type_of |
             :sibling | :hard_negative | :easy_negative | :exclusion,
             weight: float(), meta: %{...}}]
}
```

Every visualization lens is then a **pure transform from this shape**,
not a new data-fetch. Adding a lens later costs one new transform
function, not a change to how data is assembled — this is the concrete
answer to "make sure we can transform the data into the required shapes
later."

### Candidate lenses (not built yet — naming the shape of the future work)

- **`Views.Confusability`** — filter to just `hard_negative`/`exclusion`
  edges. No Choreo vocabulary needed for this one; it's a filtered
  render of the canonical graph directly. Probably the most immediately
  useful lens given the guide's own emphasis ("hard negatives... the
  important bit") — good for reviewing/auditing curated negative data.
- **`Views.MindMap`** (`Choreo.MindMap`) — pick or synthesize a root,
  map `type_of` → `:branch`, `sibling` → `:associates`. Necessarily
  lossy: `MindMap` enforces a single root and only two edge types, so
  `supporting`/`hard_negative`/`exclusion` don't appear in this lens at
  all. Good for a "concept hierarchy" view, not a complete one.
- **`Views.Dependency`** (`Choreo.Dependency`) — map `supporting` onto
  `depends_on(type: :uses)` (a role "depends on" its supporting skills,
  loosely). Whether this earns its complexity over the full/generic
  view is an open question, not a commitment — flagged here so the
  option exists, not because it's decided to be worth building.
- **`Views.Full`** — the lossless, everything-at-once render. Built
  either via `Yog` directly (see note below) or a generic Choreo
  diagram, since no fixed vocabulary can represent six independently
  typed relations without dropping some.

Each lens module implements the same shape: take the canonical graph
(plus any lens-specific options, e.g. a root for `MindMap`), return
whatever the target renderer needs. None of this is built until this
phase starts — the point of doing this now is only to make sure the
canonical-graph seam exists before any lens is written, so the first
lens doesn't have to be refactored to make room for the second.

### Other notes

- `Choreo.Viewable` (zoom/focus/filter/collapse) is an orthogonal axis
  to the above — it's *within* one chosen vocabulary (e.g. `MindMap`
  zoom level 0 = root only, level 1 = root + topics), not a choice
  *between* vocabularies. Both axes are useful together: pick a lens,
  then zoom within it.
- Choreo's `Analysis` toolkit (centrality, shortest-path with custom
  semirings, isolated nodes) overlaps with `related/2` above — worth
  using instead of duplicating that logic in Datalog once this phase
  starts.
- No interactive graph editing here (Choreo renders to DOT/Mermaid, one
  direction only) — all data creation/editing is the LiveView/CSV path in
  §4.

---

## 9. Phased roadmap

1. **Done.** TerminusDB schema (`Role`, `Skill`, `RoleRelation`, plus the
   `Synonym` subdocument) in `Data.TerminusDB.Schema.classes/0`; synced
   and verified live via `mix terminus.setup`.
2. **Done.** `Data.SkillTaxonomy.CsvImporter` (`parse/1` + `import/2`),
   built on the shared `Data.SkillTaxonomy.RowBuilder`.
3. **Done.** `DataWeb.SkillTaxonomy.RoleLive` entry form, on the same
   `RowBuilder` plus `Data.SkillTaxonomy.RoleLoader` for the edit path.
4. `Data.Reasoning.Catalogs.SkillTaxonomy` + `Loaders.SkillTaxonomy`,
   validated against a small real dataset (5–10 hand-entered roles).
5. Measure symbolic-only match quality against real data; decide whether
   §7 Phase C is warranted.
6. (Conditional) Nx contrastive projection.
7. Choreo visualization.

---

## 10. Open decisions

- **`Yog` standalone usability** — resolved: `yog` is an independent hex
  package, but it's a **Gleam** library, not Elixir. Callable from
  Elixir (Gleam compiles to BEAM bytecode; `Result`/custom types are
  usable Erlang terms), but not idiomatic-Elixir-smooth — lowercase
  module access, Gleam-shaped records, no `@doc`/`@spec`. Default to
  Choreo's Elixir-native vocabulary wrappers (§8); reach for `Yog`
  directly only if a needed capability isn't exposed by any of them.
- **Which visualization lenses are actually worth building** — §8 names
  candidates (`Confusability`, `MindMap`, `Dependency`, `Full`) but only
  commits to the seam (canonical graph → pluggable transforms), not to
  building all of them. Decide per-lens when §8 starts, based on what's
  actually useful once real data exists.
- **`candidate/2` source and shape** — stubbed through §5; batch
  (Nx-produced) vs. point-query (served to `heeero_core` over an API)
  decided once §1's integration question resolves.
- **`heeero_core` integration** — standalone for now. If pursued later,
  expected shape is an API service this app exposes, gated on
  performance being good enough to justify it — not a code port/merge.

---

## 11. Future exploration (not scheduled)

Ideas surfaced during design discussion, deliberately kept separate from
the committed roadmap (§9) — captured so they aren't lost, not because
any of this is decided or scheduled.

### LLM-assisted candidate generation + mobile swipe triage

When describing a new role (or improving an existing one), call an LLM
to generate a candidate word cloud for it — synonyms, supporting skills,
lookalike roles — instead of a contributor typing a structured cluster
from scratch. On mobile, present the candidates as a fast swipe-triage
UI rather than a form: swipe to keep/discard (building `synonym`/
`supporting`/`hard_negative` sets as inclusions vs. exclusions),
ordering by importance, possibly left/right mapped to positive/negative.

- Distinct from the Nx layer (§7): an LLM generates plausible
  *candidate terms* in natural language for a human to judge; Nx
  measures *numeric similarity* between terms already in the taxonomy.
  Different tools, different jobs — worth keeping conceptually separate
  rather than folding "AI helps write the data" into "AI helps score
  the data."
- Natural fit for `confidence` (§2), which today has no real signal
  behind it: an LLM-suggested-then-swiped-yes term could reasonably
  default to `guess` (machine-suggested, human-confirmed quickly, not
  deeply vetted), while a manually-typed entry carries whatever the
  contributor states — giving that field an actual basis instead of
  always defaulting flat.
- Accelerates the LiveView/CSV entry path from §4 — doesn't change the
  data model. Same `Role`/`RoleRelation` documents result either way.

### Concentric-circle drag UI (web/admin)

Primary skill fixed at the center; candidate related terms placed as
draggable nodes; distance from center expresses relevance/match
strength, set by a physical drag gesture rather than typing a number.

- Directly relevant to the `weight` field decision (§2/§3): weight was
  deliberately kept out of human hands because people are unreliable at
  *typing* a meaningful decimal. A drag gesture sidesteps that
  objection entirely — it's a spatial/analog action, not a numeric
  estimate — so this may be the one interface where a human-set weight
  is actually trustworthy. Worth revisiting the Nx-only-writes-weight
  decision if this gets built.
- Also a plausible *training signal* for the Nx projection (§7): rather
  than Nx supplying weight unilaterally, human-placed positions could
  serve as additional labeled input — alongside `synonym`/
  `hard_negative` pairs — for the contrastive loss to learn to
  reproduce.
- An additional entry mode alongside §4's LiveView form and CSV import,
  not a replacement for either.

### Explorer + Parquet for larger-scale data handling

[`Explorer`](https://explorer.hexdocs.pm/Explorer.html) (Elixir dataframes,
Rust/Polars-backed) and Parquet as a columnar storage/interchange format,
as an alternative to hand-rolled CSV parsing and row-by-row `Enum`/`Map`
logic once the dataset outgrows what that comfortably handles.

- Most relevant to the Nx layer (§7): Explorer and Nx are designed to
  interoperate (dataframe ↔ tensor conversion), so a training pipeline
  loading/preprocessing embedding vectors or curated pairs at scale
  would likely want Explorer in front of Nx rather than plain Elixir
  data structures.
- Parquet as an export/interchange format is a plausible complement to,
  not a replacement for, `seed_roles.csv` — CSV stays the
  contributor-editable entry format (spreadsheet-friendly, per §4);
  Parquet would be for moving larger materialized datasets between this
  app and any other tooling (compressed, columnar, faster to scan).
- Not relevant to Phase 2 as currently scoped — the launch dataset is a
  few dozen rows, well within what `NimbleCSV` + plain Elixir handles
  without added complexity. Revisit if/when dataset size or Nx data
  pipeline needs actually justify it.

### LLM-mediated natural-language querying, with Datalog as the truth in the middle

Use an LLM only at the two translation boundaries of a query, never for
the reasoning itself: natural language question → **LLM translates to a
formal Datalog query** (a goal against `Data.Reasoning.Store`, e.g.
`{"eligible", [worker_role, job_role]}`) → **ExDatalog evaluates it —
deterministic, repeatable, the same input always gives the same
answer** → the structured result (optionally with `explain: true`
provenance, §5) → **LLM rephrases that structured result as natural
language** for the person asking.

- The point is what stays *out* of the LLM's hands: the actual
  inference. Asking an LLM "does this candidate match this job" directly
  is exactly the unreliable, non-reproducible thing the whole symbolic
  layer (§5) exists to avoid. Here the LLM only ever translates at the
  edges — question in, answer out — never computes the answer itself.
  The "truth" — eligible/excluded and why — is always whatever ExDatalog
  actually derived, byte-for-byte reproducible from the same facts.
  Repeatability is the entire premise of the RBAC/SkillTaxonomy scaffold
  already built (§5); this idea preserves that instead of trading it
  away for conversational convenience.
- `req_llm` (added to `mix.exs` for the §11 word-cloud idea above)
  is the natural fit for both translation calls.
- Failure mode to design for, not yet decided: what happens when the
  LLM produces a malformed or nonsensical Datalog goal from an ambiguous
  question. Validation (`ExDatalog.validate/1`, already proven in the
  RBAC catalog) gives a structural safety net — a bad goal fails loudly
  rather than silently returning a wrong answer — but the UX for "I
  couldn't turn that into a query" isn't designed yet.
