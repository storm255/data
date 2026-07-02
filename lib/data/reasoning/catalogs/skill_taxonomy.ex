defmodule Data.Reasoning.Catalogs.SkillTaxonomy do
  @moduledoc """
  Catalog for skill-taxonomy matching: symmetric closure over the guide's
  one-directional relations, transitive `related/2`, and the
  `candidate -> excluded -> eligible` gate (design doc §5).

  Relations use `:string` columns (never `:atom`) for role/skill
  identifiers — these come from unbounded contributor-entered data, not
  a fixed enum, so interning them as atoms would be an unbounded-atom
  leak. Identifiers are `Role`/`Skill` `@id` strings, matching what
  `RoleRelation.from`/`to` already store.

  `weight` is an `:integer` column, not `:float` — `ExDatalog.Term.const/1`
  rejects any float outright. `Data.Reasoning.Loaders.SkillTaxonomy` is
  responsible for scaling the real (`TerminusDB`/Elixir-side) float
  weight to an integer before it becomes a fact; this catalog only ever
  sees the already-scaled integer and never converts it back — nothing
  here currently does arithmetic on `weight` (see `related/2`'s
  moduledoc note below), it's carried through purely for future
  thresholding/ranking (§7).
  """

  alias Data.Reasoning.Catalog

  @directional_relations ~w(supporting type_of)
  @symmetric_relations ~w(hard_negative easy_negative sibling exclusion manual_review)

  @doc """
  Builds the skill-taxonomy catalog.

  ## Examples

      iex> catalog = Data.Reasoning.Catalogs.SkillTaxonomy.build()
      iex> catalog.name
      :skill_taxonomy

  """
  @spec build() :: Catalog.t()
  def build do
    Catalog.new(:skill_taxonomy, relations(), rules())
  end

  defp relations do
    base =
      for name <- @directional_relations ++ @symmetric_relations,
          do: {name, [:string, :string, :integer]}

    sym = for name <- @symmetric_relations, do: {"#{name}_sym", [:string, :string, :integer]}

    base ++
      sym ++
      [
        # candidate/2 is supplied externally (§5) — not populated by
        # Data.Reasoning.Loaders.SkillTaxonomy, just declared here so
        # eligible/2's rule body can reference it.
        {"candidate", [:string, :string]},
        {"related", [:string, :string]},
        {"excluded", [:string, :string]},
        {"eligible", [:string, :string]},
        {"flagged_for_review", [:string, :string]}
      ]
  end

  defp rules do
    symmetric_closure_rules() ++
      related_rules() ++
      [
        {{"excluded", [:X, :Y]}, [{:positive, {"hard_negative_sym", [:X, :Y, :_]}}]},
        {{"excluded", [:X, :Y]}, [{:positive, {"easy_negative_sym", [:X, :Y, :_]}}]},
        {{"excluded", [:X, :Y]}, [{:positive, {"exclusion_sym", [:X, :Y, :_]}}]},
        {
          {"eligible", [:X, :Y]},
          [{:positive, {"candidate", [:X, :Y]}}, {:negative, {"excluded", [:X, :Y]}}]
        },
        {{"flagged_for_review", [:X, :Y]}, [{:positive, {"manual_review_sym", [:X, :Y, :_]}}]}
      ]
  end

  # hard_negative_sym(X, Y, W) :- hard_negative(X, Y, W).
  # hard_negative_sym(X, Y, W) :- hard_negative(Y, X, W).
  # ...same pattern for easy_negative, sibling, exclusion, manual_review.
  defp symmetric_closure_rules do
    Enum.flat_map(@symmetric_relations, fn name ->
      sym = "#{name}_sym"

      [
        {{sym, [:X, :Y, :W]}, [{:positive, {name, [:X, :Y, :W]}}]},
        {{sym, [:X, :Y, :W]}, [{:positive, {name, [:Y, :X, :W]}}]}
      ]
    end)
  end

  # related(X, Y) — transitive closure over type_of + sibling_sym edges,
  # combined (a related-chain can mix hops of either kind). Weight is
  # dropped here (arity 2, per design doc §5) — combining per-hop
  # weights into a path weight is deferred until §7 produces real
  # weights to combine.
  #
  # The recursive steps need an explicit X != Y constraint: sibling_sym
  # already stores both directions of a single curated sibling fact, so
  # without it, a bare `related(X,Z), sibling_sym(Z,Y)` chain walks
  # straight back to X in one extra hop (X -> Z -> X) and derives a
  # meaningless related(X, X) self-loop from nothing but the closure's
  # own symmetry — not a real second relationship.
  defp related_rules do
    [
      {{"related", [:X, :Y]}, [{:positive, {"type_of", [:X, :Y, :_]}}]},
      {{"related", [:X, :Y]}, [{:positive, {"sibling_sym", [:X, :Y, :_]}}]},
      {
        {"related", [:X, :Y]},
        [{:positive, {"related", [:X, :Z]}}, {:positive, {"type_of", [:Z, :Y, :_]}}],
        [{:neq, :X, :Y}]
      },
      {
        {"related", [:X, :Y]},
        [{:positive, {"related", [:X, :Z]}}, {:positive, {"sibling_sym", [:Z, :Y, :_]}}],
        [{:neq, :X, :Y}]
      }
    ]
  end
end
