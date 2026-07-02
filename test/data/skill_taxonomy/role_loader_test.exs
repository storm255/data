defmodule Data.SkillTaxonomy.RoleLoaderTest do
  use ExUnit.Case, async: true

  alias Data.SkillTaxonomy.RoleLoader

  # Document.get(id: ...) sends the id as a query param
  # ("...?graph_type=instance&id=Role%2FBartender%2B&as_list=false"), not
  # part of the URL path — Document.query/3 POSTs the template as the
  # request body instead. This stub serves a fixed set of `docs` for GETs
  # and a fixed relation list for the one query POST.
  defp stub_config(docs, relations) do
    TerminusDB.Config.new(
      endpoint: "http://stub.local",
      adapter: fn req ->
        case req.method do
          :get ->
            id = URI.decode_query(req.url.query || "")["id"]
            {req, Req.Response.new(status: 200, body: Map.fetch!(docs, id))}

          :post ->
            {req, Req.Response.new(status: 200, body: relations)}
        end
      end
    )
    |> TerminusDB.Config.with_database("test_db")
  end

  test "resolves relations back to display names, grouped by field" do
    role = %{
      "@id" => "Role/Bartender+",
      "@type" => "Role",
      "primary_name" => "Bartender",
      "context" => "",
      "description" => "Serves drinks",
      "locale" => "en",
      "industry" => "hospitality/F&B",
      "synonyms" => [
        %{"@type" => "Synonym", "term" => "barkeep", "locale" => "en"},
        %{"@type" => "Synonym", "term" => "barman", "locale" => "en"}
      ]
    }

    relations = [
      %{
        "@type" => "RoleRelation",
        "from" => "Role/Bartender+",
        "to" => "Skill/cocktail%20prep",
        "relation_type" => "supporting",
        "confidence" => "sure"
      },
      %{
        "@type" => "RoleRelation",
        "from" => "Role/Bartender+",
        "to" => "Role/Barista+",
        "relation_type" => "hard_negative",
        "confidence" => "guess"
      }
    ]

    docs = %{
      "Role/Bartender+" => role,
      "Skill/cocktail%20prep" => %{"@type" => "Skill", "name" => "cocktail prep"},
      "Role/Barista+" => %{"@type" => "Role", "primary_name" => "Barista", "context" => ""}
    }

    config = stub_config(docs, relations)

    assert {:ok, fields} = RoleLoader.fetch(config, "Role/Bartender+")

    assert fields.primary == "Bartender"
    assert fields.description == "Serves drinks"
    assert fields.context == ""
    assert Enum.sort(fields.synonyms) == ["barkeep", "barman"]
    assert fields.supporting == ["cocktail prep"]
    assert fields.hard_negatives == ["Barista"]
    assert fields.sibling == []
    assert fields.type_of == []
    assert fields.easy_negatives == []
    assert fields.exclusions == []
  end

  test "excludes the auto-generated type_of link back to the base role for a context variant" do
    variant = %{
      "@id" => "Role/Waitstaff+fine_dining",
      "@type" => "Role",
      "primary_name" => "Waitstaff",
      "context" => "fine_dining",
      "locale" => "en",
      "industry" => "hospitality/F&B",
      "synonyms" => []
    }

    relations = [
      %{
        "@type" => "RoleRelation",
        "from" => "Role/Waitstaff+fine_dining",
        "to" => "Role/Waitstaff+",
        "relation_type" => "type_of",
        "confidence" => "guess"
      },
      %{
        "@type" => "RoleRelation",
        "from" => "Role/Waitstaff+fine_dining",
        "to" => "Skill/wine%20service",
        "relation_type" => "supporting",
        "confidence" => "guess"
      }
    ]

    docs = %{
      "Role/Waitstaff+fine_dining" => variant,
      "Role/Waitstaff+" => %{"@type" => "Role", "primary_name" => "Waitstaff", "context" => ""},
      "Skill/wine%20service" => %{"@type" => "Skill", "name" => "wine service"}
    }

    config = stub_config(docs, relations)

    assert {:ok, fields} = RoleLoader.fetch(config, "Role/Waitstaff+fine_dining")
    assert fields.context == "fine_dining"
    assert fields.type_of == []
    assert fields.supporting == ["wine service"]
  end
end
