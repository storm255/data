defmodule Data.SkillTaxonomy.RoleLoader do
  @moduledoc """
  Fetches an existing `Role` and its outgoing `RoleRelation`s back into
  `Data.SkillTaxonomy.RowBuilder.fields()` shape — the inverse of
  `RowBuilder.build/2`, resolving stored `@id` references back to the
  display names a human edits. Used by the LiveView edit path
  (`DataWeb.SkillTaxonomy.RoleLive`).
  """

  alias Data.SkillTaxonomy.RowBuilder

  @relation_type_to_field %{
    "supporting" => :supporting,
    "type_of" => :type_of,
    "sibling" => :sibling,
    "hard_negative" => :hard_negatives,
    "easy_negative" => :easy_negatives,
    "exclusion" => :exclusions,
    "manual_review" => :manual_review
  }

  @doc """
  Fetches the `Role` at `role_id` plus its outgoing relations, resolved
  to display names and grouped by field. Excludes the `type_of`
  relation `RowBuilder.build/2` auto-generates for a `context` variant
  (linking it back to its base role) — editing shouldn't surface a
  relation the next save will regenerate anyway.
  """
  @spec fetch(TerminusDB.Config.t(), String.t()) :: {:ok, RowBuilder.fields()} | {:error, term()}
  def fetch(config, role_id) do
    with {:ok, role} <- TerminusDB.Document.get(config, id: role_id, as_list: false),
         {:ok, relations} <-
           TerminusDB.Document.query(config, %{"@type" => "RoleRelation", "from" => role_id}),
         target_ids = relations |> Enum.map(& &1["to"]) |> Enum.uniq(),
         {:ok, target_docs} <- fetch_docs(config, target_ids) do
      {:ok, build_fields(role, relations, target_docs)}
    end
  end

  defp fetch_docs(config, ids) do
    Enum.reduce_while(ids, {:ok, %{}}, fn id, {:ok, acc} ->
      case TerminusDB.Document.get(config, id: id, as_list: false) do
        {:ok, doc} -> {:cont, {:ok, Map.put(acc, id, doc)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp build_fields(role, relations, target_docs) do
    base = %{
      primary: role["primary_name"],
      description: role["description"] || "",
      context: role["context"],
      locale: role["locale"],
      industry: role["industry"],
      confidence: "guess",
      synonyms: Enum.map(role["synonyms"] || [], & &1["term"])
    }

    grouped =
      relations
      |> Enum.reject(&auto_type_of_link?(&1, role, target_docs))
      |> Enum.group_by(& &1["relation_type"])

    Enum.reduce(@relation_type_to_field, base, fn {relation_type, field}, acc ->
      names =
        grouped
        |> Map.get(relation_type, [])
        |> Enum.map(&display_name(target_docs[&1["to"]]))

      Map.put(acc, field, names)
    end)
  end

  defp display_name(doc), do: doc["primary_name"] || doc["name"]

  defp auto_type_of_link?(%{"relation_type" => "type_of", "to" => to_id}, role, target_docs) do
    case {role["context"], target_docs[to_id]} do
      {"", _} -> false
      {_context, %{"primary_name" => name, "context" => ""}} -> name == role["primary_name"]
      _ -> false
    end
  end

  defp auto_type_of_link?(_relation, _role, _target_docs), do: false
end
