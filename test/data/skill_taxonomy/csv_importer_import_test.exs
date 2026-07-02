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
end
