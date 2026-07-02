defmodule Data.SkillTaxonomy.CsvImporter do
  @moduledoc """
  Parses and imports the skill-taxonomy CSV format (see
  `design/SKILLS_TAXONOMY.md` §4) into TerminusDB documents.

  Split into two steps because `RoleRelation.from`/`to` must hold the
  exact `@id` TerminusDB assigns a `Role`/`Skill`, and that can only be
  learned from TerminusDB's own insert response — its Lexical-key
  percent-encoding doesn't match Elixir's `URI.encode/2` (e.g. it leaves
  `&` unescaped), so it can't be safely predicted (see design doc §5).

  - `parse/1` is pure — CSV in, `Role`/`Skill` document maps and
    *pending* relations (addressed by natural key, not yet a real `@id`)
    out. No network.
  - `import/2` performs the actual TerminusDB writes: inserts roles and
    skills first, reads the `@id` each insert response returns, then
    builds and inserts `RoleRelation` documents from those real ids.
  """

  alias NimbleCSV.RFC4180, as: CSV

  @columns ~w(primary description context synonyms supporting type_of sibling
              hard_negatives easy_negatives exclusions locale industry confidence)a

  @column_names Enum.map(@columns, &Atom.to_string/1)

  @relation_columns %{
    supporting: "supporting",
    type_of: "type_of",
    sibling: "sibling",
    hard_negatives: "hard_negative",
    easy_negatives: "easy_negative",
    exclusions: "exclusion"
  }

  @type pending_relation :: %{
          from: {:role, String.t(), String.t()},
          to: {:role, String.t(), String.t()} | {:skill, String.t()},
          relation_type: String.t(),
          confidence: String.t()
        }

  @type parsed :: %{
          roles: [map()],
          skills: [map()],
          pending_relations: [pending_relation()],
          warnings: [%{row: pos_integer(), message: String.t()}],
          errors: [%{row: pos_integer(), message: String.t()}]
        }

  @doc """
  Parses CSV content into `Role`/`Skill` document maps and pending
  relations. Pure — performs no network I/O.

  Row-level problems (missing primary, bad confidence, duplicate role
  identity, a context row with no base row) are collected into
  `result.errors`; that row contributes nothing else to the result. A
  malformed header is a single top-level error for the whole file.
  """
  @spec parse(String.t()) :: {:ok, parsed()} | {:error, term()}
  def parse(csv_content) when is_binary(csv_content) do
    case CSV.parse_string(csv_content, skip_headers: false) do
      [header | data_rows] ->
        with :ok <- validate_header(header) do
          {:ok, build_result(data_rows)}
        end

      [] ->
        {:error, :empty_file}
    end
  rescue
    e in NimbleCSV.ParseError -> {:error, {:parse_error, Exception.message(e)}}
  end

  defp validate_header(header) do
    header_set = MapSet.new(header)
    expected_set = MapSet.new(@column_names)

    missing = MapSet.difference(expected_set, header_set) |> Enum.sort()
    unexpected = MapSet.difference(header_set, expected_set) |> Enum.sort()

    if missing == [] and unexpected == [] do
      :ok
    else
      {:error, {:invalid_header, %{missing: missing, unexpected: unexpected}}}
    end
  end

  defp build_result(data_rows) do
    rows =
      data_rows
      |> Enum.with_index(2)
      |> Enum.map(fn {values, row_num} ->
        {row_num, Enum.zip(@column_names, values) |> Map.new()}
      end)

    base_role_names =
      rows
      |> Enum.filter(fn {_row, fields} -> fields["context"] == "" end)
      |> MapSet.new(fn {_row, fields} -> fields["primary"] end)

    duplicate_keys =
      rows
      |> Enum.map(fn {_row, fields} -> {fields["primary"], fields["context"]} end)
      |> Enum.frequencies()
      |> Enum.filter(fn {_key, count} -> count > 1 end)
      |> MapSet.new(fn {key, _count} -> key end)

    init = %{roles: [], skills: [], pending_relations: [], warnings: [], errors: []}

    rows
    |> Enum.reduce(init, &process_row(&1, &2, base_role_names, duplicate_keys))
    |> dedupe_skills()
  end

  defp process_row({row_num, fields}, acc, base_role_names, duplicate_keys) do
    primary = fields["primary"]
    context = fields["context"]

    with :ok <- validate_primary(primary),
         :ok <- validate_not_duplicate(primary, context, duplicate_keys),
         :ok <- validate_base_role(primary, context, base_role_names),
         {:ok, confidence} <- validate_confidence(fields["confidence"]) do
      build_row(row_num, fields, confidence, acc)
    else
      {:error, message} ->
        %{
          acc
          | errors: acc.errors ++ [%{row: row_num, primary: nullify(primary), message: message}]
        }
    end
  end

  defp nullify(""), do: nil
  defp nullify(value), do: value

  defp validate_primary(""), do: {:error, "primary is required"}
  defp validate_primary(_primary), do: :ok

  defp validate_not_duplicate(primary, context, duplicate_keys) do
    if MapSet.member?(duplicate_keys, {primary, context}) do
      {:error, "duplicate role identity for #{inspect({primary, context})}"}
    else
      :ok
    end
  end

  defp validate_base_role(_primary, "", _base_role_names), do: :ok

  defp validate_base_role(primary, _context, base_role_names) do
    if MapSet.member?(base_role_names, primary) do
      :ok
    else
      {:error,
       "no base role found for #{inspect(primary)} — the base (blank-context) row must exist first"}
    end
  end

  defp validate_confidence(""), do: {:ok, "guess"}
  defp validate_confidence(value) when value in ["sure", "guess"], do: {:ok, value}

  defp validate_confidence(value),
    do: {:error, "invalid confidence #{inspect(value)} — expected \"sure\" or \"guess\""}

  defp build_row(row_num, fields, confidence, acc) do
    primary = fields["primary"]
    context = fields["context"]

    synonyms = split_list(fields["synonyms"])
    hard_negatives = split_list(fields["hard_negatives"])

    role = build_role_doc(fields, synonyms)
    relations = build_relations(fields, primary, context, confidence)

    skills =
      relations
      |> Enum.map(& &1.to)
      |> Enum.filter(&match?({:skill, _}, &1))
      |> Enum.map(&skill_doc/1)

    relations =
      if context == "" do
        relations
      else
        [auto_type_of_relation(primary, context, confidence) | relations]
      end

    warnings = row_warnings(row_num, synonyms, hard_negatives)

    %{
      acc
      | roles: acc.roles ++ [role],
        skills: acc.skills ++ skills,
        pending_relations: acc.pending_relations ++ relations,
        warnings: acc.warnings ++ warnings
    }
  end

  defp build_role_doc(fields, synonyms) do
    base = %{
      "@type" => "Role",
      "primary_name" => fields["primary"],
      "context" => fields["context"],
      "locale" => fields["locale"],
      "industry" => fields["industry"],
      "synonyms" => Enum.map(synonyms, &synonym_doc(&1, fields["locale"]))
    }

    case fields["description"] do
      "" -> base
      description -> Map.put(base, "description", description)
    end
  end

  defp synonym_doc(term, locale) do
    %{"@type" => "Synonym", "term" => term, "locale" => locale}
  end

  defp build_relations(fields, primary, context, confidence) do
    for {column, relation_type} <- @relation_columns,
        target <- split_list(fields[Atom.to_string(column)]) do
      %{
        from: {:role, primary, context},
        to: relation_target(column, target),
        relation_type: relation_type,
        confidence: confidence
      }
    end
  end

  defp relation_target(:supporting, target), do: {:skill, target}
  defp relation_target(_column, target), do: {:role, target, ""}

  defp skill_doc({:skill, name}), do: %{"@type" => "Skill", "name" => name}

  defp auto_type_of_relation(primary, context, confidence) do
    %{
      from: {:role, primary, context},
      to: {:role, primary, ""},
      relation_type: "type_of",
      confidence: confidence
    }
  end

  defp row_warnings(row_num, synonyms, hard_negatives) do
    []
    |> maybe_warn(row_num, length(synonyms) < 2, "fewer than 2 synonyms")
    |> maybe_warn(row_num, hard_negatives == [], "0 hard negatives")
  end

  defp maybe_warn(warnings, _row_num, false, _message), do: warnings

  defp maybe_warn(warnings, row_num, true, message),
    do: warnings ++ [%{row: row_num, message: message}]

  defp split_list(nil), do: []

  defp split_list(value) do
    value
    |> String.split(";")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp dedupe_skills(result) do
    skills = Enum.uniq_by(result.skills, & &1["name"])
    %{result | skills: skills}
  end

  @doc """
  Imports a `parse/1` result into TerminusDB: inserts `roles` and
  `skills`, reads the real `@id` each insert response returns, then
  builds and inserts `RoleRelation` documents from `pending_relations`
  using those ids. `weight` is set to `1.0` here — never contributor-set
  (see design doc §2).

  Returns `{:error, reason}` on the first failed insert rather than
  continuing with a partial import.
  """
  @spec import(TerminusDB.Config.t(), parsed()) :: {:ok, map()} | {:error, term()}
  def import(%TerminusDB.Config{} = config, %{} = parsed) do
    with {:ok, role_ids} <- insert_and_index(config, parsed.roles, &role_key/1),
         {:ok, skill_ids} <- insert_and_index(config, parsed.skills, &skill_key/1),
         ids = Map.merge(role_ids, skill_ids),
         {:ok, relation_docs} <- resolve_relations(parsed.pending_relations, ids),
         {:ok, _} <- insert_all(config, relation_docs) do
      {:ok,
       %{roles: map_size(role_ids), skills: map_size(skill_ids), relations: length(relation_docs)}}
    end
  end

  defp role_key(%{"primary_name" => primary, "context" => context}), do: {:role, primary, context}
  defp skill_key(%{"name" => name}), do: {:skill, name}

  defp insert_and_index(_config, [], _key_fun), do: {:ok, %{}}

  defp insert_and_index(config, docs, key_fun) do
    Enum.reduce_while(docs, {:ok, %{}}, fn doc, {:ok, acc} ->
      case insert_one(config, doc) do
        {:ok, id} -> {:cont, {:ok, Map.put(acc, key_fun.(doc), id)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # Uses replace(create: true), not insert/3 — insert/3 errors if the
  # document's Lexical-keyed id already exists, which would make
  # re-importing the same CSV fail instead of updating in place. This
  # matches how Data.TerminusDB.Setup.ensure_schema!/2 already handles
  # idempotent re-application elsewhere in this app.
  defp insert_one(config, doc) do
    case TerminusDB.Document.replace(config, doc,
           create: true,
           author: "csv_importer",
           message: "skill taxonomy import"
         ) do
      {:ok, [full_iri]} -> {:ok, short_id(full_iri)}
      {:ok, [full_iri | _]} -> {:ok, short_id(full_iri)}
      {:error, _} = error -> error
    end
  end

  # Insert responses come back as a full IRI (e.g.
  # "terminusdb:///data/Role/Test%20Role+"); documents reference each
  # other by the short form ("Role/Test%20Role+"). Stripping a known,
  # fixed prefix — not reconstructing the percent-encoding ourselves.
  defp short_id("terminusdb:///data/" <> short), do: short
  defp short_id(other), do: other

  defp resolve_relations(pending_relations, ids) do
    Enum.reduce_while(pending_relations, {:ok, []}, fn relation, {:ok, acc} ->
      with {:ok, from_id} <- fetch_id(ids, relation.from),
           {:ok, to_id} <- fetch_id(ids, relation.to) do
        doc = %{
          "@type" => "RoleRelation",
          "from" => from_id,
          "to" => to_id,
          "relation_type" => relation.relation_type,
          "confidence" => relation.confidence,
          "weight" => 1.0
        }

        {:cont, {:ok, [doc | acc]}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, docs} -> {:ok, Enum.reverse(docs)}
      error -> error
    end
  end

  defp fetch_id(ids, key) do
    case Map.fetch(ids, key) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, {:unresolved_reference, key}}
    end
  end

  defp insert_all(_config, []), do: {:ok, []}

  defp insert_all(config, docs) do
    Enum.reduce_while(docs, {:ok, []}, fn doc, {:ok, acc} ->
      case insert_one(config, doc) do
        {:ok, id} -> {:cont, {:ok, [id | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end
end
