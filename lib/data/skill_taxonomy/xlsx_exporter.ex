defmodule Data.SkillTaxonomy.XlsxExporter do
  @moduledoc """
  Exports `Role`s (plus their outgoing `RoleRelation`s and `Synonym`s)
  from TerminusDB into the same reformed XLSX template shape
  `Data.SkillTaxonomy.XlsxImporter.parse/1` reads — one Role Summary
  header block plus one Term-Level Matching Detail table per role sheet
  (design doc §4), so the current state of the taxonomy (including
  anything adjusted through `DataWeb.SkillTaxonomy.RoleLive`, which
  `XlsxImporter` never sees) can be handed to someone as a readable
  document, not just inspected through the app.

  Not a strict inverse of `parse/1` — some information genuinely isn't
  reconstructable from what's stored:

  - **Local-language term** is written as a *second* `Synonym` on
    import (design doc §2), not kept as relation metadata — so on
    export, the Term-Level table's `Local-language term` column is
    always blank; a role's local-language name shows up as its own
    `Synonym` row instead, wherever that role's own sheet is exported.
  - **End-of-role Matching Statement** and **Category Guidance** text
    are never persisted (`XlsxImporter`'s moduledoc — no `RoleGuidance`
    storage exists yet, design doc §6), so those blocks are exported
    with their row labels but blank content.
  """

  alias TerminusDB.Document

  @relation_type_to_category %{
    "supporting" => "Supporting Skill",
    "type_of" => "Related Role",
    "sibling" => "Related Role",
    "hard_negative" => "Hard Negative",
    "manual_review" => "Manual Review",
    "easy_negative" => "Easy Negative",
    "exclusion" => "Exclusion"
  }

  @category_guidance_categories [
    "Synonyms",
    "Supporting Skills",
    "Related Roles",
    "Hard Negatives",
    "Manual Review",
    "Easy Negatives",
    "Exclusions"
  ]

  @bold [:bold]
  @section [:bold, {:font_size, 12}, {:bg_color, "#D9E1F2"}]
  @subtle [{:font_color, "#666666"}, :italic]

  @doc """
  Exports the given roles (or every `Role` in the database) to an XLSX
  binary.

  `role_keys` is either `:all`, or a list of `{primary_name, context}`
  tuples naming exactly the roles to export. Requesting a key with no
  matching `Role` is an error for the whole call, same as
  `Data.SkillTaxonomy.Importer.import/2`'s "abort on first problem"
  behavior — a typo in a requested role name should be visible, not
  silently skipped.
  """
  @spec export(TerminusDB.Config.t(), :all | [{String.t(), String.t()}]) ::
          {:ok, binary()} | {:error, term()}
  def export(config, role_keys \\ :all) do
    with {:ok, roles} <- fetch_roles(config, role_keys),
         {:ok, relations_by_role} <- fetch_relations(config, roles),
         target_ids =
           relations_by_role
           |> Map.values()
           |> List.flatten()
           |> Enum.map(& &1["to"])
           |> Enum.uniq(),
         {:ok, target_docs} <- fetch_docs(config, target_ids) do
      sheets =
        roles
        |> Enum.map(&build_role_sheet(&1, Map.get(relations_by_role, &1["@id"], []), target_docs))
        |> add_role_index(roles)

      XlsxWriter.generate(sheets)
    end
  end

  defp fetch_roles(config, :all) do
    Document.get(config, type: "Role", as_list: true)
  end

  defp fetch_roles(config, role_keys) do
    Enum.reduce_while(role_keys, {:ok, []}, fn {primary, context}, {:ok, acc} ->
      case Document.query(config, %{
             "@type" => "Role",
             "primary_name" => primary,
             "context" => context
           }) do
        {:ok, [role | _]} -> {:cont, {:ok, [role | acc]}}
        {:ok, []} -> {:halt, {:error, {:role_not_found, {primary, context}}}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, roles} -> {:ok, Enum.reverse(roles)}
      error -> error
    end
  end

  defp fetch_relations(config, roles) do
    Enum.reduce_while(roles, {:ok, %{}}, fn role, {:ok, acc} ->
      case Document.query(config, %{"@type" => "RoleRelation", "from" => role["@id"]}) do
        {:ok, relations} -> {:cont, {:ok, Map.put(acc, role["@id"], relations)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # Batched across every exported role's relations (not one fetch per
  # relation) — the same shape Data.SkillTaxonomy.RoleLoader.fetch/2
  # already uses for this, so a target referenced by several roles is
  # only ever fetched once.
  defp fetch_docs(config, ids) do
    Enum.reduce_while(ids, {:ok, %{}}, fn id, {:ok, acc} ->
      case Document.get(config, id: id, as_list: false) do
        {:ok, doc} -> {:cont, {:ok, Map.put(acc, id, doc)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # ---- Sheet building ----

  defp build_role_sheet(role, relations, target_docs) do
    rows =
      role_summary_rows(role) ++
        [[]] ++
        term_table_rows(role, relations, target_docs) ++
        [[]] ++
        category_guidance_rows() ++
        [[]] ++
        app_keywords_rows(role) ++
        [[]] ++
        notes_rows()

    XlsxWriter.new_sheet(sheet_name(role))
    |> write_rows(rows)
    |> XlsxWriter.set_column_width(0, 22)
    |> XlsxWriter.set_column_width(1, 32)
    |> XlsxWriter.set_column_width(2, 24)
    |> XlsxWriter.set_column_width(3, 32)
    |> XlsxWriter.set_column_width(4, 45)
    |> XlsxWriter.set_column_width(5, 14)
  end

  defp role_summary_rows(role) do
    [
      [{"Heeero Role Differentiation: #{role["primary_name"]}", @section}],
      [],
      [{"Role Summary", @bold}],
      ["Primary Role", role["primary_name"]],
      ["Description", role["description"] || ""],
      ["Locale / Language", role["locale"] || ""],
      ["Industry / Context", role["industry"] || ""],
      ["End-of-role Matching Statement", ""]
    ]
  end

  defp term_table_rows(role, relations, target_docs) do
    [
      [
        {"Term-Level Matching Detail", @bold},
        "",
        "",
        "",
        "",
        {"The single source of relationship data - every synonym, skill, related role, negative, and exclusion is one row here. Nothing else repeats it.",
         @subtle}
      ],
      [
        {"Category", @bold},
        {"Term", @bold},
        {"Local-language term", @bold},
        {"Relationship detail", @bold},
        {"Matching note", @bold},
        {"Confidence", @bold}
      ]
    ] ++
      synonym_rows(role) ++
      relation_rows(relations, target_docs)
  end

  defp synonym_rows(role) do
    Enum.map(role["synonyms"] || [], fn synonym ->
      ["Synonym", synonym["term"], nil, nil, nil, synonym["confidence"]]
    end)
  end

  defp relation_rows(relations, target_docs) do
    Enum.map(relations, fn relation ->
      category = Map.fetch!(@relation_type_to_category, relation["relation_type"])
      term = display_name(target_docs[relation["to"]])

      [
        category,
        term,
        nil,
        relation["relationship_detail"],
        relation["notes"],
        relation["confidence"]
      ]
    end)
  end

  defp display_name(nil), do: nil
  defp display_name(doc), do: doc["primary_name"] || doc["name"]

  defp category_guidance_rows do
    [
      [
        {"Category Guidance", @bold},
        "",
        {"Optional - informs matching-rule design, not stored as role data. Not yet persisted — see design doc §6.",
         @subtle}
      ],
      [{"Category", @bold}, {"Expanded Detail", @bold}, {"Heeero matching logic", @bold}]
    ] ++ Enum.map(@category_guidance_categories, &[&1])
  end

  defp app_keywords_rows(role) do
    keywords = role["keywords"] || []

    [
      [{"App Keywords / Job Phrases", @bold}],
      [{"Use case", @bold}, {"Keywords / Phrases", @bold}],
      ["Worker profile words", phrases_for(keywords, "worker_profile")],
      ["Employer job post phrases", phrases_for(keywords, "employer_job_post")],
      ["Local-language terms", phrases_for(keywords, "local_language")],
      ["Trend words / quality signals", phrases_for(keywords, "trend_signal")]
    ]
  end

  defp phrases_for(keywords, category) do
    keywords
    |> Enum.filter(&(&1["category"] == category))
    |> Enum.map_join(", ", & &1["phrase"])
  end

  defp notes_rows do
    [
      [{"Notes / Sources", @bold}],
      ["Exported", "Generated by Data.SkillTaxonomy.XlsxExporter from live TerminusDB data."]
    ]
  end

  defp add_role_index(role_sheets, roles) do
    rows =
      [
        [{"Heeero Worker Role Differentiation Workbook — Export", @section}],
        [],
        [{"Role Tab", @bold}, {"Primary Label", @bold}, {"Status", @bold}]
      ] ++ Enum.map(roles, &[sheet_name(&1), &1["primary_name"], &1["status"]])

    index_sheet =
      XlsxWriter.new_sheet("Role Index")
      |> write_rows(rows)
      |> XlsxWriter.set_column_width(0, 28)
      |> XlsxWriter.set_column_width(1, 28)
      |> XlsxWriter.set_column_width(2, 16)

    [index_sheet | role_sheets]
  end

  # XLSX sheet names: no : \ / ? * [ ], max 31 chars.
  defp sheet_name(role) do
    base =
      role["primary_name"]
      |> String.replace(~r/[:\\\/\?\*\[\]]/, "-")

    base = if role["context"] not in [nil, ""], do: "#{base} (#{role["context"]})", else: base
    String.slice(base, 0, 31)
  end

  defp write_rows(sheet, rows) do
    rows
    |> Enum.with_index()
    |> Enum.reduce(sheet, fn {cells, row}, sheet ->
      cells
      |> Enum.with_index()
      |> Enum.reduce(sheet, fn {cell, col}, sheet -> write_cell(sheet, row, col, cell) end)
    end)
  end

  defp write_cell(sheet, _row, _col, nil), do: sheet
  defp write_cell(sheet, _row, _col, ""), do: sheet

  defp write_cell(sheet, row, col, {value, format}),
    do: XlsxWriter.write(sheet, row, col, value, format: format)

  defp write_cell(sheet, row, col, value), do: XlsxWriter.write(sheet, row, col, value)
end
