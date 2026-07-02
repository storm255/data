defmodule Data.SkillTaxonomy.CsvImporterImportTest do
  use ExUnit.Case, async: true

  alias Data.SkillTaxonomy.CsvImporter

  # The adapter intercepts the fully-encoded Req request; `req.body` is
  # iodata (Jason's encoder output), not a plain binary — flatten before
  # decoding. See design/SKILLS_TAXONOMY_TEST_PLAN.md Phase 2 for why this
  # stub exists: it tests that import/2 threads a real insert response's
  # id into the next request, not TerminusDB's own encoding behavior.
  defp stub_config(responder) do
    TerminusDB.Config.new(
      endpoint: "http://stub.local",
      adapter: fn req ->
        body = if req.body, do: req.body |> IO.iodata_to_binary() |> Jason.decode!()
        {status, response_body} = responder.(req.method, body)
        {req, Req.Response.new(status: status, body: response_body)}
      end
    )
    |> TerminusDB.Config.with_database("test_db")
  end

  defp parsed_fixture do
    %{
      roles: [
        %{"@type" => "Role", "primary_name" => "Bartender", "context" => "", "synonyms" => []}
      ],
      skills: [%{"@type" => "Skill", "name" => "cocktail prep"}],
      pending_relations: [
        %{
          from: {:role, "Bartender", ""},
          to: {:skill, "cocktail prep"},
          relation_type: "supporting",
          confidence: "guess"
        }
      ],
      warnings: [],
      errors: []
    }
  end

  test "resolves pending relations to the ids the stub's insert responses actually returned" do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    config =
      stub_config(fn method, body ->
        Agent.update(agent, &[{method, body} | &1])

        case body do
          %{"@type" => "Role"} ->
            {200, ["terminusdb:///data/Role/stub-role-id"]}

          %{"@type" => "Skill"} ->
            {200, ["terminusdb:///data/Skill/stub-skill-id"]}

          %{"@type" => "RoleRelation"} ->
            {200, ["terminusdb:///data/RoleRelation/stub-relation-id"]}
        end
      end)

    assert {:ok, _summary} = CsvImporter.import(config, parsed_fixture())

    calls = Agent.get(agent, & &1) |> Enum.reverse()

    relation_body =
      Enum.find_value(calls, fn
        {:put, %{"@type" => "RoleRelation"} = body} -> body
        _ -> nil
      end)

    assert relation_body["from"] == "Role/stub-role-id"
    assert relation_body["to"] == "Skill/stub-skill-id"
    assert relation_body["weight"] == 1.0
    assert relation_body["confidence"] == "guess"
  end

  test "writes via replace(create: true), not insert — re-importing must not error on already-existing documents" do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    config =
      stub_config(fn method, body ->
        Agent.update(agent, &[{method, body} | &1])

        case body do
          %{"@type" => "Role"} ->
            {200, ["terminusdb:///data/Role/stub-role-id"]}

          %{"@type" => "Skill"} ->
            {200, ["terminusdb:///data/Skill/stub-skill-id"]}

          %{"@type" => "RoleRelation"} ->
            {200, ["terminusdb:///data/RoleRelation/stub-relation-id"]}
        end
      end)

    assert {:ok, _} = CsvImporter.import(config, parsed_fixture())

    methods = Agent.get(agent, & &1) |> Enum.map(fn {method, _body} -> method end) |> Enum.uniq()
    assert methods == [:put]
  end

  test "inserts roles and skills before any relation" do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    config =
      stub_config(fn method, body ->
        Agent.update(agent, &[{method, body} | &1])

        case body do
          %{"@type" => "Role"} ->
            {200, ["terminusdb:///data/Role/stub-role-id"]}

          %{"@type" => "Skill"} ->
            {200, ["terminusdb:///data/Skill/stub-skill-id"]}

          %{"@type" => "RoleRelation"} ->
            {200, ["terminusdb:///data/RoleRelation/stub-relation-id"]}
        end
      end)

    assert {:ok, _summary} = CsvImporter.import(config, parsed_fixture())

    types =
      Agent.get(agent, & &1)
      |> Enum.reverse()
      |> Enum.map(fn {_method, body} -> body["@type"] end)

    relation_index = Enum.find_index(types, &(&1 == "RoleRelation"))
    role_index = Enum.find_index(types, &(&1 == "Role"))
    skill_index = Enum.find_index(types, &(&1 == "Skill"))

    assert role_index < relation_index
    assert skill_index < relation_index
  end

  test "an insert failure surfaces as an error rather than continuing with a partial import" do
    config =
      stub_config(fn _method, body ->
        case body do
          %{"@type" => "Role"} -> {400, %{"api:message" => "boom"}}
          _ -> {200, ["terminusdb:///data/x"]}
        end
      end)

    assert {:error, _reason} = CsvImporter.import(config, parsed_fixture())
  end

  describe "stub-creating unresolved role targets" do
    # A hard_negative on a role that isn't in this batch — the design
    # doc §2/§4 case (a relation naming a role that may never get its
    # own sheet). Query requests are POSTs with a top-level "query" key;
    # insert/replace requests are PUTs with "@type" at the top level —
    # structurally distinguishable, so the stub can route accordingly.
    defp fixture_with_unresolved_target(relations) do
      %{
        roles: [
          %{"@type" => "Role", "primary_name" => "Bartender", "context" => "", "synonyms" => []}
        ],
        skills: [],
        pending_relations: relations,
        warnings: [],
        errors: []
      }
    end

    defp hard_negative(target) do
      %{
        from: {:role, "Bartender", ""},
        to: {:role, target, ""},
        relation_type: "hard_negative",
        confidence: "guess"
      }
    end

    test "not found in the batch or live -> creates a stub Role and resolves to it" do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      config =
        stub_config(fn method, body ->
          Agent.update(agent, &[{method, body} | &1])

          case body do
            %{"query" => %{"@type" => "Role"}} ->
              {200, []}

            %{"@type" => "Role", "primary_name" => "Bartender"} ->
              {200, ["terminusdb:///data/Role/bartender-id"]}

            %{"@type" => "Role", "primary_name" => "Domestic Maid"} ->
              {200, ["terminusdb:///data/Role/domestic-maid-id"]}

            %{"@type" => "RoleRelation"} ->
              {200, ["terminusdb:///data/RoleRelation/stub-relation-id"]}
          end
        end)

      fixture = fixture_with_unresolved_target([hard_negative("Domestic Maid")])
      assert {:ok, summary} = CsvImporter.import(config, fixture)
      assert summary.stub_roles == [{"Domestic Maid", ""}]

      stub_body =
        Agent.get(agent, & &1)
        |> Enum.reverse()
        |> Enum.find_value(fn
          {:put, %{"@type" => "Role", "primary_name" => "Domestic Maid"} = body} -> body
          _ -> nil
        end)

      assert stub_body["status"] == "stub"

      relation_body =
        Agent.get(agent, & &1)
        |> Enum.reverse()
        |> Enum.find_value(fn
          {:put, %{"@type" => "RoleRelation"} = body} -> body
          _ -> nil
        end)

      assert relation_body["to"] == "Role/domestic-maid-id"
    end

    test "found via live query -> resolves to the existing document, no stub created" do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      config =
        stub_config(fn method, body ->
          Agent.update(agent, &[{method, body} | &1])

          case body do
            %{"query" => %{"@type" => "Role", "primary_name" => "Domestic Maid"}} ->
              {200,
               [
                 %{
                   "@id" => "Role/Domestic%20Maid+",
                   "primary_name" => "Domestic Maid",
                   "context" => ""
                 }
               ]}

            %{"@type" => "Role", "primary_name" => "Bartender"} ->
              {200, ["terminusdb:///data/Role/bartender-id"]}

            %{"@type" => "RoleRelation"} ->
              {200, ["terminusdb:///data/RoleRelation/stub-relation-id"]}
          end
        end)

      fixture = fixture_with_unresolved_target([hard_negative("Domestic Maid")])
      assert {:ok, summary} = CsvImporter.import(config, fixture)
      assert summary.stub_roles == []

      role_puts =
        Agent.get(agent, & &1)
        |> Enum.filter(fn
          {:put, %{"@type" => "Role"}} -> true
          _ -> false
        end)

      # only Bartender (the batch's own role) was written — Domestic
      # Maid was found, not created.
      assert length(role_puts) == 1

      relation_body =
        Agent.get(agent, & &1)
        |> Enum.reverse()
        |> Enum.find_value(fn
          {:put, %{"@type" => "RoleRelation"} = body} -> body
          _ -> nil
        end)

      assert relation_body["to"] == "Role/Domestic%20Maid+"
    end

    test "two relations naming the same unresolved target only create one stub" do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      config =
        stub_config(fn method, body ->
          Agent.update(agent, &[{method, body} | &1])

          case body do
            %{"query" => %{"@type" => "Role"}} ->
              {200, []}

            %{"@type" => "Role", "primary_name" => "Bartender"} ->
              {200, ["terminusdb:///data/Role/bartender-id"]}

            %{"@type" => "Role", "primary_name" => "Domestic Maid"} ->
              {200, ["terminusdb:///data/Role/domestic-maid-id"]}

            %{"@type" => "RoleRelation"} ->
              {200, ["terminusdb:///data/RoleRelation/stub-relation-id"]}
          end
        end)

      relations = [
        hard_negative("Domestic Maid"),
        %{hard_negative("Domestic Maid") | relation_type: "manual_review"}
      ]

      fixture = fixture_with_unresolved_target(relations)
      assert {:ok, summary} = CsvImporter.import(config, fixture)
      assert summary.stub_roles == [{"Domestic Maid", ""}]

      stub_puts =
        Agent.get(agent, & &1)
        |> Enum.filter(fn
          {:put, %{"@type" => "Role", "primary_name" => "Domestic Maid"}} -> true
          _ -> false
        end)

      assert length(stub_puts) == 1
    end

    test "a failure creating the stub surfaces as an error" do
      config =
        stub_config(fn _method, body ->
          case body do
            %{"query" => %{"@type" => "Role"}} ->
              {200, []}

            %{"@type" => "Role", "primary_name" => "Bartender"} ->
              {200, ["terminusdb:///data/Role/bartender-id"]}

            %{"@type" => "Role", "primary_name" => "Domestic Maid"} ->
              {400, %{"api:message" => "boom"}}
          end
        end)

      fixture = fixture_with_unresolved_target([hard_negative("Domestic Maid")])
      assert {:error, _reason} = CsvImporter.import(config, fixture)
    end
  end
end
