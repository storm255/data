# Generates "Heeero Role Differentiation Template v3.xlsx" in the project
# root. Re-run with `mix run priv/skill_taxonomy/generate_template.exs`
# whenever the collection shape changes — see design/SKILLS_TAXONOMY.md §4
# and the "Whats New" sheet below for what this reformulates from the
# original "Heeero Role Differentiation Template Draft.xlsx" (v1) and the
# intermediate "...v2.xlsx".

alias XlsxWriter

bold = [:bold]
section = [:bold, {:font_size, 12}, {:bg_color, "#D9E1F2"}]
subtle = [{:font_color, "#666666"}, :italic]
input = [{:bg_color, "#FFFFCC"}]
legend = [{:bg_color, "#FFFFCC"}, :italic]

# Wraps a cell value so it renders with the light-yellow "input" background —
# used on every cell a contributor is meant to type into (as opposed to
# labels/headers/guidance text the template already supplies). An empty
# string still gets the highlight (via write_blank) so an intentionally-blank
# input cell is visibly a fillable spot, not just absent.
inp = fn
  "" -> {:blank, input}
  value -> {value, input}
end

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
  defp write_cell(sheet, row, col, {:blank, format}), do: XlsxWriter.write_blank(sheet, row, col, format: format)
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

# ---- Sheet 2: Example: Hotel Housekeeper — a filled-in worked example, same
# shape as the blank template, so a reader sees what "good" looks like before
# they hit an empty form. Content is illustrative (a first pass, per the
# Notes / Sources section below), not a claim of production-verified data.
#
# Every cell a contributor would actually type (as opposed to a template
# label/header) carries the light-yellow "input" background — see the
# `inp` helper above and the legend row below the title.

example_rows = [
  [{"Heeero Role Differentiation: Hotel Housekeeper", section}],
  [{"Light yellow cells = contributor input. Everything else is a template label or guidance.", legend}],
  [],
  [{"Role Summary", bold}],
  ["Primary Role", inp.("Hotel Housekeeper")],
  [
    "Description",
    inp.(
      "Cleans and services hotel guest rooms to brand/franchise standards - making beds, restocking amenities, and reporting maintenance issues."
    )
  ],
  ["Locale / Language", inp.("en / th")],
  ["Industry / Context", inp.("Hospitality / Hotel Operations / Housekeeping")],
  [
    "End-of-role Matching Statement",
    inp.(
      "I am a verified Hotel Housekeeper with guest room cleaning and turndown service experience - but I should not automatically be matched to Domestic Maid, Nanny, or Elder-Care Assistant roles."
    )
  ],
  [],
  [
    {"Term-Level Matching Detail", bold},
    "",
    "",
    "",
    "",
    {"The single source of relationship data - every synonym, skill, related role, negative, and exclusion is one row here. Nothing else repeats it.", subtle}
  ],
  [
    {"Category", bold},
    {"Term", bold},
    {"Local-language term", bold},
    {"Relationship detail", bold},
    {"Matching note", bold},
    {"Confidence", bold}
  ],
  [
    inp.("Synonym"),
    inp.("Hotel Room Attendant"),
    inp.("แม่บ้านโรงแรม"),
    inp.(""),
    inp.("Most common formal title, used interchangeably"),
    inp.("sure")
  ],
  [
    inp.("Synonym"),
    inp.("Room Attendant"),
    inp.(""),
    inp.(""),
    inp.("Shortened form widely used in job postings"),
    inp.("sure")
  ],
  [inp.("Synonym"), inp.("Housekeeping Attendant"), inp.(""), inp.(""), inp.(""), inp.("guess")],
  [inp.("Supporting Skill"), inp.("Guest room cleaning"), inp.(""), inp.(""), inp.("Core daily task"), inp.("sure")],
  [
    inp.("Supporting Skill"),
    inp.("Bed making / turndown service"),
    inp.(""),
    inp.(""),
    inp.(""),
    inp.("sure")
  ],
  [
    inp.("Supporting Skill"),
    inp.("Linen and amenity restocking"),
    inp.(""),
    inp.(""),
    inp.(""),
    inp.("sure")
  ],
  [
    inp.("Supporting Skill"),
    inp.("Use of housekeeping trolley and chemicals"),
    inp.(""),
    inp.(""),
    inp.("Safety-relevant"),
    inp.("sure")
  ],
  [
    inp.("Related Role"),
    inp.("Housekeeping Staff"),
    inp.(""),
    inp.("parent category"),
    inp.("Broader department grouping"),
    inp.("sure")
  ],
  [
    inp.("Related Role"),
    inp.("Public Area Attendant"),
    inp.(""),
    inp.("sibling role"),
    inp.("Same level, different zone - lobby/corridors vs guest rooms"),
    inp.("sure")
  ],
  [
    inp.("Related Role"),
    inp.("Turndown Attendant"),
    inp.(""),
    inp.("related specialist, evening-specific"),
    inp.("Same core skill, narrower shift/task scope"),
    inp.("guess")
  ],
  [
    inp.("Related Role"),
    inp.("Laundry Attendant"),
    inp.(""),
    inp.("related specialist, different workflow"),
    inp.("Shares linen handling but not room servicing"),
    inp.("guess")
  ],
  [
    inp.("Hard Negative"),
    inp.("Domestic Maid"),
    inp.("แม่บ้านบ้านส่วนตัว"),
    inp.("do not auto-match"),
    inp.("Private home work differs from hotel room turnover - different employer relationship and standards"),
    inp.("sure")
  ],
  [
    inp.("Hard Negative"),
    inp.("Waitstaff"),
    inp.(""),
    inp.("do not auto-match"),
    inp.("Different department, no meaningful skill overlap"),
    inp.("sure")
  ],
  [
    inp.("Manual Review"),
    inp.("Nanny"),
    inp.(""),
    inp.("requires human check"),
    inp.("Related caregiving skills sometimes claimed alongside housekeeping but should not auto-match"),
    inp.("sure")
  ],
  [
    inp.("Manual Review"),
    inp.("Elder-Care Assistant"),
    inp.(""),
    inp.("requires human check"),
    inp.(""),
    inp.("guess")
  ],
  [inp.("Easy Negative"), inp.("Landscaping"), inp.(""), inp.(""), inp.("Unrelated skill set"), inp.("sure")],
  [inp.("Exclusion"), inp.("Chef"), inp.(""), inp.(""), inp.("Culinary role, no overlap"), inp.("sure")],
  [],
  [
    {"Category Guidance", bold},
    "",
    {"Optional - informs matching-rule design, not stored as role data. See \"Whats New\".", subtle}
  ],
  [{"Category", bold}, {"Expanded Detail", bold}, {"Heeero matching logic", bold}],
  [
    "Synonyms",
    inp.("Alternate titles used for this exact role."),
    inp.("Match on any listed synonym at equal weight to the primary label.")
  ],
  [
    "Supporting Skills",
    inp.("Skills that indicate genuine capability in the role."),
    inp.("Boost match confidence when 2+ supporting skills are present on a worker profile.")
  ],
  [
    "Related Roles",
    inp.("Roles that share meaningful overlap but are not identical."),
    inp.("Suggest as adjacent matches, weighted by relationship detail (parent > sibling > specialist).")
  ],
  [
    "Hard Negatives",
    inp.("Roles that look similar on paper but must never be auto-matched."),
    inp.("Block automatic matching outright; require explicit worker/employer confirmation.")
  ],
  [
    "Manual Review",
    inp.("Related but sensitive roles (e.g. in-home care) needing a human check."),
    inp.("Flag for reviewer sign-off before surfacing the match.")
  ],
  [
    "Easy Negatives",
    inp.("Roles with no meaningful overlap."),
    inp.("Used only to sanity-check the model; never surfaced as a near-match.")
  ],
  [
    "Exclusions",
    inp.("Explicitly out of scope for this role's matching."),
    inp.("Filtered out before any scoring happens.")
  ],
  [],
  [{"App Keywords / Job Phrases", bold}],
  [{"Use case", bold}, {"Keywords / Phrases", bold}],
  ["Worker profile words", inp.("room cleaning, turndown, housekeeping, hotel experience, guest rooms")],
  [
    "Employer job post phrases",
    inp.("housekeeping attendant needed, daily room servicing, hotel room attendant vacancy")
  ],
  ["Local-language terms", inp.("แม่บ้านโรงแรม, พนักงานทำความสะอาดห้องพัก")],
  ["Trend words / quality signals", inp.("5-star hotel experience, brand standard trained, fast turnaround")],
  [],
  [{"Notes / Sources", bold}],
  [
    "Contributor guide",
    "Carried over and expanded from the original Heeero skill sample guide's Hotel Housekeeper worksheet."
  ],
  ["Local wording", "Local-language samples are a first-pass; validate with local operators before production use."],
  ["Use rule", "This is a first-pass matching design document, not a legal, HR or regulatory classification."]
]

example_sheet =
  XlsxWriter.new_sheet("Example - Housekeeper")
  |> TemplateBuilder.write_rows(example_rows)
  |> TemplateBuilder.set_widths([22, 32, 24, 32, 45, 14])

# ---- Sheet 3: Blank Role Template — one table for all relationship data ----

blank_term_rows = for _ <- 1..15, do: [inp.(""), inp.(""), inp.(""), inp.(""), inp.(""), inp.("")]

blank_rows =
  [
    [{"Heeero Role Differentiation: [Role Name]", section}],
    [{"Light yellow cells = your input. Everything else is a template label or guidance.", legend}],
    [],
    [{"Role Summary", bold}],
    ["Primary Role", inp.("")],
    ["Description", inp.("")],
    ["Locale / Language", inp.("")],
    ["Industry / Context", inp.("")],
    ["End-of-role Matching Statement", inp.("")],
    [],
    [
      {"Term-Level Matching Detail", bold},
      "",
      "",
      "",
      "",
      {"The single source of relationship data - every synonym, skill, related role, negative, and exclusion is one row here. Nothing else repeats it.", subtle}
    ],
    [
      {"Category", bold},
      {"Term", bold},
      {"Local-language term", bold},
      {"Relationship detail", bold},
      {"Matching note", bold},
      {"Confidence", bold}
    ],
    [
      {"(Category: Synonym | Supporting Skill | Related Role | Hard Negative | Manual Review | Easy Negative | Exclusion. Relationship detail: free text - e.g. \"parent category\", \"sibling role\", \"related specialist, evening-specific\", \"do not auto-match\".)",
       subtle}
    ]
  ] ++
    blank_term_rows ++
    [
      [],
      [
        {"Category Guidance", bold},
        "",
        {"Optional - informs matching-rule design, not stored as role data. See \"Whats New\".", subtle}
      ],
      [{"Category", bold}, {"Expanded Detail", bold}, {"Heeero matching logic", bold}],
      ["Synonyms", inp.(""), inp.("")],
      ["Supporting Skills", inp.(""), inp.("")],
      ["Related Roles", inp.(""), inp.("")],
      ["Hard Negatives", inp.(""), inp.("")],
      ["Manual Review", inp.(""), inp.("")],
      ["Easy Negatives", inp.(""), inp.("")],
      ["Exclusions", inp.(""), inp.("")],
      [],
      [{"App Keywords / Job Phrases", bold}],
      [{"Use case", bold}, {"Keywords / Phrases", bold}],
      ["Worker profile words", inp.("")],
      ["Employer job post phrases", inp.("")],
      ["Local-language terms", inp.("")],
      ["Trend words / quality signals", inp.("")],
      [],
      [{"Notes / Sources", bold}],
      [
        "Contributor guide",
        "Based on the Heeero skill sample guide - primary role, synonyms, supporting skills, related roles, hard negatives, easy negatives, exclusions, and tagging."
      ],
      ["Local wording", "Local-language samples are a first-pass; validate with local operators before production use."],
      ["Use rule", "This is a first-pass matching design document, not a legal, HR or regulatory classification."]
    ]

blank_template =
  XlsxWriter.new_sheet("Blank Role Template")
  |> TemplateBuilder.write_rows(blank_rows)
  |> TemplateBuilder.set_widths([22, 32, 24, 32, 45, 14])

# ---- Sheet 4: Whats New — explains the delta from the original v1 workbook ----

whats_new_rows = [
  [{"What changed from the original workbook", section}],
  [],
  [{"Change", bold}, {"Why", bold}],
  [
    "One table for all relationship data, not two.",
    "The original had a 7-point summary AND a term-level table both describing the same relationships - editing one without the other risked them drifting out of sync, especially once we started reading this back out (round-tripping) instead of only ever reading it once. Now there's exactly one place each synonym, skill, related role, negative, or exclusion lives: the Term-Level Matching Detail table. The Role Summary block above it only holds things that are genuinely one value per role (name, description, locale, industry, the end-of-role statement) - nothing that could ever need a second row."
  ],
  [
    "New column: Relationship detail.",
    "\"Related Role\" entries turned out to need more than one flavor - Housekeeping Staff is a parent category, Public Area Attendant is a same-level sibling, Turndown Attendant is a related specialist that's neither. Rather than inventing more categories (which the matching engine would then have to handle as special cases forever), this is a free-text column: say what kind of relationship it actually is, in your own words. It's kept in full, not summarized away."
  ],
  [
    "Local-language term is now per-row, not a separate translation.",
    "A Thai name for a related role (e.g. Domestic Maid) belongs to that role, not to the relationship pointing at it. Putting it on the same row as the term keeps it attached to the right thing without a separate lookup."
  ],
  [
    "New category: Manual Review.",
    "The original Hotel Housekeeper sheet already needed this in practice (private home maid, nanny, elder-care assistant, etc.) - roles that are related but risky to auto-match, without being a hard exclusion. There was no place to put that distinct from Hard Negatives or Exclusions before."
  ],
  [
    "Expanded Detail and Heeero matching logic moved to their own Category Guidance block, one row per category instead of per role.",
    "These are genuinely valuable - they're prose describing how a whole category should be judged (e.g. \"match only when X and Y are present\"), not a fact about one specific term. Separating them from the term-level table makes that distinction visible instead of implied."
  ],
  [
    "Everything else (Primary Role, Synonyms, Supporting Skills, Related Roles, Hard/Easy Negatives, Exclusions, Locale/Industry, End-of-role Statement, App Keywords) still means the same thing.",
    "Only where the data lives changed, not what's being asked for."
  ],
  [
    "New sheet: a filled-in worked example (Hotel Housekeeper), right after Role Index.",
    "Seeing a completed row set - what a good synonym list, a well-explained related-role relationship, a real hard negative - is a faster way to understand the shape than reading the blank headers alone."
  ],
  [
    "Light-yellow cell background marks contributor input, on both the example and the blank template.",
    "It wasn't always obvious at a glance which cells were fixed template labels/guidance and which ones were meant to be typed into - the color makes that distinction visible without having to read every row."
  ]
]

whats_new =
  XlsxWriter.new_sheet("Whats New")
  |> TemplateBuilder.write_rows(whats_new_rows)
  |> TemplateBuilder.set_widths([48, 78])

{:ok, content} = XlsxWriter.generate([role_index, example_sheet, blank_template, whats_new])

out_path = Path.expand("../../Heeero Role Differentiation Template v3.xlsx", __DIR__)
File.write!(out_path, content)
IO.puts("wrote #{out_path}")
