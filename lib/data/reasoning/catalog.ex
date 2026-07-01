defmodule Data.Reasoning.Catalog do
  @moduledoc """
  Declarative schema for one reasoning concern: the relations and rules
  ExDatalog needs in order to reason about it. A catalog holds **no facts
  and does no I/O** — it's pure data, analogous to an Ecto schema.

  Concrete catalogs live under `Data.Reasoning.Catalogs.*` (e.g.
  `Data.Reasoning.Catalogs.Rbac`), kept separate from the runtime code
  that loads facts and materializes/queries them (`Data.Reasoning.Loader`,
  `Data.Reasoning.Store`). This module also provides `merge/2` for
  combining independent catalogs into one for cross-cutting analyses, and
  `build_program/2` for turning a catalog plus a set of facts into an
  `ExDatalog.Program` ready to materialize.
  """

  alias ExDatalog.Program

  @typedoc "A `{relation_name, column_types}` pair, as passed to `ExDatalog.Program.add_relation/3`."
  @type relation :: {String.t(), [Program.ir_type()]}

  @typedoc """
  A rule in `ExDatalog.Program.add_rule/3,4` shorthand form: a `{head, body}`
  pair, or a `{head, body, constraints}` triple when the rule needs
  constraints.
  """
  @type rule_spec ::
          {Program.head_shorthand(), [Program.body_literal_shorthand()]}
          | {Program.head_shorthand(), [Program.body_literal_shorthand()],
             [Program.constraint_shorthand()]}

  @type t :: %__MODULE__{
          name: atom(),
          relations: [relation()],
          rules: [rule_spec()]
        }

  @enforce_keys [:name]
  defstruct [:name, relations: [], rules: []]

  @doc """
  Builds a catalog from a name plus its relation and rule declarations.

  ## Examples

      iex> Data.Reasoning.Catalog.new(:example, [{"edge", [:atom, :atom]}], [])
      %Data.Reasoning.Catalog{
        name: :example,
        relations: [{"edge", [:atom, :atom]}],
        rules: []
      }

  """
  @spec new(atom(), [relation()], [rule_spec()]) :: t()
  def new(name, relations \\ [], rules \\ [])
      when is_atom(name) and is_list(relations) and is_list(rules) do
    %__MODULE__{name: name, relations: relations, rules: rules}
  end

  @doc """
  Merges independent catalogs into a single combined catalog named `name`,
  unioning their relations and rules.

  Use this when an analysis needs to reason across concerns that were
  defined and are otherwise materialized independently (e.g. RBAC plus an
  org hierarchy). Each input catalog, and any `Data.Reasoning.Store` entry
  built from it, is left untouched — merging only produces a new `t()` for
  building a separate, combined program.

  Raises `ArgumentError` if two catalogs declare the same relation name
  with different column types, since that is a genuine schema conflict
  rather than something safe to resolve automatically.

  ## Examples

      iex> a = Data.Reasoning.Catalog.new(:a, [{"edge", [:atom, :atom]}], [])
      iex> b = Data.Reasoning.Catalog.new(:b, [{"weight", [:atom, :integer]}], [])
      iex> merged = Data.Reasoning.Catalog.merge([a, b], :combined)
      iex> merged.name
      :combined
      iex> Enum.sort(merged.relations)
      [{"edge", [:atom, :atom]}, {"weight", [:atom, :integer]}]

  """
  @spec merge([t()], atom()) :: t()
  def merge(catalogs, name) when is_list(catalogs) and catalogs != [] and is_atom(name) do
    relations =
      catalogs
      |> Enum.reduce(%{}, &collect_relations/2)
      |> Map.to_list()

    rules = Enum.flat_map(catalogs, & &1.rules)

    %__MODULE__{name: name, relations: relations, rules: rules}
  end

  defp collect_relations(%__MODULE__{relations: relations}, acc) do
    Enum.reduce(relations, acc, fn {rel_name, types}, acc ->
      case Map.fetch(acc, rel_name) do
        {:ok, ^types} ->
          acc

        {:ok, other_types} ->
          raise ArgumentError,
                "conflicting schema for relation #{inspect(rel_name)}: " <>
                  "#{inspect(other_types)} vs #{inspect(types)}"

        :error ->
          Map.put(acc, rel_name, types)
      end
    end)
  end

  @doc """
  Builds an `ExDatalog.Program` from this catalog's relations and rules,
  populated with `facts` (a list of `{relation_name, values}` tuples).

  Returns `{:error, reason}` instead of a program if a relation or rule
  fails structural validation (see `ExDatalog.Program`) — this is passed
  straight through to `ExDatalog.materialize/2` if piped there.

  ## Examples

      iex> catalog = Data.Reasoning.Catalog.new(:example, [{"edge", [:atom, :atom]}], [])
      iex> program = Data.Reasoning.Catalog.build_program(catalog, [{"edge", [:a, :b]}])
      iex> program.facts
      [{"edge", [:a, :b]}]

  """
  @spec build_program(t(), [{String.t(), [term()]}]) :: Program.t() | {:error, term()}
  def build_program(%__MODULE__{relations: relations, rules: rules}, facts \\ []) do
    relations
    |> Enum.reduce(Program.new(), fn {name, types}, program ->
      Program.add_relation(program, name, types)
    end)
    |> Program.add_facts(facts)
    |> then(&Enum.reduce(rules, &1, fn rule, program -> add_rule(program, rule) end))
  end

  defp add_rule(program, {head, body}), do: Program.add_rule(program, head, body)

  defp add_rule(program, {head, body, constraints}),
    do: Program.add_rule(program, head, body, constraints)
end
