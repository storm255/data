defmodule Data.SkillTaxonomy.ClusterResolverTest do
  use ExUnit.Case, async: true

  alias Data.SkillTaxonomy.ClusterResolver

  # Same stub-adapter pattern as importer_test.exs/role_loader_test.exs:
  # GETs (Document.get) carry the id as a query param, decoded via
  # req.url.query; POSTs (Document.query) carry a "query" template in
  # the body; PUTs (Document.replace) and DELETEs carry the full
  # document/id being written.
  defp stub_config(responder) do
    TerminusDB.Config.new(
      endpoint: "http://stub.local",
      adapter: fn req ->
        body = if req.body, do: req.body |> IO.iodata_to_binary() |> Jason.decode!()
        query = URI.decode_query(req.url.query || "")
        {status, response_body} = responder.(req.method, query, body)
        {req, Req.Response.new(status: status, body: response_body)}
      end
    )
    |> TerminusDB.Config.with_database("test_db")
  end

  defp role(id, primary_name, overrides \\ %{}) do
    Map.merge(
      %{
        "@id" => id,
        "@type" => "Role",
        "primary_name" => primary_name,
        "context" => "",
        "locale" => "en",
        "industry" => "hospitality",
        "status" => "differentiated",
        "synonyms" => []
      },
      overrides
    )
  end

  describe "merge/3" do
    test "folds a duplicate's primary_name into canonical's synonyms, then deletes the duplicate" do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      config =
        stub_config(fn method, query, body ->
          Agent.update(agent, &[{method, query, body} | &1])

          case {method, query, body} do
            {:get, %{"id" => "Role/Canonical+"}, _} ->
              {200, role("Role/Canonical+", "Laundry Attendant")}

            {:get, %{"id" => "Role/Dup+"}, _} ->
              {200,
               role("Role/Dup+", "Laundry Attendant / Linen Attendant", %{"status" => "stub"})}

            {:post, _, %{"query" => %{"@type" => "RoleRelation", "from" => "Role/Dup+"}}} ->
              {200, []}

            {:post, _, %{"query" => %{"@type" => "RoleRelation", "to" => "Role/Dup+"}}} ->
              {200, []}

            {:put, _, %{"@type" => "Role", "@id" => "Role/Canonical+"}} ->
              {200, ["terminusdb:///data/Role/Canonical+"]}

            {:delete, %{"id" => "Role/Dup+"}, _} ->
              {200, %{"api:status" => "api:success"}}
          end
        end)

      assert {:ok, summary} = ClusterResolver.merge(config, "Role/Canonical+", ["Role/Dup+"])
      assert summary.merged == 1

      canonical_write =
        Agent.get(agent, & &1)
        |> Enum.reverse()
        |> Enum.find_value(fn
          {:put, _, %{"@type" => "Role", "@id" => "Role/Canonical+"} = body} -> body
          _ -> nil
        end)

      assert canonical_write["synonyms"] == [
               %{
                 "@type" => "Synonym",
                 "term" => "Laundry Attendant / Linen Attendant",
                 "locale" => "en"
               }
             ]

      assert Enum.any?(Agent.get(agent, & &1), &match?({:delete, %{"id" => "Role/Dup+"}, _}, &1))
    end

    test "folds a duplicate's own synonyms too, deduped by {term, locale} against canonical's existing ones" do
      config =
        stub_config(fn
          _method, %{"id" => "Role/Canonical+"}, _body ->
            {200,
             role("Role/Canonical+", "Laundry Attendant", %{
               "synonyms" => [
                 %{"@type" => "Synonym", "term" => "Linen Attendant", "locale" => "en"}
               ]
             })}

          _method, %{"id" => "Role/Dup+"}, _body ->
            {200,
             role("Role/Dup+", "Laundry Attendant / Linen Attendant", %{
               "status" => "stub",
               "synonyms" => [
                 %{"@type" => "Synonym", "term" => "Linen Attendant", "locale" => ""}
               ]
             })}

          :post, _query, %{"query" => %{"@type" => "RoleRelation"}} ->
            {200, []}

          :put, _query, %{"@type" => "Role"} = body ->
            {200, ["terminusdb:///data/#{body["@id"]}"]}

          :delete, _query, nil ->
            {200, %{"api:status" => "api:success"}}
        end)

      assert {:ok, _summary} = ClusterResolver.merge(config, "Role/Canonical+", ["Role/Dup+"])
    end

    test "repoints relations pointing at the duplicate to the canonical, both from and to sides" do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      config =
        stub_config(fn method, query, body ->
          Agent.update(agent, &[{method, query, body} | &1])

          case {method, query, body} do
            {:get, %{"id" => "Role/Canonical+"}, _} ->
              {200, role("Role/Canonical+", "Laundry Attendant")}

            {:get, %{"id" => "Role/Dup+"}, _} ->
              {200, role("Role/Dup+", "Linen Attendant", %{"status" => "stub"})}

            {:post, _, %{"query" => %{"@type" => "RoleRelation", "from" => "Role/Dup+"}}} ->
              {200,
               [
                 %{
                   "@id" => "RoleRelation/from-dup",
                   "@type" => "RoleRelation",
                   "from" => "Role/Dup+",
                   "to" => "Skill/washing+",
                   "relation_type" => "supporting",
                   "confidence" => "sure",
                   "weight" => 1.0
                 }
               ]}

            {:post, _, %{"query" => %{"@type" => "RoleRelation", "to" => "Role/Dup+"}}} ->
              {200,
               [
                 %{
                   "@id" => "RoleRelation/to-dup",
                   "@type" => "RoleRelation",
                   "from" => "Role/Housekeeper+",
                   "to" => "Role/Dup+",
                   "relation_type" => "hard_negative",
                   "confidence" => "sure",
                   "weight" => 1.0
                 }
               ]}

            {:post, _,
             %{
               "query" => %{
                 "@type" => "RoleRelation",
                 "from" => "Role/Canonical+",
                 "to" => "Skill/washing+",
                 "relation_type" => "supporting"
               }
             }} ->
              {200, []}

            {:post, _,
             %{
               "query" => %{
                 "@type" => "RoleRelation",
                 "from" => "Role/Housekeeper+",
                 "to" => "Role/Canonical+",
                 "relation_type" => "hard_negative"
               }
             }} ->
              {200, []}

            {:put, _, %{"@type" => "Role"}} ->
              {200, ["terminusdb:///data/Role/Canonical+"]}

            {:put, _, %{"@type" => "RoleRelation"} = relation} ->
              {200, ["terminusdb:///data/RoleRelation/rewritten-#{relation["relation_type"]}"]}

            {:delete, %{"id" => id}, _} ->
              {200, %{"api:status" => "api:success", "id" => id}}
          end
        end)

      assert {:ok, _summary} = ClusterResolver.merge(config, "Role/Canonical+", ["Role/Dup+"])

      calls = Agent.get(agent, & &1) |> Enum.reverse()

      assert Enum.any?(calls, fn
               {:put, _,
                %{
                  "@type" => "RoleRelation",
                  "from" => "Role/Canonical+",
                  "to" => "Skill/washing+"
                }} ->
                 true

               _ ->
                 false
             end)

      assert Enum.any?(calls, fn
               {:put, _,
                %{
                  "@type" => "RoleRelation",
                  "from" => "Role/Housekeeper+",
                  "to" => "Role/Canonical+"
                }} ->
                 true

               _ ->
                 false
             end)

      assert Enum.any?(calls, &match?({:delete, %{"id" => "RoleRelation/from-dup"}, _}, &1))
      assert Enum.any?(calls, &match?({:delete, %{"id" => "RoleRelation/to-dup"}, _}, &1))
    end

    test "a relation directly between canonical and the duplicate is dropped, not turned into a self-loop" do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      config =
        stub_config(fn method, query, body ->
          Agent.update(agent, &[{method, query, body} | &1])

          case {method, query, body} do
            {:get, %{"id" => "Role/Canonical+"}, _} ->
              {200, role("Role/Canonical+", "Laundry Attendant")}

            {:get, %{"id" => "Role/Dup+"}, _} ->
              {200, role("Role/Dup+", "Linen Attendant", %{"status" => "stub"})}

            {:post, _, %{"query" => %{"@type" => "RoleRelation", "from" => "Role/Dup+"}}} ->
              {200,
               [
                 %{
                   "@id" => "RoleRelation/dup-to-canonical",
                   "@type" => "RoleRelation",
                   "from" => "Role/Dup+",
                   "to" => "Role/Canonical+",
                   "relation_type" => "sibling",
                   "confidence" => "sure",
                   "weight" => 1.0
                 }
               ]}

            {:post, _, %{"query" => %{"@type" => "RoleRelation", "to" => "Role/Dup+"}}} ->
              {200, []}

            {:put, _, %{"@type" => "Role"}} ->
              {200, ["terminusdb:///data/Role/Canonical+"]}

            {:delete, %{"id" => id}, _} ->
              {200, %{"api:status" => "api:success", "id" => id}}
          end
        end)

      assert {:ok, summary} = ClusterResolver.merge(config, "Role/Canonical+", ["Role/Dup+"])
      assert summary.self_loops_dropped == 1

      calls = Agent.get(agent, & &1)
      refute Enum.any?(calls, &match?({:put, _, %{"@type" => "RoleRelation"}}, &1))

      assert Enum.any?(
               calls,
               &match?({:delete, %{"id" => "RoleRelation/dup-to-canonical"}, _}, &1)
             )
    end

    test "when canonical already has the same relation with a lower weight, the duplicate's higher-weight one wins" do
      config =
        stub_config(fn
          _method, %{"id" => "Role/Canonical+"}, _body ->
            {200, role("Role/Canonical+", "Laundry Attendant")}

          _method, %{"id" => "Role/Dup+"}, _body ->
            {200, role("Role/Dup+", "Linen Attendant", %{"status" => "stub"})}

          :post, _query, %{"query" => %{"@type" => "RoleRelation", "from" => "Role/Dup+"}} ->
            {200,
             [
               %{
                 "@id" => "RoleRelation/from-dup",
                 "@type" => "RoleRelation",
                 "from" => "Role/Dup+",
                 "to" => "Role/Chef+",
                 "relation_type" => "sibling",
                 "confidence" => "guess",
                 "weight" => 0.9
               }
             ]}

          :post, _query, %{"query" => %{"@type" => "RoleRelation", "to" => "Role/Dup+"}} ->
            {200, []}

          :post,
          _query,
          %{
            "query" => %{
              "@type" => "RoleRelation",
              "from" => "Role/Canonical+",
              "to" => "Role/Chef+",
              "relation_type" => "sibling"
            }
          } ->
            {200,
             [
               %{
                 "@id" => "RoleRelation/existing",
                 "@type" => "RoleRelation",
                 "from" => "Role/Canonical+",
                 "to" => "Role/Chef+",
                 "relation_type" => "sibling",
                 "confidence" => "sure",
                 "weight" => 0.3
               }
             ]}

          :put, _query, %{"@type" => "Role"} = body ->
            {200, ["terminusdb:///data/#{body["@id"]}"]}

          :put, _query, %{"@type" => "RoleRelation"} = relation ->
            {200, ["terminusdb:///data/RoleRelation/new-#{relation["weight"]}"]}

          :delete, %{"id" => id}, _ ->
            {200, %{"api:status" => "api:success", "id" => id}}
        end)

      assert {:ok, summary} = ClusterResolver.merge(config, "Role/Canonical+", ["Role/Dup+"])

      assert summary.collisions == [
               %{
                 from: "Role/Canonical+",
                 to: "Role/Chef+",
                 relation_type: "sibling",
                 kept_weight: 0.9
               }
             ]
    end
  end

  describe "keep_separate/4" do
    test "writes a sibling relation with the given weight and confidence sure" do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      config =
        stub_config(fn method, query, body ->
          Agent.update(agent, &[{method, query, body} | &1])
          {200, ["terminusdb:///data/RoleRelation/a-b-sibling"]}
        end)

      assert {:ok, _id} = ClusterResolver.keep_separate(config, "Role/A+", "Role/B+", 0.65)

      [{:put, _query, doc}] = Agent.get(agent, & &1)
      assert doc["@type"] == "RoleRelation"
      assert doc["from"] == "Role/A+"
      assert doc["to"] == "Role/B+"
      assert doc["relation_type"] == "sibling"
      assert doc["confidence"] == "sure"
      assert doc["weight"] == 0.65
    end
  end

  describe "mark_unrelated/3" do
    test "writes an easy_negative relation" do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      config =
        stub_config(fn method, query, body ->
          Agent.update(agent, &[{method, query, body} | &1])
          {200, ["terminusdb:///data/RoleRelation/a-b-easy-negative"]}
        end)

      assert {:ok, _id} = ClusterResolver.mark_unrelated(config, "Role/A+", "Role/B+")

      [{:put, _query, doc}] = Agent.get(agent, & &1)
      assert doc["relation_type"] == "easy_negative"
      assert doc["from"] == "Role/A+"
      assert doc["to"] == "Role/B+"
    end
  end
end
