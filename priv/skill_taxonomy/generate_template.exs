# Generates "Heeero Role Differentiation Template v2.xlsx" in the project
# root. Re-run with `mix run priv/skill_taxonomy/generate_template.exs`
# whenever the collection shape changes — see design/SKILLS_TAXONOMY.md §4
# and the "Whats New" sheet below for what this reformulates from the
# original "Heeero Role Differentiation Template Draft.xlsx".

alias XlsxWriter

bold = [:bold]
section = [:bold, {:font_size, 12}, {:bg_color, "#D9E1F2"}]
subtle = [{:font_color, "#666666"}, :italic]

defmodule TemplateBuilder do
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

  def set_widths(sheet, widths) do
    widths
    |> Enum.with_index()
    |> Enum.reduce(sheet, fn {w, col}, sheet -> XlsxWriter.set_column_width(sheet, col, w) end)
  end
end

# ---- Sheet 1: Role Index — same shape as the original, ready to continue from ----

role_index_rows =
  [
    [{"Heeero Worker Role Differentiation Workbook", section}],
    [],
    [
      {"Role #", bold},
      {"Role Tab", bold},
      {"Primary Label", bold},
      {"Status", bold},
      {"Notes", bold}
    ],
    [1, "Hotel Housekeeper", "Hotel Room Attendant", "Completed first-pass", "Carried over from the original workbook"]
  ] ++
    for n <- 2..25 do
      [n, "Role #{n} - TBC", "", "To build", "One tab per role"]
    end ++
    [
      [],
      [{"Recommended structure", bold}, "One worksheet tab per role, with a 7-point summary, term-level matching rows, keywords/phrases, and an end-of-role matching statement."]
    ]

role_index =
  XlsxWriter.new_sheet("Role Index")
  |> TemplateBuilder.write_rows(role_index_rows)
  |> TemplateBuilder.set_widths([10, 22, 28, 20, 45])

# ---- Sheet 2: Blank Role Template — the reformulated shape ----

blank_rows = [
  [{"Heeero Role Differentiation: [Role Name]", section}],
  ["", "[Primary Label]"],
  [{"7-Point Role Proforma", bold}],
  [
    {"Point", bold},
    {"Category", bold},
    {"Entry", bold},
    {"Expanded Detail", bold},
    {"Local wording (e.g. Thai)", bold},
    {"Heeero matching logic", bold},
    {"Confidence", bold}
  ],
  [1, "Primary Role"],
  [2, "Synonyms"],
  [3, "Supporting Skills - The Cloud"],
  [4, "Type-of / Related Roles"],
  [5, "Hard Negatives"],
  [6, "Easy Negatives"],
  [7, "Exclusions"],
  ["A", "Locale / Language", "en / [local]"],
  ["B", "Industry / Context"],
  ["C", "End-of-role Matching Statement", "", "I am a verified [primary role] with [supporting skills] experience - but I should not automatically be matched to [hard negatives] roles."],
  [
    "D",
    "Manual Review / Low-Confidence Matches",
    "",
    "Roles that are related but risky to auto-match - flag for human review or a reduced-confidence match rather than a hard exclusion.",
    "",
    {"New in this version - see the \"Whats New\" tab.", subtle}
  ],
  [],
  [{"Term-Level Matching Detail", bold}, "", "", "", "", "", {"Primary data source - fill this out fully even if it repeats the summary above.", subtle}],
  [
    {"Category", bold},
    {"Item / Term", bold},
    {"Local-language sample", bold},
    {"Relationship / Match status", bold},
    {"Matching note", bold},
    {"Confidence", bold}
  ],
  [{"(Primary Role | Synonym | Supporting Skill | Related Role | Hard Negative | Manual Review | Easy Negative | Exclusion)", subtle}],
  [],
  [{"App Keywords / Job Phrases", bold}],
  [{"Use case", bold}, {"Keywords / Phrases", bold}],
  ["Worker profile words"],
  ["Employer job post phrases"],
  ["Local-language terms"],
  ["Trend words / quality signals"],
  [],
  [{"Notes / Sources", bold}],
  ["Contributor guide", "Based on the Heeero skill sample guide - primary role, synonyms, supporting skills, related roles, hard negatives, easy negatives, exclusions, and tagging."],
  ["Local wording", "Local-language samples are a first-pass; validate with local operators before production use."],
  ["Use rule", "This is a first-pass matching design document, not a legal, HR or regulatory classification."]
]

blank_template =
  XlsxWriter.new_sheet("Blank Role Template")
  |> TemplateBuilder.write_rows(blank_rows)
  |> TemplateBuilder.set_widths([8, 30, 30, 45, 28, 45, 12])

# ---- Sheet 3: Whats New — explains the delta from the original workbook ----

whats_new_rows = [
  [{"What changed from the original workbook", section}],
  [],
  [{"Change", bold}, {"Why", bold}],
  [
    "Term-Level Matching Detail is now the primary data source, not just a recap.",
    "It already carries per-term notes, local-language terms, and confidence that the summary rows can't - this is the shape that maps directly onto how each relationship gets stored."
  ],
  [
    "New row D: Manual Review / Low-Confidence Matches.",
    "The Hotel Housekeeper sheet already needed this bucket in practice (private home maid, nanny, elder-care assistant, etc.) - roles that are related but risky to auto-match, without being a hard exclusion. Previously there was no place to put that distinct from Hard Negatives or Exclusions."
  ],
  [
    "Expanded Detail and Heeero matching logic are treated as guidance for whoever writes the matching rules, not stored per-role data.",
    "These are genuinely valuable (e.g. \"match only when X and Y are present\") but they're prose describing a rule, not a fact about one role pair - keep writing them, they inform how the matching logic actually gets built."
  ],
  [
    "Everything else (Primary Role, Synonyms, Supporting Skills, Related Roles, Hard/Easy Negatives, Exclusions, Locale/Industry, End-of-role Statement, App Keywords) is unchanged.",
    "The original shape already matched closely - most of this template is the same as what you've been using."
  ]
]

whats_new =
  XlsxWriter.new_sheet("Whats New")
  |> TemplateBuilder.write_rows(whats_new_rows)
  |> TemplateBuilder.set_widths([55, 70])

{:ok, content} = XlsxWriter.generate([role_index, blank_template, whats_new])

out_path = Path.expand("../../Heeero Role Differentiation Template v2.xlsx", __DIR__)
File.write!(out_path, content)
IO.puts("wrote #{out_path}")
