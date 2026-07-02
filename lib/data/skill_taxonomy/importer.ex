defmodule Data.SkillTaxonomy.Importer do
  @moduledoc """
  Imports a `parse/1` result (see `Data.SkillTaxonomy.CsvImporter` and,
  once built, `Data.SkillTaxonomy.XlsxImporter`) into TerminusDB. Format
  agnostic — the same `%{roles:, skills:, pending_relations:, warnings:,
  errors:}` shape either parser (or `DataWeb.SkillTaxonomy.RoleLive`,
  via its own `built` -> `parsed`-shaped conversion) produces is all
  `import/2` needs; it has no CSV- or XLSX-specific logic of its own.

  `RoleRelation.from`/`to` must hold the exact `@id` TerminusDB assigns
  a `Role`/`Skill`, and that can only be learned from TerminusDB's own
  insert response — its Lexical-key percent-encoding doesn't match
  Elixir's `URI.encode/2` (e.g. it leaves `&` unescaped), so it can't be
  safely predicted (see design doc §5). `import/2` inserts roles and
  skills first, reads the `@id` each insert response returns, then
  builds and inserts `RoleRelation` documents from those real ids.
  """

  @doc """
  Imports a `parse/1` result into TerminusDB: inserts `roles` and
  `skills`, reads the real `@id` each insert response returns, then
  builds and inserts `RoleRelation` documents from `pending_relations`
  using those ids. `weight` is set to `1.0` here — never contributor-set
  (see design doc §2). A relation's optional `notes`/`relationship_detail`
  (design doc §2's free-text nuance field) are carried onto the
  `RoleRelation` document when the pending relation supplied them.

  A relation naming a `Role` that's neither in this batch nor already in
  TerminusDB gets a minimal stub created for it (`status: "stub"`, design
  doc §2) rather than failing the import — requiring every referenced
  role to already exist would force an import ordering contributors
  can't realistically guarantee. The returned summary's `:stub_roles`
  lists every `{primary_name, context}` stub-created in this run, so
  they're visible for follow-up (differentiate it for real, or notice a
  typo — see design doc §4). `Skill` targets never hit this path — see
  design doc §2 on why.

  Returns `{:error, reason}` on the first failed insert/query rather
  than continuing with a partial import.
  """
  @spec import(TerminusDB.Config.t(), map()) ::
          {:ok,
           %{
             roles: non_neg_integer(),
             skills: non_neg_integer(),
             relations: non_neg_integer(),
             stub_roles: [{String.t(), String.t()}]
           }}
          | {:error, term()}
  def import(%TerminusDB.Config{} = config, %{} = parsed) do
    with {:ok, role_ids} <- insert_and_index(config, parsed.roles, &role_key/1),
         {:ok, skill_ids} <- insert_and_index(config, parsed.skills, &skill_key/1),
         ids = Map.merge(role_ids, skill_ids),
         {:ok, relation_docs, stub_roles} <-
           resolve_relations(config, parsed.pending_relations, ids),
         {:ok, _} <- insert_all(config, relation_docs) do
      {:ok,
       %{
         roles: map_size(role_ids),
         skills: map_size(skill_ids),
         relations: length(relation_docs),
         stub_roles: stub_roles
       }}
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
  # re-importing the same file fail instead of updating in place. This
  # matches how Data.TerminusDB.Setup.ensure_schema!/2 already handles
  # idempotent re-application elsewhere in this app.
  defp insert_one(config, doc) do
    case TerminusDB.Document.replace(config, doc,
           create: true,
           author: "skill_taxonomy_importer",
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

  defp resolve_relations(config, pending_relations, ids) do
    init = {:ok, [], ids, []}

    pending_relations
    |> Enum.reduce_while(init, fn relation, {:ok, docs, ids, stub_roles} ->
      with {:ok, from_id, ids, stub_roles} <-
             fetch_or_create(config, ids, stub_roles, relation.from),
           {:ok, to_id, ids, stub_roles} <-
             fetch_or_create(config, ids, stub_roles, relation.to, relation[:local_term]) do
        doc =
          %{
            "@type" => "RoleRelation",
            "from" => from_id,
            "to" => to_id,
            "relation_type" => relation.relation_type,
            "confidence" => relation.confidence,
            "weight" => 1.0
          }
          |> maybe_put("notes", relation[:notes])
          |> maybe_put("relationship_detail", relation[:relationship_detail])

        {:cont, {:ok, [doc | docs], ids, stub_roles}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, docs, _ids, stub_roles} ->
        stub_roles =
          stub_roles
          |> Enum.reverse()
          |> Enum.map(fn {:role, primary, context} -> {primary, context} end)

        {:ok, Enum.reverse(docs), stub_roles}

      error ->
        error
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Already resolved in this batch (or by an earlier relation in this
  # same call) -> reuse it. Otherwise: exact-match live query, else
  # stub-create. Only Role keys ever reach the "not in ids" branch in
  # practice (see moduledoc), but this handles Skill keys the same way
  # for robustness — just without adding to stub_roles, since a Skill
  # has no "differentiated vs stub" concept to flag.
  defp fetch_or_create(config, ids, stub_roles, key, local_term \\ nil) do
    case Map.fetch(ids, key) do
      {:ok, id} ->
        {:ok, id, ids, stub_roles}

      :error ->
        case resolve_or_stub(config, key, local_term) do
          {:ok, id, :existing} ->
            {:ok, id, Map.put(ids, key, id), stub_roles}

          {:ok, id, :created} ->
            stub_roles = if match?({:role, _, _}, key), do: [key | stub_roles], else: stub_roles
            {:ok, id, Map.put(ids, key, id), stub_roles}

          {:error, _} = error ->
            error
        end
    end
  end

  defp resolve_or_stub(config, {:role, primary, context}, local_term) do
    query = %{"@type" => "Role", "primary_name" => primary, "context" => context}

    stub = %{
      "@type" => "Role",
      "primary_name" => primary,
      "context" => context,
      "locale" => "",
      "industry" => "",
      "status" => "stub",
      "synonyms" => stub_synonyms(local_term)
    }

    query_or_create(config, query, stub)
  end

  defp resolve_or_stub(config, {:skill, name}, _local_term) do
    query = %{"@type" => "Skill", "name" => name}
    stub = %{"@type" => "Skill", "name" => name}
    query_or_create(config, query, stub)
  end

  defp stub_synonyms(nil), do: []

  defp stub_synonyms(term) do
    [%{"@type" => "Synonym", "term" => term, "locale" => "local"}]
  end

  defp query_or_create(config, query, stub) do
    case TerminusDB.Document.query(config, query) do
      {:ok, [doc | _]} ->
        {:ok, doc["@id"], :existing}

      {:ok, []} ->
        case insert_one(config, stub) do
          {:ok, id} -> {:ok, id, :created}
          {:error, _} = error -> error
        end

      {:error, _} = error ->
        error
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
