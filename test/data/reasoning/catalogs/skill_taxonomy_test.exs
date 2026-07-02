defmodule Data.Reasoning.Catalogs.SkillTaxonomyTest do
  use ExUnit.Case, async: true

  alias Data.Reasoning.Catalogs.SkillTaxonomy
  alias ExDatalog.Knowledge

  test "declares the expected base, symmetric-closure, and derived relations" do
    catalog = SkillTaxonomy.build()

    assert catalog.name == :skill_taxonomy

    assert Enum.sort(catalog.relations) == [
             {"candidate", [:string, :string]},
             {"easy_negative", [:string, :string, :integer]},
             {"easy_negative_sym", [:string, :string, :integer]},
             {"eligible", [:string, :string]},
             {"excluded", [:string, :string]},
             {"exclusion", [:string, :string, :integer]},
             {"exclusion_sym", [:string, :string, :integer]},
             {"flagged_for_review", [:string, :string]},
             {"hard_negative", [:string, :string, :integer]},
             {"hard_negative_sym", [:string, :string, :integer]},
             {"manual_review", [:string, :string, :integer]},
             {"manual_review_sym", [:string, :string, :integer]},
             {"related", [:string, :string]},
             {"sibling", [:string, :string, :integer]},
             {"sibling_sym", [:string, :string, :integer]},
             {"supporting", [:string, :string, :integer]},
             {"type_of", [:string, :string, :integer]}
           ]
  end

  defp materialize(facts) do
    {:ok, knowledge} =
      SkillTaxonomy.build()
      |> Data.Reasoning.Catalog.build_program(facts)
      |> ExDatalog.materialize()

    knowledge
  end

  describe "symmetric closure" do
    test "hard_negative, easy_negative, sibling, exclusion, and manual_review all close both directions" do
      facts = [
        {"hard_negative", ["Bartender", "Barista", 1000]},
        {"easy_negative", ["Bartender", "Landscaper", 1000]},
        {"sibling", ["Bartender", "Barista", 1000]},
        {"exclusion", ["Bartender", "Chef", 1000]},
        {"manual_review", ["Bartender", "Nanny", 1000]}
      ]

      knowledge = materialize(facts)

      for {base, sym} <- [
            {"hard_negative", "hard_negative_sym"},
            {"easy_negative", "easy_negative_sym"},
            {"sibling", "sibling_sym"},
            {"exclusion", "exclusion_sym"},
            {"manual_review", "manual_review_sym"}
          ] do
        [from, to, _weight] = Enum.find(facts, fn {name, _} -> name == base end) |> elem(1)

        assert MapSet.new([{from, to}, {to, from}]) ==
                 Knowledge.match(knowledge, sym, [:_, :_, :_])
                 |> Enum.map(fn {a, b, _w} -> {a, b} end)
                 |> MapSet.new()
      end
    end

    test "type_of and supporting stay directional (no reverse fact)" do
      facts = [
        {"type_of", ["Sous Chef", "Chef", 1000]},
        {"supporting", ["Bartender", "cocktail prep", 1000]}
      ]

      knowledge = materialize(facts)

      assert Knowledge.match(knowledge, "type_of", [:_, :_, :_]) ==
               MapSet.new([{"Sous Chef", "Chef", 1000}])

      assert Knowledge.match(knowledge, "supporting", [:_, :_, :_]) ==
               MapSet.new([{"Bartender", "cocktail prep", 1000}])
    end
  end

  describe "related/2 — transitive closure over type_of and sibling" do
    test "reaches multiple hops through a type_of chain" do
      facts = [
        {"type_of", ["Sous Chef", "Chef", 1000]},
        {"type_of", ["Chef", "Kitchen Staff", 1000]}
      ]

      knowledge = materialize(facts)

      assert Knowledge.match(knowledge, "related", ["Sous Chef", :_]) ==
               MapSet.new([{"Sous Chef", "Chef"}, {"Sous Chef", "Kitchen Staff"}])
    end

    test "reaches through sibling (symmetric) as well as type_of" do
      facts = [{"sibling", ["Bartender", "Barista", 1000]}]

      knowledge = materialize(facts)

      assert Knowledge.match(knowledge, "related", [:_, :_]) ==
               MapSet.new([{"Bartender", "Barista"}, {"Barista", "Bartender"}])
    end

    test "combines a sibling hop with a type_of hop" do
      facts = [
        {"sibling", ["Bartender", "Barista", 1000]},
        {"type_of", ["Barista", "Beverage Staff", 1000]}
      ]

      knowledge = materialize(facts)

      assert {"Bartender", "Beverage Staff"} in Knowledge.match(knowledge, "related", [:_, :_])
    end
  end

  describe "excluded/2 and eligible/2" do
    test "a hard_negative, easy_negative, or exclusion pair is excluded regardless of weight" do
      facts = [
        {"hard_negative", ["Bartender", "Barista", 1000]},
        {"easy_negative", ["Bartender", "Landscaper", 1]},
        {"exclusion", ["Bartender", "Chef", 500]},
        {"candidate", ["Bartender", "Barista"]},
        {"candidate", ["Bartender", "Landscaper"]},
        {"candidate", ["Bartender", "Chef"]},
        {"candidate", ["Bartender", "Mixologist"]}
      ]

      knowledge = materialize(facts)

      assert Knowledge.match(knowledge, "excluded", [:_, :_]) ==
               MapSet.new([
                 {"Bartender", "Barista"},
                 {"Barista", "Bartender"},
                 {"Bartender", "Landscaper"},
                 {"Landscaper", "Bartender"},
                 {"Bartender", "Chef"},
                 {"Chef", "Bartender"}
               ])

      assert Knowledge.match(knowledge, "eligible", [:_, :_]) ==
               MapSet.new([{"Bartender", "Mixologist"}])
    end

    test "manual_review does NOT block eligibility on its own" do
      facts = [
        {"manual_review", ["Bartender", "Nanny", 1000]},
        {"candidate", ["Bartender", "Nanny"]}
      ]

      knowledge = materialize(facts)

      assert Knowledge.match(knowledge, "excluded", [:_, :_]) == MapSet.new()

      assert Knowledge.match(knowledge, "eligible", [:_, :_]) ==
               MapSet.new([{"Bartender", "Nanny"}])
    end
  end

  describe "flagged_for_review/2 — advisory, independent of eligible/2" do
    test "a manual_review pair is both eligible and flagged for review" do
      facts = [
        {"manual_review", ["Bartender", "Nanny", 1000]},
        {"candidate", ["Bartender", "Nanny"]}
      ]

      knowledge = materialize(facts)

      assert {"Bartender", "Nanny"} in Knowledge.match(knowledge, "eligible", [:_, :_])
      assert {"Bartender", "Nanny"} in Knowledge.match(knowledge, "flagged_for_review", [:_, :_])
    end

    test "a hard_negative pair is excluded (not eligible) but not flagged_for_review" do
      facts = [
        {"hard_negative", ["Bartender", "Barista", 1000]},
        {"candidate", ["Bartender", "Barista"]}
      ]

      knowledge = materialize(facts)

      refute {"Bartender", "Barista"} in Knowledge.match(knowledge, "eligible", [:_, :_])
      assert Knowledge.match(knowledge, "flagged_for_review", [:_, :_]) == MapSet.new()
    end
  end
end
