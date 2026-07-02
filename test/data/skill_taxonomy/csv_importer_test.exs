defmodule Data.SkillTaxonomy.CsvImporterTest do
  use ExUnit.Case, async: true

  alias Data.SkillTaxonomy.CsvImporter

  @columns ~w(primary description context synonyms supporting type_of sibling
              hard_negatives easy_negatives exclusions manual_review locale industry confidence)a

  @header Enum.join(@columns, ",") <> "\n"

  defp csv(rows) when is_list(rows), do: @header <> Enum.join(rows, "\n")

  defp row(fields) when is_map(fields) do
    @columns
    |> Enum.map(fn col -> quote_field(Map.get(fields, col, "")) end)
    |> Enum.join(",")
  end

  defp quote_field(value) do
    if String.contains?(value, [",", "\""]) do
      "\"" <> String.replace(value, "\"", "\"\"") <> "\""
    else
      value
    end
  end

  describe "parse/1 — a valid single row" do
    test "produces one Role document and one pending relation per listed relationship" do
      content =
        csv([
          row(%{
            primary: "Bartender",
            description: "Serves drinks",
            synonyms: "barkeep;barman",
            supporting: "cocktail prep",
            sibling: "Barista",
            hard_negatives: "Barista;Waiter",
            easy_negatives: "Landscaping",
            manual_review: "Bar Manager",
            locale: "en",
            industry: "hospitality/F&B",
            confidence: "sure"
          })
        ])

      assert {:ok, result} = CsvImporter.parse(content)
      assert result.errors == []

      assert [role] = result.roles
      assert role["@type"] == "Role"
      assert role["primary_name"] == "Bartender"
      assert role["context"] == ""
      assert role["description"] == "Serves drinks"
      assert role["locale"] == "en"
      assert role["industry"] == "hospitality/F&B"
      assert role["status"] == "differentiated"

      assert Enum.sort_by(role["synonyms"], & &1["term"]) == [
               %{"@type" => "Synonym", "term" => "barkeep", "locale" => "en"},
               %{"@type" => "Synonym", "term" => "barman", "locale" => "en"}
             ]

      # 1 supporting + 1 sibling + 2 hard_negatives + 1 easy_negative + 1 manual_review = 6
      assert length(result.pending_relations) == 6

      assert result.pending_relations |> Enum.map(& &1.relation_type) |> Enum.sort() ==
               [
                 "easy_negative",
                 "hard_negative",
                 "hard_negative",
                 "manual_review",
                 "sibling",
                 "supporting"
               ]

      supporting = Enum.find(result.pending_relations, &(&1.relation_type == "supporting"))
      assert supporting.from == {:role, "Bartender", ""}
      assert supporting.to == {:skill, "cocktail prep"}
      assert supporting.confidence == "sure"
      refute Map.has_key?(supporting, :weight)

      sibling = Enum.find(result.pending_relations, &(&1.relation_type == "sibling"))
      assert sibling.from == {:role, "Bartender", ""}
      assert sibling.to == {:role, "Barista", ""}

      assert result.skills == [%{"@type" => "Skill", "name" => "cocktail prep"}]
    end
  end

  describe "parse/1 — multiple rows" do
    test "produces distinct, non-contaminated Role sets" do
      content =
        csv([
          row(%{primary: "Bartender", synonyms: "barkeep;barman", hard_negatives: "Barista"}),
          row(%{
            primary: "Barista",
            synonyms: "coffee maker;barista(th)",
            hard_negatives: "Bartender"
          })
        ])

      assert {:ok, result} = CsvImporter.parse(content)
      assert result.errors == []
      assert length(result.roles) == 2

      names = Enum.map(result.roles, & &1["primary_name"]) |> Enum.sort()
      assert names == ["Barista", "Bartender"]

      bartender = Enum.find(result.roles, &(&1["primary_name"] == "Bartender"))
      assert Enum.map(bartender["synonyms"], & &1["term"]) |> Enum.sort() == ["barkeep", "barman"]
    end

    test "deduplicates Skill documents shared across rows" do
      content =
        csv([
          row(%{primary: "Bartender", supporting: "customer service", hard_negatives: "Barista"}),
          row(%{primary: "Barista", supporting: "customer service", hard_negatives: "Bartender"})
        ])

      assert {:ok, result} = CsvImporter.parse(content)
      assert result.skills == [%{"@type" => "Skill", "name" => "customer service"}]
    end
  end

  describe "parse/1 — list-column parsing" do
    test "splits on ';', trims whitespace, and drops empty entries" do
      content =
        csv([
          row(%{
            primary: "Bartender",
            synonyms: " barkeep ; ; barman ",
            hard_negatives: "Barista"
          })
        ])

      assert {:ok, result} = CsvImporter.parse(content)
      [role] = result.roles
      assert Enum.map(role["synonyms"], & &1["term"]) |> Enum.sort() == ["barkeep", "barman"]
    end
  end

  describe "parse/1 — missing primary" do
    test "is a row-level error and the row contributes nothing" do
      content =
        csv([
          row(%{primary: "", synonyms: "barkeep", hard_negatives: "Barista"}),
          row(%{primary: "Barista", hard_negatives: "Bartender"})
        ])

      assert {:ok, result} = CsvImporter.parse(content)
      assert [%{row: 2, message: message}] = result.errors
      assert message =~ "primary"

      assert length(result.roles) == 1
      assert hd(result.roles)["primary_name"] == "Barista"

      # row 2's own relation (barista -> bartender) still went through —
      # only row 2 (the malformed row) contributed nothing.
      assert [%{from: {:role, "Barista", ""}, to: {:role, "Bartender", ""}}] =
               result.pending_relations
    end
  end

  describe "parse/1 — malformed header" do
    test "is a single top-level error, not a per-row one" do
      bad_header =
        "primary,description,synonyms,supporting,type_of,sibling,hard_negative,easy_negatives,exclusions,locale,industry,confidence\n"

      content = bad_header <> row(%{primary: "Bartender"})

      assert {:error, {:invalid_header, details}} = CsvImporter.parse(content)
      assert "context" in details.missing
      assert "hard_negative" in details.unexpected
    end
  end

  describe "parse/1 — warnings" do
    test "fewer than 2 synonyms or 0 hard negatives warn without rejecting the row" do
      content =
        csv([
          row(%{primary: "Bartender", synonyms: "barkeep", hard_negatives: ""})
        ])

      assert {:ok, result} = CsvImporter.parse(content)
      assert result.errors == []
      assert length(result.roles) == 1

      messages = Enum.map(result.warnings, & &1.message)
      assert Enum.any?(messages, &(&1 =~ "synonym"))
      assert Enum.any?(messages, &(&1 =~ "hard negative"))
    end
  end

  describe "parse/1 — confidence" do
    test "defaults to guess when blank" do
      content = csv([row(%{primary: "Bartender", hard_negatives: "Barista", confidence: ""})])
      assert {:ok, result} = CsvImporter.parse(content)
      assert Enum.all?(result.pending_relations, &(&1.confidence == "guess"))
    end

    test "passes through explicit sure/guess unchanged" do
      content = csv([row(%{primary: "Bartender", hard_negatives: "Barista", confidence: "sure"})])
      assert {:ok, result} = CsvImporter.parse(content)
      assert Enum.all?(result.pending_relations, &(&1.confidence == "sure"))
    end

    test "any other value is a row-level error" do
      content =
        csv([row(%{primary: "Bartender", hard_negatives: "Barista", confidence: "maybe"})])

      assert {:ok, result} = CsvImporter.parse(content)
      assert [%{row: 2, message: message}] = result.errors
      assert message =~ "confidence"
      assert result.roles == []
    end
  end

  describe "parse/1 — weight" do
    test "is never produced by parse/1 — it's set later by import/2" do
      content = csv([row(%{primary: "Bartender", hard_negatives: "Barista"})])
      assert {:ok, result} = CsvImporter.parse(content)
      refute Enum.any?(result.pending_relations, &Map.has_key?(&1, :weight))
    end

    test "a stray weight column in the file is ignored, not trusted" do
      content =
        "primary,description,context,synonyms,supporting,type_of,sibling,hard_negatives,easy_negatives,exclusions,locale,industry,confidence,weight\n" <>
          "Bartender,,,,,,,\"Barista\",,,,,,0.1\n"

      assert {:error, {:invalid_header, details}} = CsvImporter.parse(content)
      assert "weight" in details.unexpected
    end
  end

  describe "parse/1 — context variants" do
    test "blank context produces a Role identified by primary alone" do
      content = csv([row(%{primary: "Waitstaff", hard_negatives: "Bartender"})])
      assert {:ok, result} = CsvImporter.parse(content)
      assert [role] = result.roles
      assert role["context"] == ""
    end

    test "non-blank context produces a distinct Role and an auto type_of relation to the base row" do
      content =
        csv([
          row(%{primary: "Waitstaff", hard_negatives: "Bartender"}),
          row(%{primary: "Waitstaff", context: "fine_dining", supporting: "wine service"})
        ])

      assert {:ok, result} = CsvImporter.parse(content)
      assert result.errors == []
      assert length(result.roles) == 2

      variant = Enum.find(result.roles, &(&1["context"] == "fine_dining"))
      assert variant["primary_name"] == "Waitstaff"

      auto_type_of =
        Enum.find(result.pending_relations, fn r ->
          r.relation_type == "type_of" and r.from == {:role, "Waitstaff", "fine_dining"}
        end)

      assert auto_type_of
      assert auto_type_of.to == {:role, "Waitstaff", ""}
    end

    test "a context row with no matching blank-context row is a row-level error" do
      content =
        csv([row(%{primary: "Waitstaff", context: "fine_dining", supporting: "wine service"})])

      assert {:ok, result} = CsvImporter.parse(content)
      assert [%{row: 2, message: message}] = result.errors
      assert message =~ "base"
      assert result.roles == []
    end

    test "an unrelated duplicate row does not block a valid context row's base-role check" do
      content =
        csv([
          row(%{primary: "Waitstaff", hard_negatives: "Bartender"}),
          row(%{primary: "Waitstaff", hard_negatives: "Bartender"}),
          row(%{primary: "Waitstaff", context: "fine_dining", supporting: "wine service"})
        ])

      assert {:ok, result} = CsvImporter.parse(content)

      # rows 2 and 3 (both blank-context "Waitstaff") are duplicate errors...
      duplicate_rows = Enum.filter(result.errors, &(&1.message =~ "duplicate"))
      assert length(duplicate_rows) == 2

      # ...but the context variant (row 4) still resolves successfully
      assert Enum.any?(result.roles, &(&1["context"] == "fine_dining"))
    end
  end

  describe "parse/1 — duplicate role identity" do
    test "two rows with the same primary and context both error, neither silently overwrites" do
      content =
        csv([
          row(%{primary: "Waitstaff", hard_negatives: "Bartender"}),
          row(%{primary: "Waitstaff", hard_negatives: "Sommelier"})
        ])

      assert {:ok, result} = CsvImporter.parse(content)
      assert [%{row: 2, message: m1}, %{row: 3, message: m2}] = result.errors
      assert m1 =~ "duplicate"
      assert m2 =~ "duplicate"
      assert result.roles == []
    end
  end

  describe "parse/1 — description and synonym locale" do
    test "description passes through as free text, blank is allowed" do
      content =
        csv([
          row(%{
            primary: "Bartender",
            description: "Serves drinks, mixes cocktails",
            hard_negatives: "Barista"
          }),
          row(%{primary: "Barista", hard_negatives: "Bartender"})
        ])

      assert {:ok, result} = CsvImporter.parse(content)
      assert result.errors == []

      bartender = Enum.find(result.roles, &(&1["primary_name"] == "Bartender"))
      assert bartender["description"] == "Serves drinks, mixes cocktails"

      barista = Enum.find(result.roles, &(&1["primary_name"] == "Barista"))
      refute Map.has_key?(barista, "description")
    end

    test "each synonym inherits the row's own locale column" do
      content =
        csv([
          row(%{
            primary: "Bartender",
            synonyms: "barkeep;barman",
            locale: "th",
            hard_negatives: "Barista"
          })
        ])

      assert {:ok, result} = CsvImporter.parse(content)
      [role] = result.roles
      assert Enum.all?(role["synonyms"], &(&1["locale"] == "th"))
    end
  end
end
