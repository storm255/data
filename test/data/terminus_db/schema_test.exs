defmodule Data.TerminusDB.SchemaTest do
  use ExUnit.Case, async: true

  alias Data.TerminusDB.Schema

  describe "classes/0" do
    setup do
      classes = Schema.classes()
      by_id = Map.new(classes, &{&1["@id"], &1})
      %{classes: classes, by_id: by_id}
    end

    test "every class is a valid Class map with a distinct @id", %{classes: classes} do
      ids = Enum.map(classes, & &1["@id"])

      assert ids == Enum.uniq(ids)

      for class <- classes do
        assert class["@type"] == "Class"
        assert is_binary(class["@id"]) and class["@id"] != ""
        assert Map.has_key?(class, "@key")
      end
    end

    test "includes Role, Skill, RoleRelation, and the embedded Synonym/Keyword subdocuments", %{
      by_id: by_id
    } do
      assert Map.has_key?(by_id, "Role")
      assert Map.has_key?(by_id, "Skill")
      assert Map.has_key?(by_id, "RoleRelation")
      assert Map.has_key?(by_id, "Synonym")
      assert Map.has_key?(by_id, "Keyword")
    end

    test "Role has the fields from design doc §3, including context, description, and keywords",
         %{
           by_id: by_id
         } do
      role = by_id["Role"]

      assert role["primary_name"] == "xsd:string"
      assert role["context"] == "xsd:string"
      assert role["locale"] == "xsd:string"
      assert role["industry"] == "xsd:string"
      assert role["description"] == %{"@type" => "Optional", "@class" => "xsd:string"}
      assert role["status"] == "xsd:string"
      assert role["synonyms"] == %{"@type" => "Set", "@class" => "Synonym"}
      assert role["keywords"] == %{"@type" => "Set", "@class" => "Keyword"}
    end

    test "Skill has a name field", %{by_id: by_id} do
      assert by_id["Skill"]["name"] == "xsd:string"
    end

    test "RoleRelation has from/to references, relation_type, confidence, weight, relationship_detail, and optional context fields",
         %{by_id: by_id} do
      relation = by_id["RoleRelation"]

      assert relation["from"] == "xsd:string"
      assert relation["to"] == "xsd:string"
      assert relation["relation_type"] == "xsd:string"
      assert relation["confidence"] == "xsd:string"
      assert relation["weight"] == "xsd:decimal"
      assert relation["relationship_detail"] == %{"@type" => "Optional", "@class" => "xsd:string"}
      assert relation["locale"] == %{"@type" => "Optional", "@class" => "xsd:string"}
      assert relation["industry"] == %{"@type" => "Optional", "@class" => "xsd:string"}
      assert relation["notes"] == %{"@type" => "Optional", "@class" => "xsd:string"}
    end

    test "Synonym is a subdocument with term and locale", %{by_id: by_id} do
      synonym = by_id["Synonym"]

      assert Map.has_key?(synonym, "@subdocument")
      assert synonym["term"] == "xsd:string"
      assert synonym["locale"] == "xsd:string"
      assert synonym["confidence"] == %{"@type" => "Optional", "@class" => "xsd:string"}
    end

    test "Keyword is a subdocument with category and phrase", %{by_id: by_id} do
      keyword = by_id["Keyword"]

      assert Map.has_key?(keyword, "@subdocument")
      assert keyword["category"] == "xsd:string"
      assert keyword["phrase"] == "xsd:string"
    end
  end
end
