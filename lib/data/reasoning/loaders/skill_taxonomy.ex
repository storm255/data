defmodule Data.Reasoning.Loaders.SkillTaxonomy do
  @moduledoc """
  Populates `Data.Reasoning.Catalogs.SkillTaxonomy`'s base relations from
  TerminusDB — every `RoleRelation` document, dispatched to its fact
  relation by `relation_type` (which already matches the catalog's
  relation names one-to-one: `"hard_negative"` -> `hard_negative/3`, and
  so on for every kind in design doc §2's relation-kinds table).

  Each `RoleRelation`'s `from`/`to` (already `Role`/`Skill` `@id`
  strings) and `weight` map straight onto the fact tuple; `weight` is
  scaled to an integer (`round(weight * 1000)`) since `ExDatalog` has no
  float term type at all — see
  `Data.Reasoning.Catalogs.SkillTaxonomy`'s moduledoc.

  `confidence` is read but not currently used to filter anything —
  design doc §5 notes a confidence-based loader policy (e.g. skip
  `:guess`-confidence relations) as a *possible* future refinement, not
  a decided one; every relation is loaded regardless of confidence today.

  `candidate/2` is deliberately **not** produced here — it's supplied
  externally, per design doc §5.
  """

  @behaviour Data.Reasoning.Loader

  alias TerminusDB.Document

  @doc """
  Implements `Data.Reasoning.Loader`'s zero-arg contract, using
  `Data.TerminusDB.config/0` for the connection. Prefer `facts/1` when
  you already have a `TerminusDB.Config` (e.g. in tests).
  """
  @impl true
  @spec facts() :: [{String.t(), [term()]}]
  def facts, do: facts(Data.TerminusDB.config())

  @doc "Same as `facts/0`, but against an explicit config."
  @spec facts(TerminusDB.Config.t()) :: [{String.t(), [term()]}]
  def facts(%TerminusDB.Config{} = config) do
    {:ok, relations} = Document.get(config, type: "RoleRelation", as_list: true)
    Enum.map(relations, &relation_fact/1)
  end

  defp relation_fact(%{
         "relation_type" => relation_type,
         "from" => from,
         "to" => to,
         "weight" => weight
       }) do
    {relation_type, [from, to, scale_weight(weight)]}
  end

  defp scale_weight(weight) when is_float(weight), do: round(weight * 1000)
  defp scale_weight(weight) when is_integer(weight), do: weight * 1000
end
