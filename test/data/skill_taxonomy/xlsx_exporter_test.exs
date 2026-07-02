defmodule Data.SkillTaxonomy.XlsxExporterTest do
  use ExUnit.Case, async: true

  alias Data.SkillTaxonomy.XlsxExporter

  # Document.get(id: ...) sends the id as a query param, not part of the
  # URL path — Document.query/3 POSTs the template as the request body
  # instead; Document.get(type: ...) (the :all scope) is a GET with no
  # id param. Same stub shape as RoleLoaderTest, since XlsxExporter does
  # the same kind of role+relations+target fetch.
  defp stub_config(responder) do
    TerminusDB.Config.new(
      endpoint: "http://stub.local",
      adapter: fn req ->
        case req.method do
          :get ->
            id = URI.decode_query(req.url.query || "")["id"]
            {status, body} = responder.(:get, id)
            {req, Req.Response.new(status: status, body: body)}

          :post ->
            query = req.body |> IO.iodata_to_binary() |> Jason.decode!() |> Map.fetch!("query")
            {status, body} = responder.(:post, query)
            {req, Req.Response.new(status: status, body: body)}
        end
      end
    )
    |> TerminusDB.Config.with_database("test_db")
  end

  defp role_doc(overrides) do
    Map.merge(
      %{
        "@id" => "Role/Bartender+",
        "@type" => "Role",
        "primary_name" => "Bartender",
        "context" => "",
        "locale" => "en",
        "industry" => "Hospitality / F&B",
        "description" => "Mixes and serves drinks.",
        "status" => "differentiated",
        "synonyms" => [],
        "keywords" => []
      },
      overrides
    )
  end

  defp sheets(content) do
    {:ok, sheets} = Spreadsheet.parse(content, format: :binary)
    Map.new(sheets)
  end

  defp find_row(rows, label) do
    rows
    |> Enum.find(fn row -> match?([^label | _], row) end)
    |> trim_trailing_nils()
  end

  # Spreadsheet.parse/2 pads every row out to the sheet's widest row, so
  # short rows come back with trailing nils that aren't meaningful data.
  defp trim_trailing_nils(nil), do: nil

  defp trim_trailing_nils(row),
    do: Enum.reverse(row) |> Enum.drop_while(&is_nil/1) |> Enum.reverse()

  describe "export/2 — a single named role" do
    test "Role Summary block round-trips primary/description/locale/industry" do
      config =
        stub_config(fn
          :post, %{"@type" => "Role", "primary_name" => "Bartender", "context" => ""} ->
            {200, [role_doc(%{})]}

          :post, %{"@type" => "RoleRelation"} ->
            {200, []}
        end)

      assert {:ok, content} = XlsxExporter.export(config, [{"Bartender", ""}])
      sheet = sheets(content)["Bartender"]

      assert find_row(sheet, "Primary Role") == ["Primary Role", "Bartender"]
      assert find_row(sheet, "Description") == ["Description", "Mixes and serves drinks."]
      assert find_row(sheet, "Locale / Language") == ["Locale / Language", "en"]
      assert find_row(sheet, "Industry / Context") == ["Industry / Context", "Hospitality / F&B"]
    end

    test "synonyms become one Synonym row each, Local-language term left blank (not stored per-pairing)" do
      role =
        role_doc(%{
          "synonyms" => [
            %{
              "@type" => "Synonym",
              "term" => "barkeep",
              "locale" => "en",
              "confidence" => "sure"
            },
            %{"@type" => "Synonym", "term" => "แม่บ้านบาร์", "locale" => "en"}
          ]
        })

      config =
        stub_config(fn
          :post, %{"@type" => "Role"} -> {200, [role]}
          :post, %{"@type" => "RoleRelation"} -> {200, []}
        end)

      assert {:ok, content} = XlsxExporter.export(config, [{"Bartender", ""}])
      sheet = sheets(content)["Bartender"]

      synonym_rows = Enum.filter(sheet, &match?(["Synonym" | _], &1))
      terms = Enum.map(synonym_rows, &Enum.at(&1, 1)) |> Enum.sort()

      assert terms == Enum.sort(["barkeep", "แม่บ้านบาร์"])
      assert Enum.all?(synonym_rows, &(Enum.at(&1, 2) in [nil, ""]))
    end

    test "a supporting relation resolves its Skill target's name and carries notes/relationship_detail/confidence" do
      config =
        stub_config(fn
          :post, %{"@type" => "Role", "primary_name" => "Bartender"} ->
            {200, [role_doc(%{})]}

          :post, %{"@type" => "RoleRelation", "from" => "Role/Bartender+"} ->
            {200,
             [
               %{
                 "@type" => "RoleRelation",
                 "from" => "Role/Bartender+",
                 "to" => "Skill/cocktail%20prep+",
                 "relation_type" => "supporting",
                 "confidence" => "sure",
                 "notes" => "Core signal",
                 "relationship_detail" => "primary tool skill",
                 "weight" => 1.0
               }
             ]}

          :get, "Skill/cocktail%20prep+" ->
            {200,
             %{"@id" => "Skill/cocktail%20prep+", "@type" => "Skill", "name" => "cocktail prep"}}
        end)

      assert {:ok, content} = XlsxExporter.export(config, [{"Bartender", ""}])
      sheet = sheets(content)["Bartender"]

      row = find_row(sheet, "Supporting Skill")

      assert row == [
               "Supporting Skill",
               "cocktail prep",
               nil,
               "primary tool skill",
               "Core signal",
               "sure"
             ]
    end

    test "type_of and sibling relations both render as Related Role, relationship_detail preserved verbatim" do
      config =
        stub_config(fn
          :post, %{"@type" => "Role", "primary_name" => "Bartender"} ->
            {200, [role_doc(%{})]}

          :post, %{"@type" => "RoleRelation", "from" => "Role/Bartender+"} ->
            {200,
             [
               %{
                 "@type" => "RoleRelation",
                 "from" => "Role/Bartender+",
                 "to" => "Role/Mixology%20Lead+",
                 "relation_type" => "type_of",
                 "confidence" => "sure",
                 "relationship_detail" => "parent category",
                 "weight" => 1.0
               },
               %{
                 "@type" => "RoleRelation",
                 "from" => "Role/Bartender+",
                 "to" => "Role/Barista+",
                 "relation_type" => "sibling",
                 "confidence" => "guess",
                 "weight" => 1.0
               }
             ]}

          :get, "Role/Mixology%20Lead+" ->
            {200,
             %{
               "@id" => "Role/Mixology%20Lead+",
               "primary_name" => "Mixology Lead",
               "context" => ""
             }}

          :get, "Role/Barista+" ->
            {200, %{"@id" => "Role/Barista+", "primary_name" => "Barista", "context" => ""}}
        end)

      assert {:ok, content} = XlsxExporter.export(config, [{"Bartender", ""}])
      rows = Enum.filter(sheets(content)["Bartender"], &match?(["Related Role" | _], &1))

      assert ["Related Role", "Mixology Lead", nil, "parent category", nil, "sure"] in rows
      assert ["Related Role", "Barista", nil, nil, nil, "guess"] in rows
    end

    test "requesting a role that doesn't exist is an error" do
      config = stub_config(fn :post, %{"@type" => "Role"} -> {200, []} end)

      assert {:error, _reason} = XlsxExporter.export(config, [{"Nonexistent Role", ""}])
    end
  end

  describe "export/2 — :all scope" do
    test "exports every Role in the database, one sheet each, plus a Role Index sheet" do
      config =
        stub_config(fn
          :get, nil ->
            {200,
             [
               role_doc(%{"@id" => "Role/Bartender+", "primary_name" => "Bartender"}),
               role_doc(%{
                 "@id" => "Role/Domestic%20Maid+",
                 "primary_name" => "Domestic Maid",
                 "status" => "stub",
                 "locale" => "",
                 "industry" => "",
                 "description" => nil
               })
             ]}

          :post, %{"@type" => "RoleRelation"} ->
            {200, []}
        end)

      assert {:ok, content} = XlsxExporter.export(config, :all)
      all = sheets(content)

      assert Map.has_key?(all, "Bartender")
      assert Map.has_key?(all, "Domestic Maid")
      assert Map.has_key?(all, "Role Index")

      index_rows = all["Role Index"]
      assert Enum.any?(index_rows, &match?(["Bartender" | _], &1))
      assert Enum.any?(index_rows, &match?(["Domestic Maid" | _], &1))
    end
  end
end
