# One-off reformatting of "Heeero Role Differentiation Scope Bangkok
# 20260702v2.xlsx" (27 hand/AI-authored role sheets from colleagues, in an
# independently-evolved 8-column layout) into the v3 template shape
# `Data.SkillTaxonomy.XlsxImporter.parse/1` reads, so it can go through the
# normal import pipeline rather than a bespoke one-off parser.
#
# NOT a general-purpose converter — this hardcodes the source file's exact
# column layout, discovered by inspection, not derived from any shared
# schema. Re-run with `mix run priv/skill_taxonomy/reformat_bangkok_scope.exs`.
#
# Source layout (discovered, not documented anywhere else):
#   - Non-role sheets to skip: Role Index, Competitive Landscape (Bangkok),
#     Client Source Validation, Blank Role Template, Conventions & Legend,
#     Relationship Matrix (DEFERRED), Scope Decision Summary.
#   - "7-Point Role Proforma" block: rows shaped
#     [Point, Category, Entry, Expanded Detail, Thai wording, Heeero logic, Confidence],
#     Category label in column 1 (not column 0, unlike v3) — used only for
#     description/locale/industry/end-of-role-statement; everything else in
#     this block is either redundant with or formula-derived from the term
#     table below it (their own "single source of truth" rule).
#   - "Term-Level Matching Detail" table: rows shaped
#     [Category, Item / Term, Thai sample, Relationship / Match status,
#      Matching note, Confidence, Negative Rationale].
#
# Transformations applied (see chat discussion for the reasoning):
#   - primary_name comes from the term table's own "Primary Role" row, not
#     the sheet tab name — 12 of 27 sheets differ (e.g. tab "Sommelier" ->
#     primary "Wine Sommelier"), matching the source's own Scope Decision
#     Summary "Primary Label" column.
#   - "Primary Role" term-rows are dropped (descriptive of the sheet itself,
#     not a relationship).
#   - confidence "conditional" -> "guess" (closest fit to the existing
#     sure/guess model; the actual condition stays verbatim in the note).
#   - "Negative Rationale" (their controlled-vocabulary tag, e.g.
#     "adjacent-function") has no dedicated field downstream — folded into
#     Relationship detail as "<status> (<rationale>)" rather than dropped.
#   - Exclusion rows whose term is "None"/blank are dropped (every sheet's
#     Exclusion row is "None" in this dataset — nothing to import there).
#   - Related Role rows are passed through verbatim, NOT forced to one
#     classification — XlsxImporter's existing parent/type_of heuristic
#     (unchanged) correctly promotes the ~11 genuine "parent"-worded rows
#     and leaves the rest as sibling; a full-dataset scan confirmed no
#     false triggers from this vocabulary before relying on that.
#   - No "Manual Review" category exists in the source; two sheets'
#     Exclusion notes mention manual-review/low-confidence in passing
#     (general commentary, not tagged to a specific term) — listed in the
#     output's "Reformat Notes" sheet for human follow-up, not guessed at.

alias XlsxWriter

source_path = Path.expand("../../Heeero Role Differentiation Scope Bangkok 20260702v2.xlsx", __DIR__)

out_path =
  Path.expand(
    "../../Heeero Role Differentiation Scope Bangkok 20260702v2 - Reformatted.xlsx",
    __DIR__
  )

non_role_sheets =
  MapSet.new([
    "Role Index",
    "Competitive Landscape (Bangkok)",
    "Client Source Validation",
    "Blank Role Template",
    "Conventions & Legend",
    "Relationship Matrix (DEFERRED)",
    "Scope Decision Summary"
  ])

bold = [:bold]
section = [:bold, {:font_size, 12}, {:bg_color, "#D9E1F2"}]
subtle = [{:font_color, "#666666"}, :italic]

defmodule Builder do
  def write_rows(sheet, rows, start_row \\ 0) do
    rows
    |> Enum.with_index(start_row)
    |> Enum.reduce(sheet, fn {cells, row}, sheet ->
      cells
      |> Enum.with_index()
      |> Enum.reduce(sheet, fn {cell, col}, sheet -> write_cell(sheet, row, col, cell) end)
    end)
  end

  defp write_cell(sheet, _row, _col, nil), do: sheet
  defp write_cell(sheet, _row, _col, ""), do: sheet
  defp write_cell(sheet, row, col, {value, format}), do: XlsxWriter.write(sheet, row, col, value, format: format)
  defp write_cell(sheet, row, col, value), do: XlsxWriter.write(sheet, row, col, value)
end

defmodule Extract do
  def blank?(nil), do: true
  def blank?(""), do: true
  def blank?(v) when is_binary(v), do: String.trim(v) == ""
  def blank?(_), do: false

  # Proforma rows are [Point, Category, Entry, Expanded Detail, Thai, Heeero
  # logic, Confidence] — Category label lives in column 1 here (unlike v3's
  # column 0). field_index picks which column to read: 2 (Entry) for
  # Locale/Industry/Statement, whose real value lives there; 3 (Expanded
  # Detail) for Primary Role, since its Entry column just repeats the label
  # while Expanded Detail holds the actual descriptive text.
  def find_proforma_field(rows, category, field_index) do
    Enum.find_value(rows, fn row ->
      if Enum.at(row, 1) == category do
        value = Enum.at(row, field_index)
        if blank?(value), do: nil, else: value
      end
    end)
  end

  def term_header_index(rows) do
    Enum.find_index(rows, &match?(["Category", "Item / Term" | _], &1))
  end

  def term_rows(rows) do
    case term_header_index(rows) do
      nil ->
        []

      idx ->
        rows
        |> Enum.drop(idx + 1)
        |> Enum.take_while(fn row -> match?([c | _] when is_binary(c) and c != "", row) end)
    end
  end

  def normalize_confidence("conditional"), do: "guess"
  def normalize_confidence(value), do: value

  def combine_relationship_detail(status, rationale) do
    cond do
      blank?(status) and blank?(rationale) -> nil
      blank?(rationale) -> status
      blank?(status) -> "(#{rationale})"
      true -> "#{status} (#{rationale})"
    end
  end

  def reformat_term_row([category, term, thai, status, note, confidence, rationale | _]) do
    cond do
      category == "Primary Role" ->
        nil

      category == "Exclusion" and (blank?(term) or String.downcase(term) == "none") ->
        nil

      true ->
        [
          category,
          term,
          if(blank?(thai), do: nil, else: thai),
          combine_relationship_detail(status, rationale),
          if(blank?(note), do: nil, else: note),
          normalize_confidence(confidence)
        ]
    end
  end

  def manual_review_mentions(rows) do
    rows
    |> term_rows()
    |> Enum.filter(fn row ->
      text = row |> Enum.filter(&is_binary/1) |> Enum.join(" | ") |> String.downcase()

      String.contains?(text, "manual review") or String.contains?(text, "manual-review") or
        String.contains?(text, "low-confidence") or String.contains?(text, "low confidence")
    end)
  end

  # Proforma category labels -> v3 Category Guidance labels. Only the six
  # that have a v3 Category Guidance home; Primary Role/Locale/Industry/
  # End-of-role Statement aren't categories in that block, and there's no
  # Manual Review data in the source at all.
  @proforma_to_guidance_category [
    {"Synonyms", "Synonyms"},
    {"Supporting Skills - The Cloud", "Supporting Skills"},
    {"Type-of / Related Roles", "Related Roles"},
    {"Hard Negatives", "Hard Negatives"},
    {"Easy Negatives", "Easy Negatives"},
    {"Exclusions", "Exclusions"}
  ]

  # Every point row in the 7-Point Proforma carries its own "Heeero
  # matching logic" (and "Expanded Detail") commentary — real category-level
  # guidance the source's own Conventions & Legend describes as feeding
  # matching-rule design. v3's Category Guidance block exists for exactly
  # this; the first version of this script dropped it entirely.
  def category_guidance_rows(rows) do
    for {source_category, v3_category} <- @proforma_to_guidance_category,
        expanded_detail = find_proforma_field(rows, source_category, 3),
        heeero_logic = find_proforma_field(rows, source_category, 5),
        not (blank?(expanded_detail) and blank?(heeero_logic)) do
      [v3_category, expanded_detail, heeero_logic]
    end
  end

  @keyword_use_cases [
    "Worker profile words",
    "Employer job post phrases",
    "Thailand-facing terms",
    "Trend words / quality signals"
  ]

  def app_keyword_rows(rows) do
    for use_case <- @keyword_use_cases,
        phrases = Enum.find_value(rows, fn row -> if Enum.at(row, 0) == use_case, do: Enum.at(row, 1) end),
        not blank?(phrases) do
      label = if use_case == "Thailand-facing terms", do: "Local-language terms", else: use_case
      [label, phrases]
    end
  end

  def notes_source_rows(rows) do
    contributor = Enum.find_value(rows, fn row -> if Enum.at(row, 0) == "Contributor guide", do: Enum.at(row, 1) end)

    sources =
      Enum.find_value(rows, fn row ->
        if Enum.at(row, 0) == "Role research sources / use rule", do: Enum.at(row, 1)
      end)

    [["Contributor guide (source)", contributor], ["Sources / use rule (source)", sources]]
    |> Enum.reject(fn [_, v] -> blank?(v) end)
  end
end

{:ok, sheets} = Spreadsheet.parse(source_path, format: :filename)

role_sheet_names =
  sheets
  |> Enum.map(&elem(&1, 0))
  |> Enum.reject(&MapSet.member?(non_role_sheets, &1))

roles =
  for {name, rows} <- sheets, name in role_sheet_names do
    primary =
      rows
      |> Extract.term_rows()
      |> Enum.find_value(fn
        ["Primary Role", term | _] -> term
        _ -> nil
      end)

    %{
      tab_name: name,
      primary: primary,
      description: Extract.find_proforma_field(rows, "Primary Role", 3),
      locale: Extract.find_proforma_field(rows, "Locale / Language", 2),
      industry: Extract.find_proforma_field(rows, "Industry / Context", 2),
      statement: Extract.find_proforma_field(rows, "End-of-role Matching Statement", 2),
      term_rows:
        rows
        |> Extract.term_rows()
        |> Enum.map(&Extract.reformat_term_row/1)
        |> Enum.reject(&is_nil/1),
      category_guidance_rows: Extract.category_guidance_rows(rows),
      app_keyword_rows: Extract.app_keyword_rows(rows),
      notes_source_rows: Extract.notes_source_rows(rows),
      manual_review_mentions: Extract.manual_review_mentions(rows)
    }
  end

IO.puts("#{length(roles)} role sheets reformatted")

# ---- Sheet: Role Index ----

role_index_rows =
  [
    [{"Heeero Role Differentiation — Bangkok Scope (Reformatted)", section}],
    [],
    [{"Source Tab", bold}, {"Primary Label", bold}, {"Term Rows", bold}]
  ] ++
    Enum.map(roles, &[&1.tab_name, &1.primary, length(&1.term_rows)])

role_index =
  XlsxWriter.new_sheet("Role Index")
  |> Builder.write_rows(role_index_rows)
  |> XlsxWriter.set_column_width(0, 28)
  |> XlsxWriter.set_column_width(1, 28)
  |> XlsxWriter.set_column_width(2, 12)

# ---- One sheet per role, v3 shape ----

used_names = MapSet.new(["Role Index"])

{role_sheets, _used} =
  Enum.reduce(roles, {[], used_names}, fn role, {acc, used} ->
    base =
      (role.primary || role.tab_name)
      |> String.replace(~r/[:\\\/\?\*\[\]]/, "-")
      |> String.slice(0, 28)

    name = if MapSet.member?(used, base), do: String.slice(base, 0, 25) <> "-#{length(acc)}", else: base

    rows =
      [
        [{"Heeero Role Differentiation: #{role.primary}", section}],
        [],
        [{"Role Summary", bold}],
        ["Primary Role", role.primary],
        ["Description", role.description],
        ["Locale / Language", role.locale],
        ["Industry / Context", role.industry],
        ["End-of-role Matching Statement", role.statement],
        [],
        [
          {"Term-Level Matching Detail", bold},
          "",
          "",
          "",
          "",
          {"Reformatted from the source Bangkok scope workbook's own Term-Level table — see Whats New.",
           subtle}
        ],
        [
          {"Category", bold},
          {"Term", bold},
          {"Local-language term", bold},
          {"Relationship detail", bold},
          {"Matching note", bold},
          {"Confidence", bold}
        ]
      ] ++
        role.term_rows ++
        [
          [],
          [
            {"Category Guidance", bold},
            "",
            {"Carried over from the source's 7-Point Proforma \"Expanded Detail\"/\"Heeero matching logic\" columns.",
             subtle}
          ],
          [{"Category", bold}, {"Expanded Detail", bold}, {"Heeero matching logic", bold}]
        ] ++
        role.category_guidance_rows ++
        [
          [],
          [{"App Keywords / Job Phrases", bold}],
          [{"Use case", bold}, {"Keywords / Phrases", bold}]
        ] ++
        role.app_keyword_rows ++
        [
          [],
          [{"Notes / Sources", bold}]
        ] ++ role.notes_source_rows

    sheet =
      XlsxWriter.new_sheet(name)
      |> Builder.write_rows(rows)
      |> XlsxWriter.set_column_width(0, 22)
      |> XlsxWriter.set_column_width(1, 32)
      |> XlsxWriter.set_column_width(2, 24)
      |> XlsxWriter.set_column_width(3, 32)
      |> XlsxWriter.set_column_width(4, 45)
      |> XlsxWriter.set_column_width(5, 14)

    {[sheet | acc], MapSet.put(used, name)}
  end)

role_sheets = Enum.reverse(role_sheets)

# ---- Sheet: Reformat Notes ----

manual_review_flags =
  for role <- roles, mention <- role.manual_review_mentions do
    [role.primary, Enum.at(mention, 0), Enum.at(mention, 1), Enum.at(mention, 4)]
  end

notes_rows =
  [
    [{"Reformat Notes — Bangkok Scope Import", section}],
    [],
    [
      {"What this is", bold},
      "This workbook was mechanically reformatted from \"Heeero Role Differentiation Scope Bangkok 20260702v2.xlsx\" into the standard v3 template shape (priv/skill_taxonomy/reformat_bangkok_scope.exs), so it could go through the normal XlsxImporter/Importer pipeline. See that script for the exact column mapping."
    ],
    [
      "Confidence normalization",
      "The source used a three-value vocabulary (sure / conditional / guess). \"conditional\" was mapped to \"guess\" — the closest fit to this app's two-value model. The actual condition text is preserved verbatim in each row's Matching note, so nothing is lost, just relabeled."
    ],
    [
      "Negative Rationale column",
      "The source's Hard/Easy Negative rows carried an extra controlled-vocabulary tag (e.g. \"adjacent-function\", \"seniority-mismatch\") with no equivalent field downstream. Folded into Relationship detail as \"<status> (<tag>)\" rather than dropped."
    ],
    [
      "Related Role classification",
      "Passed through verbatim, not forced to one classification. XlsxImporter's existing parent/type_of heuristic (unchanged) correctly promotes the small number of genuinely parent-worded rows (e.g. \"Parent category\", \"Parent/general role\") to type_of and leaves the rest as sibling."
    ],
    [
      "No Manual Review category in the source",
      "The source has no structural Manual Review category. The rows below are every place its own notes mention manual review / low-confidence handling in passing — none tag a specific term, so none were auto-reclassified. Review and manually flag the relevant Hard Negative relations via RoleLive if warranted."
    ],
    [
      "Category Guidance / App Keywords / Notes-Sources carried over",
      "The source's 7-Point Proforma \"Expanded Detail\"/\"Heeero matching logic\" text (per category, per role), its App Keywords / Job Phrases section, and its Contributor guide / research-sources text are all reproduced on each role sheet below, in the matching v3 template sections. Category Guidance flows into XlsxImporter's role_guidance on parse — captured, not yet persisted anywhere (design doc §6 RoleGuidance isn't built). App Keywords and Notes/Sources aren't parsed by anything yet (a pre-existing gap, not specific to this file) — kept here so the text isn't lost before that's built."
    ],
    [
      "What's known to NOT carry over",
      "Two things have no home in the v3 template at all: the source's per-field Thai translations of Locale/Industry/End-of-role Statement (only per-term local-language text is modeled), and the \"Negative Rationale\" controlled-vocabulary tags as separately queryable data (folded into Relationship detail as free text instead, per the note above)."
    ],
    [],
    # Deliberately not "Primary Role" as the first header cell — that
    # exact two-cell shape is what XlsxImporter's row-label search looks
    # for to find a *role* sheet's Primary Role value; reusing it here
    # produced a bogus 28th "role" the first time this ran.
    [{"Affected Role", bold}, {"Row Category", bold}, {"Term", bold}, {"Note text", bold}]
  ] ++ manual_review_flags

notes_sheet =
  # Named "Whats New" (not "Reformat Notes") deliberately — it's already
  # in XlsxImporter's non-role sheet skip list, so this stays skipped
  # without needing a change to the general-purpose importer for a
  # one-off file's sheet name.
  XlsxWriter.new_sheet("Whats New")
  |> Builder.write_rows(notes_rows)
  |> XlsxWriter.set_column_width(0, 45)
  |> XlsxWriter.set_column_width(1, 78)

{:ok, content} = XlsxWriter.generate([role_index] ++ role_sheets ++ [notes_sheet])
File.write!(out_path, content)
IO.puts("wrote #{out_path}")
