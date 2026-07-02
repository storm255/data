defmodule Data.Reasoning.Loaders.SkillTaxonomyTest do
  use ExUnit.Case, async: true

  alias Data.Reasoning.Loaders.SkillTaxonomy

  defp stub_config(responder) do
    TerminusDB.Config.new(
      endpoint: "http://stub.local",
      adapter: fn req ->
        query = URI.decode_query(req.url.query || "")
        {req, Req.Response.new(status: 200, body: responder.(query))}
      end
    )
    |> TerminusDB.Config.with_database("test_db")
  end

  test "dispatches each RoleRelation to its fact relation by relation_type" do
    config =
      stub_config(fn %{"type" => "RoleRelation"} ->
        [
          %{
            "@type" => "RoleRelation",
            "from" => "Role/Bartender+",
            "to" => "Role/Barista+",
            "relation_type" => "hard_negative",
            "confidence" => "sure",
            "weight" => 1.0
          },
          %{
            "@type" => "RoleRelation",
            "from" => "Role/Bartender+",
            "to" => "Skill/cocktail%20prep+",
            "relation_type" => "supporting",
            "confidence" => "guess",
            "weight" => 1.0
          }
        ]
      end)

    facts = SkillTaxonomy.facts(config)

    assert {"hard_negative", ["Role/Bartender+", "Role/Barista+", 1000]} in facts
    assert {"supporting", ["Role/Bartender+", "Skill/cocktail%20prep+", 1000]} in facts
    assert length(facts) == 2
  end

  test "scales a fractional weight to an integer (round(weight * 1000))" do
    config =
      stub_config(fn %{"type" => "RoleRelation"} ->
        [
          %{
            "@type" => "RoleRelation",
            "from" => "Role/A+",
            "to" => "Role/B+",
            "relation_type" => "sibling",
            "confidence" => "sure",
            "weight" => 0.734
          }
        ]
      end)

    assert [{"sibling", ["Role/A+", "Role/B+", 734]}] = SkillTaxonomy.facts(config)
  end

  test "an empty RoleRelation set produces no facts" do
    config = stub_config(fn %{"type" => "RoleRelation"} -> [] end)
    assert SkillTaxonomy.facts(config) == []
  end

  test "every relation kind the catalog declares round-trips through the loader" do
    kinds = ~w(supporting type_of sibling hard_negative easy_negative exclusion manual_review)

    relations =
      Enum.map(kinds, fn kind ->
        %{
          "@type" => "RoleRelation",
          "from" => "Role/A+",
          "to" => "Role/B+",
          "relation_type" => kind,
          "confidence" => "sure",
          "weight" => 1.0
        }
      end)

    config = stub_config(fn %{"type" => "RoleRelation"} -> relations end)

    facts = SkillTaxonomy.facts(config)
    assert Enum.map(facts, &elem(&1, 0)) |> Enum.sort() == Enum.sort(kinds)
  end
end
