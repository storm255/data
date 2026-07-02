defmodule Data.SkillTaxonomy.RowBuilderTest do
  use ExUnit.Case, async: true

  alias Data.SkillTaxonomy.RowBuilder

  defp fields(overrides) do
    Map.merge(
      %{
        primary: "Bartender",
        description: "",
        context: "",
        synonyms: [],
        supporting: [],
        type_of: [],
        sibling: [],
        hard_negatives: [],
        easy_negatives: [],
        exclusions: [],
        manual_review: [],
        locale: "en",
        industry: "hospitality/F&B",
        confidence: "guess"
      },
      Map.new(overrides)
    )
  end

  test "builds a role document, relations per list field, and skill documents for supporting targets" do
    input =
      fields(
        synonyms: ["barkeep", "barman"],
        supporting: ["cocktail prep"],
        sibling: ["Barista"],
        hard_negatives: ["Barista", "Waiter"],
        easy_negatives: ["Landscaping"],
        manual_review: ["Bar Manager"],
        confidence: "sure"
      )

    assert {:ok, result} = RowBuilder.build(input)

    assert result.role["@type"] == "Role"
    assert result.role["primary_name"] == "Bartender"
    assert result.role["context"] == ""
    assert result.role["status"] == "differentiated"

    assert Enum.sort_by(result.role["synonyms"], & &1["term"]) == [
             %{"@type" => "Synonym", "term" => "barkeep", "locale" => "en"},
             %{"@type" => "Synonym", "term" => "barman", "locale" => "en"}
           ]

    assert length(result.relations) == 6

    assert result.relations |> Enum.map(& &1.relation_type) |> Enum.sort() ==
             [
               "easy_negative",
               "hard_negative",
               "hard_negative",
               "manual_review",
               "sibling",
               "supporting"
             ]

    supporting = Enum.find(result.relations, &(&1.relation_type == "supporting"))
    assert supporting.from == {:role, "Bartender", ""}
    assert supporting.to == {:skill, "cocktail prep"}
    assert supporting.confidence == "sure"

    assert result.skills == [%{"@type" => "Skill", "name" => "cocktail prep"}]
  end

  test "missing primary is an error" do
    assert {:error, message} = RowBuilder.build(fields(primary: ""))
    assert message =~ "primary"
  end

  test "invalid confidence is an error" do
    assert {:error, message} = RowBuilder.build(fields(confidence: "maybe"))
    assert message =~ "confidence"
  end

  test "blank confidence defaults to guess" do
    assert {:ok, result} = RowBuilder.build(fields(confidence: "", hard_negatives: ["Barista"]))
    assert Enum.all?(result.relations, &(&1.confidence == "guess"))
  end

  test "a non-blank context with base_role_exists?: true builds a variant role plus an auto type_of relation" do
    input = fields(context: "fine_dining", supporting: ["wine service"])

    assert {:ok, result} = RowBuilder.build(input, base_role_exists?: true)
    assert result.role["context"] == "fine_dining"

    auto = Enum.find(result.relations, &(&1.relation_type == "type_of"))
    assert auto.from == {:role, "Bartender", "fine_dining"}
    assert auto.to == {:role, "Bartender", ""}
  end

  test "a non-blank context with base_role_exists?: false (or omitted) is an error" do
    input = fields(context: "fine_dining")

    assert {:error, message} = RowBuilder.build(input)
    assert message =~ "base"

    assert {:error, _} = RowBuilder.build(input, base_role_exists?: false)
  end

  test "warnings for fewer than 2 synonyms and 0 hard negatives" do
    assert {:ok, result} = RowBuilder.build(fields(synonyms: ["barkeep"]))
    assert Enum.any?(result.warnings, &(&1 =~ "synonym"))
    assert Enum.any?(result.warnings, &(&1 =~ "hard negative"))
  end

  test "description is included only when present" do
    assert {:ok, with_description} = RowBuilder.build(fields(description: "Serves drinks"))
    assert with_description.role["description"] == "Serves drinks"

    assert {:ok, without} = RowBuilder.build(fields(description: ""))
    refute Map.has_key?(without.role, "description")
  end

  describe "rich term maps (per-item confidence/notes/relationship_detail/local_term)" do
    test "a relation list item can be a rich map instead of a plain string" do
      input =
        fields(
          confidence: "guess",
          hard_negatives: [
            %{
              term: "Domestic Maid",
              confidence: "sure",
              notes: "Private home work differs from hotel room turnover.",
              relationship_detail: "do not auto-match",
              local_term: "แม่บ้านบ้านส่วนตัว"
            }
          ]
        )

      assert {:ok, result} = RowBuilder.build(input)
      assert [relation] = result.relations

      assert relation.to == {:role, "Domestic Maid", ""}
      assert relation.confidence == "sure"
      assert relation.notes == "Private home work differs from hotel room turnover."
      assert relation.relationship_detail == "do not auto-match"
      assert relation.local_term == "แม่บ้านบ้านส่วนตัว"
    end

    test "a rich map without confidence falls back to the row-level default" do
      input =
        fields(
          confidence: "guess",
          sibling: [%{term: "Public Area Attendant", relationship_detail: "sibling role"}]
        )

      assert {:ok, result} = RowBuilder.build(input)
      assert [relation] = result.relations
      assert relation.confidence == "guess"
      assert relation.relationship_detail == "sibling role"
      refute Map.has_key?(relation, :notes)
      refute Map.has_key?(relation, :local_term)
    end

    test "plain strings still work unchanged, with no notes/relationship_detail/local_term keys" do
      input = fields(hard_negatives: ["Barista"])

      assert {:ok, result} = RowBuilder.build(input)
      assert [relation] = result.relations
      assert relation.to == {:role, "Barista", ""}
      refute Map.has_key?(relation, :notes)
      refute Map.has_key?(relation, :relationship_detail)
      refute Map.has_key?(relation, :local_term)
    end

    test "a rich map works for supporting (skill target) too" do
      input =
        fields(
          supporting: [
            %{term: "guest room cleaning", confidence: "sure", notes: "Core signal for the role."}
          ]
        )

      assert {:ok, result} = RowBuilder.build(input)
      assert [relation] = result.relations
      assert relation.to == {:skill, "guest room cleaning"}
      assert relation.confidence == "sure"
      assert relation.notes == "Core signal for the role."
      assert result.skills == [%{"@type" => "Skill", "name" => "guest room cleaning"}]
    end

    test "synonyms can be rich maps carrying per-synonym confidence" do
      input =
        fields(
          synonyms: ["barkeep", %{term: "barman", confidence: "guess"}],
          hard_negatives: ["Barista"]
        )

      assert {:ok, result} = RowBuilder.build(input)

      synonyms = Enum.sort_by(result.role["synonyms"], & &1["term"])

      assert synonyms == [
               %{"@type" => "Synonym", "term" => "barkeep", "locale" => "en"},
               %{
                 "@type" => "Synonym",
                 "term" => "barman",
                 "locale" => "en",
                 "confidence" => "guess"
               }
             ]
    end

    test "two distinct synonym entries that resolve to the same (term, locale) are deduped, not embedded twice" do
      # TerminusDB rejects mutating the same subdocument id twice in one
      # document — this happens for real when two different English
      # synonyms happen to share an identical local-language translation
      # (XLSX import's per-row local_term expansion, design doc §2).
      input =
        fields(
          synonyms: [
            %{term: "Specialist Cook", confidence: "sure"},
            %{term: "กุ๊กเฉพาะทาง", confidence: "sure"},
            %{term: "Specialty Cook", confidence: "sure"},
            %{term: "กุ๊กเฉพาะทาง", confidence: "sure"}
          ],
          hard_negatives: ["Barista"]
        )

      assert {:ok, result} = RowBuilder.build(input)

      terms = Enum.map(result.role["synonyms"], & &1["term"]) |> Enum.sort()
      assert terms == Enum.sort(["Specialist Cook", "Specialty Cook", "กุ๊กเฉพาะทาง"])
    end
  end
end
