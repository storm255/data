defmodule Data.SkillTaxonomy.XlsxImporterTest do
  use ExUnit.Case, async: true

  alias Data.SkillTaxonomy.XlsxImporter

  # Builds a minimal xlsx in memory (no formatting — only what parse/1
  # itself cares about: raw cell values) so these tests don't depend on
  # priv/skill_taxonomy/generate_template.exs's exact row positions.
  # Rows are deliberately NOT at fixed offsets across fixtures, to prove
  # parse/1 finds sections by row-label search rather than hardcoded
  # positions.
  defp build_xlsx(sheets) do
    built =
      Enum.map(sheets, fn {name, rows} ->
        rows
        |> Enum.with_index()
        |> Enum.reduce(XlsxWriter.new_sheet(name), fn {cells, row}, sheet ->
          cells
          |> Enum.with_index()
          |> Enum.reduce(sheet, fn
            {nil, _col}, sheet -> sheet
            {"", _col}, sheet -> sheet
            {value, col}, sheet -> XlsxWriter.write(sheet, row, col, value)
          end)
        end)
      end)

    {:ok, content} = XlsxWriter.generate(built)
    content
  end

  defp role_summary_rows(overrides \\ %{}) do
    defaults = %{
      primary: "Bartender",
      description: "Mixes and serves drinks at the bar.",
      locale: "en",
      industry: "Hospitality / F&B",
      statement: "I am a verified Bartender."
    }

    f = Map.merge(defaults, overrides)

    [
      ["Heeero Role Differentiation: #{f.primary}"],
      [],
      ["Role Summary"],
      ["Primary Role", f.primary],
      ["Description", f.description],
      ["Locale / Language", f.locale],
      ["Industry / Context", f.industry],
      ["End-of-role Matching Statement", f.statement]
    ]
  end

  defp term_table_header do
    [
      ["Term-Level Matching Detail"],
      [
        "Category",
        "Term",
        "Local-language term",
        "Relationship detail",
        "Matching note",
        "Confidence"
      ],
      ["(guidance parenthetical row, not data)"]
    ]
  end

  defp category_guidance_rows(entries) do
    [
      ["Category Guidance"],
      ["Category", "Expanded Detail", "Heeero matching logic"]
    ] ++ entries
  end

  describe "parse/1 — Role Summary extraction (row-label search, not fixed offsets)" do
    test "extracts primary/description/locale/industry regardless of section position" do
      rows =
        [["Some preamble row"], []] ++
          role_summary_rows() ++
          [[]] ++ term_table_header() ++ [[]]

      content = build_xlsx([{"Bartender", rows}])

      assert {:ok, result} = XlsxImporter.parse(content)
      assert [role] = result.roles
      assert role["primary_name"] == "Bartender"
      assert role["context"] == ""
      assert role["description"] == "Mixes and serves drinks at the bar."
      assert role["locale"] == "en"
      assert role["industry"] == "Hospitality / F&B"
      assert role["status"] == "differentiated"
    end

    test "known non-role sheets (Role Index, Whats New, Blank Role Template, Example - Housekeeper) are skipped" do
      content =
        build_xlsx([
          {"Role Index", [["Heeero Worker Role Differentiation Workbook"]]},
          {"Whats New", [["What changed"]]},
          {"Blank Role Template", role_summary_rows(%{primary: ""})},
          {"Example - Housekeeper", role_summary_rows(%{primary: "Hotel Housekeeper"})},
          {"Bartender", role_summary_rows() ++ [[]] ++ term_table_header()}
        ])

      assert {:ok, result} = XlsxImporter.parse(content)
      assert Enum.map(result.roles, & &1["primary_name"]) == ["Bartender"]
    end

    test "a sheet missing the Primary Role row entirely is a build error, same message RowBuilder gives" do
      rows = [["Role Summary"], ["Description", "no primary here"]]
      content = build_xlsx([{"Broken", rows}])

      assert {:ok, result} = XlsxImporter.parse(content)
      assert result.roles == []
      assert [%{message: message}] = result.errors
      assert message =~ "primary"
    end
  end

  describe "parse/1 — Term-Level Matching Detail table" do
    test "a Synonym row with a Local-language term becomes two Synonym subdocuments — neither privileged as canonical" do
      rows =
        role_summary_rows() ++
          [[]] ++
          term_table_header() ++
          [["Synonym", "barkeep", "แม่บ้านบาร์", "", "", "sure"]]

      content = build_xlsx([{"Bartender", rows}])

      assert {:ok, result} = XlsxImporter.parse(content)
      assert [role] = result.roles

      terms = role["synonyms"] |> Enum.map(& &1["term"]) |> Enum.sort()
      assert terms == Enum.sort(["barkeep", "แม่บ้านบาร์"])
      assert Enum.all?(role["synonyms"], &(&1["locale"] == "en"))
      assert Enum.all?(role["synonyms"], &(&1["confidence"] == "sure"))
    end

    test "a Synonym row without a Local-language term produces just the one synonym" do
      rows =
        role_summary_rows() ++
          [[]] ++
          term_table_header() ++
          [["Synonym", "barkeep", "", "", "", "guess"]]

      content = build_xlsx([{"Bartender", rows}])

      assert {:ok, result} = XlsxImporter.parse(content)
      assert [role] = result.roles
      assert [%{"term" => "barkeep"}] = role["synonyms"]
    end

    test "a Supporting Skill row becomes a supporting relation targeting a Skill, carrying notes and relationship_detail" do
      rows =
        role_summary_rows() ++
          [[]] ++
          term_table_header() ++
          [["Supporting Skill", "cocktail prep", "", "primary tool skill", "Core signal", "sure"]]

      content = build_xlsx([{"Bartender", rows}])

      assert {:ok, result} = XlsxImporter.parse(content)
      assert [relation] = result.pending_relations
      assert relation.relation_type == "supporting"
      assert relation.to == {:skill, "cocktail prep"}
      assert relation.confidence == "sure"
      assert relation.notes == "Core signal"
      assert relation.relationship_detail == "primary tool skill"
      assert [%{"@type" => "Skill", "name" => "cocktail prep"}] = result.skills
    end

    test "a Related Role row with a parent-category relationship_detail classifies as type_of" do
      rows =
        role_summary_rows() ++
          [[]] ++
          term_table_header() ++
          [["Related Role", "Mixology Lead", "", "parent category", "", "sure"]]

      content = build_xlsx([{"Bartender", rows}])

      assert {:ok, result} = XlsxImporter.parse(content)
      assert [relation] = result.pending_relations
      assert relation.relation_type == "type_of"
      assert relation.to == {:role, "Mixology Lead", ""}
      assert relation.relationship_detail == "parent category"
    end

    test "a Related Role row with no relationship_detail (or a non-parent one) classifies as sibling" do
      rows =
        role_summary_rows() ++
          [[]] ++
          term_table_header() ++
          [["Related Role", "Barista", "", "", "", "sure"]]

      content = build_xlsx([{"Bartender", rows}])

      assert {:ok, result} = XlsxImporter.parse(content)
      assert [relation] = result.pending_relations
      assert relation.relation_type == "sibling"
    end

    test "a Hard Negative row's Local-language term becomes local_term, and role_locale is set from the sheet's own locale" do
      rows =
        role_summary_rows(%{locale: "en / th"}) ++
          [[]] ++
          term_table_header() ++
          [
            [
              "Hard Negative",
              "Domestic Maid",
              "แม่บ้านบ้านส่วนตัว",
              "do not auto-match",
              "differs from hotel work",
              "sure"
            ]
          ]

      content = build_xlsx([{"Bartender", rows}])

      assert {:ok, result} = XlsxImporter.parse(content)
      assert [relation] = result.pending_relations
      assert relation.relation_type == "hard_negative"
      assert relation.to == {:role, "Domestic Maid", ""}
      assert relation.local_term == "แม่บ้านบ้านส่วนตัว"
      assert relation.relationship_detail == "do not auto-match"
      assert relation.role_locale == "en / th"
    end

    test "Manual Review and Easy Negative and Exclusion rows map to their matching relation kinds" do
      rows =
        role_summary_rows() ++
          [[]] ++
          term_table_header() ++
          [
            ["Manual Review", "Nanny", "", "", "", "sure"],
            ["Easy Negative", "Landscaping", "", "", "", "sure"],
            ["Exclusion", "Chef", "", "", "", "sure"]
          ]

      content = build_xlsx([{"Bartender", rows}])

      assert {:ok, result} = XlsxImporter.parse(content)

      kinds =
        result.pending_relations
        |> Enum.map(&{&1.relation_type, elem(&1.to, 1)})
        |> Enum.sort()

      assert kinds == [
               {"easy_negative", "Landscaping"},
               {"exclusion", "Chef"},
               {"manual_review", "Nanny"}
             ]
    end

    test "a blank Confidence cell defaults to guess" do
      rows =
        role_summary_rows() ++
          [[]] ++
          term_table_header() ++
          [["Hard Negative", "Domestic Maid", "", "", "", ""]]

      content = build_xlsx([{"Bartender", rows}])

      assert {:ok, result} = XlsxImporter.parse(content)
      assert [relation] = result.pending_relations
      assert relation.confidence == "guess"
    end

    test "table reading stops at the Category Guidance section, not spilling guidance rows in as data" do
      rows =
        role_summary_rows() ++
          [[]] ++
          term_table_header() ++
          [["Hard Negative", "Domestic Maid", "", "", "", "sure"]] ++
          [[]] ++
          category_guidance_rows([["Hard Negatives", "explanation text", "matching logic text"]])

      content = build_xlsx([{"Bartender", rows}])

      assert {:ok, result} = XlsxImporter.parse(content)
      assert length(result.pending_relations) == 1
    end
  end

  describe "parse/1 — cross-sheet duplicate role identity" do
    test "two sheets resolving to the same Primary Role are both errors, same as CsvImporter" do
      content =
        build_xlsx([
          {"Bartender 1", role_summary_rows()},
          {"Bartender 2", role_summary_rows()}
        ])

      assert {:ok, result} = XlsxImporter.parse(content)
      assert result.roles == []
      assert length(result.errors) == 2
      assert Enum.all?(result.errors, &(&1.message =~ "duplicate role identity"))
    end
  end

  describe "parse/1 — role guidance capture (not interpreted, not lost)" do
    test "the End-of-role Matching Statement and Category Guidance text are captured, not discarded" do
      rows =
        role_summary_rows(%{statement: "I am a verified Bartender with cocktail experience."}) ++
          [[]] ++
          term_table_header() ++
          [["Hard Negative", "Domestic Maid", "", "", "", "sure"]] ++
          [[]] ++
          category_guidance_rows([
            [
              "Hard Negatives",
              "Roles that look similar but must not match.",
              "Block automatic matching."
            ],
            ["Synonyms", "", ""]
          ])

      content = build_xlsx([{"Bartender", rows}])

      assert {:ok, result} = XlsxImporter.parse(content)
      assert [guidance] = result.role_guidance
      assert guidance.primary == "Bartender"

      assert guidance.end_of_role_statement ==
               "I am a verified Bartender with cocktail experience."

      assert guidance.category_guidance["Hard Negatives"] == %{
               expanded_detail: "Roles that look similar but must not match.",
               matching_logic: "Block automatic matching."
             }

      refute Map.has_key?(guidance.category_guidance, "Synonyms")
    end

    test "a sheet with no guidance text at all contributes nothing to role_guidance" do
      rows = role_summary_rows(%{statement: ""}) ++ [[]] ++ term_table_header()
      content = build_xlsx([{"Bartender", rows}])

      assert {:ok, result} = XlsxImporter.parse(content)
      assert result.role_guidance == []
    end
  end
end
