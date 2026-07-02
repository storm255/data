defmodule Data.SkillTaxonomy.ClusterResolver do
  @moduledoc """
  Writes a human's decision on a `Data.SkillTaxonomy.Reconciliation`
  cluster back to TerminusDB — the I/O half of the stub reconciliation
  view (design doc §9 roadmap item 8, §11), same role `Importer` plays
  for `RowBuilder`. Named outcome-neutral (not e.g. `RoleMerger`) since
  it owns all three review outcomes, which all end up as ordinary
  `RoleRelation`/`Role` writes through the same
  `Document.replace(create: true, ...)` idempotent-upsert pattern
  `Importer.insert_one/2` already establishes:

  - `merge/3` — alternative spellings of the same role: fold into one
    canonical `Role`, delete the rest.
  - `keep_separate/4` — genuinely different-but-related roles: a
    `sibling` relation carrying a human-set weight (design doc §11 —
    set by a drag gesture in the eventual UI, not typed).
  - `mark_unrelated/3` — similarly-named but unrelated roles: an
    `easy_negative` relation, so the pair stops resurfacing as a
    clustering candidate (Reconciliation.cluster/2 is expected to skip
    pairs that already have any relation between them).

  No multi-document transactions exist anywhere in this codebase
  (`TerminusDB.Document.delete`/`replace` are independent HTTP calls) —
  `merge/3` inherits the same "abort on first problem, no partial-
  operation protection" risk tolerance `Importer.import/2` already
  documents. Acceptable here because this is a human-supervised,
  one-cluster-at-a-time flow, not a bulk import.
  """

  alias TerminusDB.Document

  @doc """
  Merges `duplicate_ids` into `canonical_id`: folds each duplicate's
  `primary_name` and its own synonyms into canonical's `synonyms`
  (deduped by the real `Synonym` Lexical key, `{term, locale}` — not
  `term` alone — every folded-in synonym stamped with *canonical's*
  locale, not the duplicate's, so a bare stub's `locale: ""` doesn't
  produce a spurious non-duplicate entry), repoints every relation
  that referenced a duplicate to reference canonical instead, then
  deletes the duplicates.

  A `RoleRelation`'s `from`/`to` are part of its Lexical key, so a
  relation can't be repointed in place — each one is deleted and
  reinserted with the substitution applied. Two things can happen
  during that substitution, both handled explicitly rather than left
  to TerminusDB's implicit last-write-wins:

  - **Self-loop**: a relation directly between the duplicate and
    canonical becomes `canonical -> canonical` after substitution —
    dropped rather than inserted; counted in the returned summary's
    `:self_loops_dropped`.
  - **Collision**: canonical already has a relation with the same
    `{from, to, relation_type}` the substitution would produce — the
    higher-`weight` relation wins (ties broken by `confidence: "sure"`
    over `"guess"`); the discarded side is reported in the summary's
    `:collisions`, never silently dropped.

  Returns `{:error, reason}` on the first failed call.
  """
  @spec merge(TerminusDB.Config.t(), String.t(), [String.t()]) ::
          {:ok,
           %{
             merged: non_neg_integer(),
             self_loops_dropped: non_neg_integer(),
             collisions: [map()]
           }}
          | {:error, term()}
  def merge(config, canonical_id, duplicate_ids) do
    with {:ok, canonical} <- Document.get(config, id: canonical_id, as_list: false),
         {:ok, duplicates} <- fetch_docs(config, duplicate_ids),
         {:ok, _} <- fold_synonyms(config, canonical, duplicates),
         id_remap = Map.new(duplicate_ids, &{&1, canonical_id}),
         {:ok, outcome} <- repoint_relations(config, duplicate_ids, id_remap),
         {:ok, _} <- delete_all(config, duplicate_ids) do
      {:ok,
       %{
         merged: length(duplicate_ids),
         self_loops_dropped: outcome.self_loops_dropped,
         collisions: outcome.collisions
       }}
    end
  end

  @doc """
  Records that `role_a_id` and `role_b_id` are different-but-related
  roles: writes a `sibling` `RoleRelation` with the given `weight`.
  `confidence: "sure"` — a human explicitly reviewed and placed this,
  not a guess. Both ids are already-resolved `@id`s, so this skips
  `Importer`'s query-else-stub-create resolution entirely; it doesn't
  apply here.
  """
  @spec keep_separate(TerminusDB.Config.t(), String.t(), String.t(), float()) ::
          {:ok, String.t()} | {:error, term()}
  def keep_separate(config, role_a_id, role_b_id, weight) do
    write_relation(config, role_a_id, role_b_id, "sibling", "sure", weight)
  end

  @doc """
  Records that `role_a_id` and `role_b_id` are similarly-named but
  unrelated: writes an `easy_negative` relation. Reuses the existing
  relation kind rather than a separate "dismissed" concept — this is
  what makes a rejected pair stop resurfacing as a clustering
  candidate.
  """
  @spec mark_unrelated(TerminusDB.Config.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def mark_unrelated(config, role_a_id, role_b_id) do
    write_relation(config, role_a_id, role_b_id, "easy_negative", "sure", 1.0)
  end

  defp write_relation(config, from_id, to_id, relation_type, confidence, weight) do
    doc = %{
      "@type" => "RoleRelation",
      "from" => from_id,
      "to" => to_id,
      "relation_type" => relation_type,
      "confidence" => confidence,
      "weight" => weight
    }

    insert_one(config, doc)
  end

  defp fetch_docs(config, ids) do
    Enum.reduce_while(ids, {:ok, %{}}, fn id, {:ok, acc} ->
      case Document.get(config, id: id, as_list: false) do
        {:ok, doc} -> {:cont, {:ok, Map.put(acc, id, doc)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp fold_synonyms(config, canonical, duplicates) do
    locale = canonical["locale"]

    folded =
      duplicates
      |> Map.values()
      |> Enum.flat_map(fn duplicate ->
        [%{"term" => duplicate["primary_name"]} | duplicate["synonyms"] || []]
      end)
      |> Enum.map(&%{"@type" => "Synonym", "term" => &1["term"], "locale" => locale})

    synonyms =
      ((canonical["synonyms"] || []) ++ folded)
      |> Enum.uniq_by(&{&1["term"], &1["locale"]})

    updated = Map.put(canonical, "synonyms", synonyms)
    insert_one(config, updated)
  end

  defp repoint_relations(config, duplicate_ids, id_remap) do
    with {:ok, relations} <- fetch_relations(config, duplicate_ids) do
      Enum.reduce_while(relations, {:ok, %{self_loops_dropped: 0, collisions: []}}, fn relation,
                                                                                       {:ok, acc} ->
        case repoint_one(config, relation, id_remap, acc) do
          {:ok, acc} -> {:cont, {:ok, acc}}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  defp fetch_relations(config, duplicate_ids) do
    Enum.reduce_while(duplicate_ids, {:ok, []}, fn id, {:ok, acc} ->
      with {:ok, from_relations} <-
             Document.query(config, %{"@type" => "RoleRelation", "from" => id}),
           {:ok, to_relations} <- Document.query(config, %{"@type" => "RoleRelation", "to" => id}) do
        {:cont, {:ok, acc ++ from_relations ++ to_relations}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp repoint_one(config, relation, id_remap, acc) do
    new_from = Map.get(id_remap, relation["from"], relation["from"])
    new_to = Map.get(id_remap, relation["to"], relation["to"])

    with {:ok, _} <-
           Document.delete(config,
             id: relation["@id"],
             author: "cluster_resolver",
             message: "reconciliation merge"
           ) do
      if new_from == new_to do
        {:ok, %{acc | self_loops_dropped: acc.self_loops_dropped + 1}}
      else
        write_repointed_relation(config, relation, new_from, new_to, acc)
      end
    end
  end

  defp write_repointed_relation(config, relation, new_from, new_to, acc) do
    relation_type = relation["relation_type"]

    query = %{
      "@type" => "RoleRelation",
      "from" => new_from,
      "to" => new_to,
      "relation_type" => relation_type
    }

    with {:ok, existing} <- Document.query(config, query) do
      candidate = %{relation | "from" => new_from, "to" => new_to}
      existing_relation = List.first(existing)
      winner = winning_relation(existing_relation, candidate)

      acc =
        if existing_relation do
          collision = %{
            from: new_from,
            to: new_to,
            relation_type: relation_type,
            kept_weight: winner["weight"]
          }

          %{acc | collisions: [collision | acc.collisions]}
        else
          acc
        end

      if winner == existing_relation do
        {:ok, acc}
      else
        case insert_one(config, strip_id(winner)) do
          {:ok, _} -> {:ok, acc}
          {:error, _} = error -> error
        end
      end
    end
  end

  defp winning_relation(nil, candidate), do: candidate

  defp winning_relation(existing, candidate) do
    cond do
      candidate["weight"] > existing["weight"] -> candidate
      candidate["weight"] < existing["weight"] -> existing
      candidate["confidence"] == "sure" and existing["confidence"] != "sure" -> candidate
      true -> existing
    end
  end

  defp strip_id(relation), do: Map.delete(relation, "@id")

  defp delete_all(config, ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      case Document.delete(config,
             id: id,
             author: "cluster_resolver",
             message: "reconciliation merge"
           ) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # Uses replace(create: true), not insert/3 — matches
  # Importer.insert_one/2's idempotent-upsert pattern.
  defp insert_one(config, doc) do
    case Document.replace(config, doc,
           create: true,
           author: "cluster_resolver",
           message: "reconciliation"
         ) do
      {:ok, [full_iri]} -> {:ok, short_id(full_iri)}
      {:ok, [full_iri | _]} -> {:ok, short_id(full_iri)}
      {:error, _} = error -> error
    end
  end

  defp short_id("terminusdb:///data/" <> short), do: short
  defp short_id(other), do: other
end
