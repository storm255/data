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
    out. No network. Per-row document building delegates to
    `Data.SkillTaxonomy.RowBuilder`, shared with the LiveView entry
    form; this module only handles what's CSV-specific (splitting
    `;`-delimited cells, and the cross-row checks `RowBuilder` can't do
    on its own: duplicate role identity, whether a `context` row's base
    role exists elsewhere in the same file).
  - `import/2` performs the actual TerminusDB writes: inserts roles and
    skills first, reads the `@id` each insert response returns, then
    builds and inserts `RoleRelation` documents from those real ids.
  """

  alias Data.SkillTaxonomy.RowBuilder
  alias NimbleCSV.RFC4180, as: CSV

  @columns ~w(primary description context synonyms supporting type_of sibling
              hard_negatives easy_negatives exclusions locale industry confidence)a

  @column_names Enum.map(@columns, &Atom.to_string/1)
  @list_columns ~w(synonyms supporting type_of sibling hard_negatives easy_negatives exclusions)a

  @type parsed :: %{
          roles: [map()],
          skills: [map()],
          pending_relations: [RowBuilder.pending_relation()],
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
      |> Enum.filter(fn {_row, raw} -> raw["context"] == "" end)
      |> MapSet.new(fn {_row, raw} -> raw["primary"] end)

    duplicate_keys =
      rows
      |> Enum.map(fn {_row, raw} -> {raw["primary"], raw["context"]} end)
      |> Enum.frequencies()
      |> Enum.filter(fn {_key, count} -> count > 1 end)
      |> MapSet.new(fn {key, _count} -> key end)

    init = %{roles: [], skills: [], pending_relations: [], warnings: [], errors: []}

    rows
    |> Enum.reduce(init, &process_row(&1, &2, base_role_names, duplicate_keys))
    |> dedupe_skills()
  end

  defp process_row({row_num, raw}, acc, base_role_names, duplicate_keys) do
    primary = raw["primary"]
    context = raw["context"]

    case validate_not_duplicate(primary, context, duplicate_keys) do
      :ok ->
        fields = to_row_builder_fields(raw)
        base_role_exists? = MapSet.member?(base_role_names, primary)

        case RowBuilder.build(fields, base_role_exists?: base_role_exists?) do
          {:ok, built} -> merge_built(acc, row_num, built)
          {:error, message} -> add_error(acc, row_num, primary, message)
        end

      {:error, message} ->
        add_error(acc, row_num, primary, message)
    end
  end

  defp validate_not_duplicate(primary, context, duplicate_keys) do
    if MapSet.member?(duplicate_keys, {primary, context}) do
      {:error, "duplicate role identity for #{inspect({primary, context})}"}
    else
      :ok
    end
  end

  defp to_row_builder_fields(raw) do
    %{
      primary: raw["primary"],
      description: raw["description"],
      context: raw["context"],
      locale: raw["locale"],
      industry: raw["industry"],
      confidence: raw["confidence"]
    }
    |> Map.merge(Map.new(@list_columns, &{&1, split_list(raw[Atom.to_string(&1)])}))
  end

  defp split_list(nil), do: []

  defp split_list(value) do
    value
    |> String.split(";")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp merge_built(acc, row_num, built) do
    %{
      acc
      | roles: acc.roles ++ [built.role],
        skills: acc.skills ++ built.skills,
        pending_relations: acc.pending_relations ++ built.relations,
        warnings: acc.warnings ++ Enum.map(built.warnings, &%{row: row_num, message: &1})
    }
  end

  defp add_error(acc, row_num, primary, message) do
    %{acc | errors: acc.errors ++ [%{row: row_num, primary: nullify(primary), message: message}]}
  end

  defp nullify(""), do: nil
  defp nullify(value), do: value

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
