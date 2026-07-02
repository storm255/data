defmodule Data.SkillTaxonomy.RowBuilder do
  @moduledoc """
  Builds a `Role` document, its `Skill`/relation documents, and any
  warnings, from one role's already-structured field data. Pure — no
  network, no CSV/form-specific parsing.

  This is the "one document-building function" design doc §4 promises
  for both entry paths: `Data.SkillTaxonomy.CsvImporter` calls it once
  per CSV row (after splitting that row's `;`-delimited cells into
  lists); `DataWeb.SkillTaxonomy.RoleLive` calls it once per form
  submission (its dynamic add/remove lists are already real lists, no
  splitting needed). Neither caller duplicates validation rules.

  Deliberately **not** responsible for cross-row/cross-request
  concerns — those need visibility this module doesn't have:

  - Duplicate role identity (two rows/submissions both claiming the same
    `{primary, context}`) — only a caller iterating multiple rows can
    see that; `CsvImporter` checks it before calling `build/2`.
  - Whether a `context` variant's base role exists — this module takes
    that as the `:base_role_exists?` option instead of checking itself,
    since "exists" means different things per caller (`CsvImporter`
    checks the rest of the same file; `RoleLive` would check TerminusDB
    directly, live).
  """

  @relation_kinds %{
    supporting: "supporting",
    type_of: "type_of",
    sibling: "sibling",
    hard_negatives: "hard_negative",
    easy_negatives: "easy_negative",
    exclusions: "exclusion"
  }

  @type fields :: %{
          primary: String.t(),
          description: String.t(),
          context: String.t(),
          synonyms: [String.t()],
          supporting: [String.t()],
          type_of: [String.t()],
          sibling: [String.t()],
          hard_negatives: [String.t()],
          easy_negatives: [String.t()],
          exclusions: [String.t()],
          locale: String.t(),
          industry: String.t(),
          confidence: String.t()
        }

  @type pending_relation :: %{
          from: {:role, String.t(), String.t()},
          to: {:role, String.t(), String.t()} | {:skill, String.t()},
          relation_type: String.t(),
          confidence: String.t()
        }

  @type built :: %{
          role: map(),
          skills: [map()],
          relations: [pending_relation()],
          warnings: [String.t()]
        }

  @doc """
  Builds one role's documents from its fields.

  ## Options

  - `:base_role_exists?` — required when `fields.context` is non-blank;
    whether a blank-context role of the same `primary` already exists
    (elsewhere in the same batch, or in TerminusDB — the caller decides
    what "exists" means). Ignored when `context` is blank.

  Returns `{:error, message}` for a missing `primary`, an invalid
  `confidence`, or a `context` row with no base role — none of which
  this module can fix, only report.
  """
  @spec build(fields(), keyword()) :: {:ok, built()} | {:error, String.t()}
  def build(fields, opts \\ []) do
    with :ok <- validate_primary(fields.primary),
         :ok <- validate_base_role(fields.context, Keyword.get(opts, :base_role_exists?)),
         {:ok, confidence} <- validate_confidence(fields.confidence) do
      {:ok, build_row(fields, confidence)}
    end
  end

  defp validate_primary(""), do: {:error, "primary is required"}
  defp validate_primary(_primary), do: :ok

  defp validate_base_role("", _base_role_exists?), do: :ok
  defp validate_base_role(_context, true), do: :ok

  defp validate_base_role(_context, _not_true) do
    {:error, "no base role found — the base (blank-context) row must exist first"}
  end

  defp validate_confidence(""), do: {:ok, "guess"}
  defp validate_confidence(value) when value in ["sure", "guess"], do: {:ok, value}

  defp validate_confidence(value),
    do: {:error, "invalid confidence #{inspect(value)} — expected \"sure\" or \"guess\""}

  defp build_row(fields, confidence) do
    role = build_role_doc(fields)
    relations = build_relations(fields, confidence)

    skills =
      relations
      |> Enum.map(& &1.to)
      |> Enum.filter(&match?({:skill, _}, &1))
      |> Enum.map(&skill_doc/1)

    relations =
      if fields.context == "" do
        relations
      else
        [auto_type_of_relation(fields, confidence) | relations]
      end

    %{
      role: role,
      skills: skills,
      relations: relations,
      warnings: warnings(fields)
    }
  end

  defp build_role_doc(fields) do
    base = %{
      "@type" => "Role",
      "primary_name" => fields.primary,
      "context" => fields.context,
      "locale" => fields.locale,
      "industry" => fields.industry,
      "synonyms" => Enum.map(fields.synonyms, &synonym_doc(&1, fields.locale))
    }

    case fields.description do
      "" -> base
      description -> Map.put(base, "description", description)
    end
  end

  defp synonym_doc(term, locale), do: %{"@type" => "Synonym", "term" => term, "locale" => locale}

  defp build_relations(fields, confidence) do
    for {key, relation_type} <- @relation_kinds,
        target <- Map.fetch!(fields, key) do
      %{
        from: {:role, fields.primary, fields.context},
        to: relation_target(key, target),
        relation_type: relation_type,
        confidence: confidence
      }
    end
  end

  defp relation_target(:supporting, target), do: {:skill, target}
  defp relation_target(_key, target), do: {:role, target, ""}

  defp skill_doc({:skill, name}), do: %{"@type" => "Skill", "name" => name}

  defp auto_type_of_relation(fields, confidence) do
    %{
      from: {:role, fields.primary, fields.context},
      to: {:role, fields.primary, ""},
      relation_type: "type_of",
      confidence: confidence
    }
  end

  defp warnings(fields) do
    []
    |> maybe_warn(length(fields.synonyms) < 2, "fewer than 2 synonyms")
    |> maybe_warn(fields.hard_negatives == [], "0 hard negatives")
  end

  defp maybe_warn(warnings, false, _message), do: warnings
  defp maybe_warn(warnings, true, message), do: warnings ++ [message]
end
