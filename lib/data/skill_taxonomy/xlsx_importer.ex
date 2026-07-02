defmodule Data.SkillTaxonomy.XlsxImporter do
  @moduledoc """
  Parses the reformed Heeero role differentiation XLSX template (see
  `design/SKILLS_TAXONOMY.md` §4 — one Role Summary header block plus
  one Term-Level Matching Detail table per role sheet; the layout
  `priv/skill_taxonomy/generate_template.exs` generates) into the same
  `%{roles:, skills:, pending_relations:, warnings:, errors:}` shape
  `Data.SkillTaxonomy.CsvImporter.parse/1` produces, so
  `Data.SkillTaxonomy.Importer.import/2` doesn't need to know which
  parser produced its input. Pure — no network. Per-sheet document
  building delegates to `Data.SkillTaxonomy.RowBuilder`, same as the
  CSV path.

  One sheet is one role. Sections are found by **row-label search**, not
  fixed row offsets — a sheet is free to have extra rows, moved
  sections, or a differently-positioned Term-Level table, since a
  contributor's copy of the template will drift from the generated
  original as they fill it in. Known non-role sheets (`"Role Index"`,
  `"Whats New"`, `"Blank Role Template"`, `"Example - Housekeeper"` —
  the fixed names the generator produces) are skipped by name; any
  other sheet is treated as a role.

  ## Known gap: no `context` (venue-tier variant) support

  Unlike `CsvImporter`, this importer has no way to represent a
  `context` variant (design doc §2's "Context-dependent variants",
  e.g. `Waiter (fine_dining)` vs. the base `Waiter`) — the template has
  no per-sheet field for it. Every role parsed here gets `context: ""`.
  Revisit if/when the template grows a Context row.

  ## Term-Level Matching Detail category mapping

  | Category (Term-Level table) | Becomes |
  |---|---|
  | `Synonym` | a `Synonym` on the role — see below |
  | `Supporting Skill` | `supporting` relation (Role -> Skill) |
  | `Related Role` | `type_of` or `sibling`, via the same narrow "parent"/"type of" `relationship_detail` heuristic design doc §2 describes — `sibling` otherwise |
  | `Hard Negative` | `hard_negative` relation |
  | `Manual Review` | `manual_review` relation |
  | `Easy Negative` | `easy_negative` relation |
  | `Exclusion` | `exclusion` relation |

  A `Synonym` row's `Local-language term` column becomes a **second**
  `Synonym` on the same role, not a translation attached to the first —
  neither the `Term` column nor the `Local-language term` column is
  assumed more canonical than the other (a role's "real" name might
  turn out to be the local-language one). Both get the sheet's own
  `Locale / Language` value, the same rough locale-inference convention
  `Data.SkillTaxonomy.Importer` already uses for stub-seeded synonyms
  (design doc §2/§10) — not a real per-term locale model.

  For every other category, `Local-language term` becomes the pending
  relation's `local_term`, which seeds the *target* role's own synonyms
  if it gets stub-created (design doc §2). `Supporting Skill` rows
  ignore it — `Skill` has no synonym/locale concept.

  A row's `Confidence` cell is used verbatim when it's exactly `"sure"`
  or `"guess"` (case/whitespace-insensitive); anything else (blank or
  unrecognized text) is treated as unspecified and falls back to the
  row default, same as a blank cell would.

  ## Role guidance — captured, not interpreted

  The `End-of-role Matching Statement` and `Category Guidance` block's
  `Expanded Detail`/`Heeero matching logic` text are prose, not raw
  taxonomy facts — same as design doc §6's `RoleGuidance` scope. Neither
  is turned into a `Role`/`RoleRelation` field, but neither is thrown
  away either: `parse/1`'s result carries a `role_guidance` list (one
  entry per sheet that had any such text) so it survives until §6's
  interpretation pipeline exists to actually use it.
  `Data.SkillTaxonomy.Importer.import/2` doesn't read this key.
  """

  alias Data.SkillTaxonomy.RowBuilder

  @non_role_sheets MapSet.new([
                     "Role Index",
                     "Whats New",
                     "Blank Role Template",
                     "Example - Housekeeper"
                   ])

  @term_categories %{
    "synonym" => :synonym,
    "supporting skill" => :supporting,
    "related role" => :related_role,
    "hard negative" => :hard_negatives,
    "manual review" => :manual_review,
    "easy negative" => :easy_negatives,
    "exclusion" => :exclusions
  }

  @section_titles MapSet.new([
                    "Category Guidance",
                    "App Keywords / Job Phrases",
                    "Notes / Sources"
                  ])

  @type role_guidance :: %{
          sheet: String.t(),
          primary: String.t() | nil,
          end_of_role_statement: String.t() | nil,
          category_guidance: %{
            String.t() => %{expanded_detail: String.t() | nil, matching_logic: String.t() | nil}
          }
        }

  @type parsed :: %{
          roles: [map()],
          skills: [map()],
          pending_relations: [RowBuilder.pending_relation()],
          role_guidance: [role_guidance()],
          warnings: [%{sheet: String.t(), message: String.t()}],
          errors: [%{sheet: String.t(), primary: String.t() | nil, message: String.t()}]
        }

  @doc """
  Parses XLSX binary content into the same shape `CsvImporter.parse/1`
  produces (plus `role_guidance`). Pure — performs no network I/O.

  Sheet-level problems (missing `Primary Role`, invalid data, duplicate
  role identity across sheets) are collected into `result.errors`; that
  sheet contributes no role/relations to the result (its guidance text,
  if any, is still captured).
  """
  @spec parse(binary()) :: {:ok, parsed()} | {:error, term()}
  def parse(xlsx_content) when is_binary(xlsx_content) do
    with {:ok, sheets} <- Spreadsheet.parse(xlsx_content, format: :binary) do
      {:ok, build_result(sheets)}
    end
  end

  defp build_result(sheets) do
    role_sheets =
      sheets
      |> Enum.reject(fn {name, _rows} -> MapSet.member?(@non_role_sheets, name) end)

    parsed_sheets = Enum.map(role_sheets, fn {name, rows} -> {name, parse_sheet(rows)} end)

    duplicate_primaries =
      parsed_sheets
      |> Enum.map(fn {_name, sheet} -> sheet.primary end)
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.frequencies()
      |> Enum.filter(fn {_primary, count} -> count > 1 end)
      |> MapSet.new(fn {primary, _count} -> primary end)

    init = %{
      roles: [],
      skills: [],
      pending_relations: [],
      role_guidance: [],
      warnings: [],
      errors: []
    }

    parsed_sheets
    |> Enum.reduce(init, &process_sheet(&1, &2, duplicate_primaries))
    |> dedupe_skills()
  end

  defp process_sheet({name, sheet}, acc, duplicate_primaries) do
    acc = add_guidance(acc, name, sheet)

    case validate_not_duplicate(sheet.primary, duplicate_primaries) do
      :ok ->
        fields = to_row_builder_fields(sheet)

        case RowBuilder.build(fields, base_role_exists?: true) do
          {:ok, built} -> merge_built(acc, built)
          {:error, message} -> add_error(acc, name, sheet.primary, message)
        end

      {:error, message} ->
        add_error(acc, name, sheet.primary, message)
    end
  end

  defp validate_not_duplicate(primary, duplicate_primaries) do
    if MapSet.member?(duplicate_primaries, primary) do
      {:error, "duplicate role identity for #{inspect(primary)}"}
    else
      :ok
    end
  end

  defp to_row_builder_fields(sheet) do
    {plain_synonyms, local_synonyms} = synonym_items(sheet.term_rows)

    %{
      primary: sheet.primary || "",
      description: sheet.description || "",
      context: "",
      locale: sheet.locale || "",
      industry: sheet.industry || "",
      confidence: "guess",
      synonyms: plain_synonyms ++ local_synonyms,
      supporting: relation_items(sheet.term_rows, :supporting),
      type_of: relation_items(sheet.term_rows, :type_of),
      sibling: relation_items(sheet.term_rows, :sibling),
      hard_negatives: relation_items(sheet.term_rows, :hard_negatives),
      easy_negatives: relation_items(sheet.term_rows, :easy_negatives),
      exclusions: relation_items(sheet.term_rows, :exclusions),
      manual_review: relation_items(sheet.term_rows, :manual_review)
    }
  end

  # Both use the same locale — RowBuilder stamps every synonym with the
  # row-level fields.locale itself, so there's no per-item locale to
  # thread through here (see design doc §2/§10 on why this is a rough
  # proxy, not a real multi-locale model).
  defp synonym_items(term_rows) do
    synonym_rows = Enum.filter(term_rows, &(&1.category_kind == :synonym))

    plain = Enum.map(synonym_rows, &%{term: &1.term, confidence: &1.confidence})

    local =
      synonym_rows
      |> Enum.filter(&(&1.local_term not in [nil, ""]))
      |> Enum.map(&%{term: &1.local_term, confidence: &1.confidence})

    {plain, local}
  end

  # Related Role rows are pre-classified into :type_of/:sibling by
  # parse_term_row/1 (the design doc §2 heuristic), so this just filters
  # on the already-resolved kind.
  defp relation_items(term_rows, kind) do
    term_rows
    |> Enum.filter(&(&1.category_kind == kind))
    |> Enum.map(fn row ->
      %{term: row.term, confidence: row.confidence}
      |> maybe_put(:notes, row.notes)
      |> maybe_put(:relationship_detail, row.relationship_detail)
      |> maybe_put(:local_term, if(kind != :supporting, do: presence(row.local_term)))
    end)
  end

  defp presence(""), do: nil
  defp presence(value), do: value

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp merge_built(acc, built) do
    %{
      acc
      | roles: acc.roles ++ [built.role],
        skills: acc.skills ++ built.skills,
        pending_relations: acc.pending_relations ++ built.relations
    }
  end

  defp add_error(acc, sheet, primary, message) do
    %{acc | errors: acc.errors ++ [%{sheet: sheet, primary: presence(primary), message: message}]}
  end

  defp add_guidance(acc, sheet_name, sheet) do
    case build_guidance(sheet_name, sheet) do
      nil -> acc
      guidance -> %{acc | role_guidance: acc.role_guidance ++ [guidance]}
    end
  end

  defp build_guidance(sheet_name, sheet) do
    statement = presence(sheet.end_of_role_statement)
    category_guidance = sheet.category_guidance

    if statement == nil and category_guidance == %{} do
      nil
    else
      %{
        sheet: sheet_name,
        primary: presence(sheet.primary),
        end_of_role_statement: statement,
        category_guidance: category_guidance
      }
    end
  end

  defp dedupe_skills(result) do
    %{result | skills: Enum.uniq_by(result.skills, & &1["name"])}
  end

  # ---- Per-sheet extraction (row-label search) ----

  defp parse_sheet(rows) do
    rows = Enum.map(rows, &normalize_row/1)

    %{
      primary: find_label(rows, "Primary Role"),
      description: find_label(rows, "Description"),
      locale: find_label(rows, "Locale / Language"),
      industry: find_label(rows, "Industry / Context"),
      end_of_role_statement: find_label(rows, "End-of-role Matching Statement"),
      term_rows: parse_term_table(rows),
      category_guidance: parse_category_guidance(rows)
    }
  end

  defp normalize_row(row) do
    Enum.map(row, fn
      cell when is_binary(cell) -> String.trim(cell)
      cell -> cell
    end)
  end

  defp find_label(rows, label) do
    Enum.find_value(rows, fn
      [^label, value | _] -> value
      _ -> nil
    end)
  end

  # Consumes rows after the header until a recognized next-section title
  # (see @section_titles) — anything else in between (a blank separator
  # row, the "(Category: ...)" guidance parenthetical, stray text) is
  # skipped rather than treated as "end of table", since only an
  # explicit section boundary reliably means the table is actually done.
  defp parse_term_table(rows) do
    case find_term_header_index(rows) do
      nil ->
        []

      header_index ->
        rows
        |> Enum.drop(header_index + 1)
        |> Enum.reduce_while([], fn row, acc ->
          cond do
            section_title?(row) -> {:halt, acc}
            (term_row = parse_term_row(row)) != :not_a_term_row -> {:cont, [term_row | acc]}
            true -> {:cont, acc}
          end
        end)
        |> Enum.reverse()
    end
  end

  defp section_title?([title | _]) when is_binary(title),
    do: MapSet.member?(@section_titles, title)

  defp section_title?(_row), do: false

  defp find_term_header_index(rows) do
    Enum.find_index(rows, &match?(["Category", "Term" | _], &1))
  end

  defp parse_term_row(row) do
    with [category, term | _] <- pad(row, 6),
         category_kind when not is_nil(category_kind) <- category_kind(category),
         true <- is_binary(term) and term != "" do
      [_category, _term, local_term, relationship_detail, notes, confidence] = pad(row, 6)

      %{
        category_kind: resolve_related_role_kind(category_kind, relationship_detail),
        term: term,
        local_term: presence(local_term),
        relationship_detail: presence(relationship_detail),
        notes: presence(notes),
        confidence: normalize_confidence(confidence)
      }
    else
      _ -> :not_a_term_row
    end
  end

  defp pad(row, length) do
    row
    |> Enum.take(length)
    |> Kernel.++(List.duplicate(nil, length))
    |> Enum.take(length)
  end

  defp category_kind(category) when is_binary(category) do
    Map.get(@term_categories, category |> String.downcase() |> String.trim())
  end

  defp category_kind(_category), do: nil

  # design doc §2 "relationship_detail — nuance without a bigger enum":
  # an unambiguous "parent"/"type of" signal -> type_of, sibling otherwise.
  defp resolve_related_role_kind(:related_role, relationship_detail) do
    text = (relationship_detail || "") |> String.downcase()

    if String.contains?(text, "parent") or String.contains?(text, "type of") do
      :type_of
    else
      :sibling
    end
  end

  defp resolve_related_role_kind(kind, _relationship_detail), do: kind

  defp normalize_confidence(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "sure" -> "sure"
      "guess" -> "guess"
      _ -> "guess"
    end
  end

  defp normalize_confidence(_value), do: "guess"

  defp parse_category_guidance(rows) do
    case find_guidance_header_index(rows) do
      nil ->
        %{}

      header_index ->
        rows
        |> Enum.drop(header_index + 1)
        |> Enum.take_while(&guidance_row?/1)
        |> Enum.reduce(%{}, &put_guidance_entry/2)
    end
  end

  defp find_guidance_header_index(rows) do
    Enum.find_index(rows, &match?(["Category", "Expanded Detail" | _], &1))
  end

  defp guidance_row?([category | _]) when is_binary(category) and category != "", do: true
  defp guidance_row?(_row), do: false

  defp put_guidance_entry(row, acc) do
    [category, expanded_detail, matching_logic] = pad(row, 3)
    expanded_detail = presence(expanded_detail)
    matching_logic = presence(matching_logic)

    if expanded_detail == nil and matching_logic == nil do
      acc
    else
      Map.put(acc, category, %{expanded_detail: expanded_detail, matching_logic: matching_logic})
    end
  end
end
