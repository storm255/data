defmodule DataWeb.SkillTaxonomy.RoleLiveTest do
  use DataWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Data.SkillTaxonomy.CsvImporter

  # Injected via the connect session (see RoleLive's moduledoc) — the same
  # stub-adapter pattern used by CsvImporter's/RoleLoader's tests, so no
  # real network is needed to drive the form end to end.
  defp stub_conn(conn, responder) do
    config =
      TerminusDB.Config.new(
        endpoint: "http://stub.local",
        adapter: fn req ->
          body = if req.body, do: req.body |> IO.iodata_to_binary() |> Jason.decode!()
          {status, response_body} = responder.(req.method, req.url, body)
          {req, Req.Response.new(status: status, body: response_body)}
        end
      )
      |> TerminusDB.Config.with_database("test_db")

    Plug.Test.init_test_session(conn, %{"terminus_config" => config})
  end

  defp always_succeeds(_method, _url, %{"@type" => "Role"}),
    do: {200, ["terminusdb:///data/Role/stub-role"]}

  defp always_succeeds(_method, _url, %{"@type" => "Skill"}),
    do: {200, ["terminusdb:///data/Skill/stub-skill"]}

  defp always_succeeds(_method, _url, %{"@type" => "RoleRelation"}),
    do: {200, ["terminusdb:///data/RoleRelation/stub-relation"]}

  defp always_succeeds(:post, %{path: path}, %{"query" => %{"@type" => "Role"}})
       when is_binary(path),
       do: {200, [%{"primary_name" => "Bartender", "context" => ""}]}

  test "mount renders all seven guide sections as distinct form blocks", %{conn: conn} do
    conn = stub_conn(conn, &always_succeeds/3)
    {:ok, view, html} = live(conn, ~p"/skill_taxonomy/roles/new")

    for label <- [
          "Synonyms",
          "Supporting",
          "Type-of",
          "Sibling",
          "Hard negatives",
          "Easy negatives",
          "Exclusions"
        ] do
      assert html =~ label
    end

    assert has_element?(view, "fieldset[data-field=synonyms]")
    assert has_element?(view, "fieldset[data-field=supporting]")
    assert has_element?(view, "fieldset[data-field=type_of]")
    assert has_element?(view, "fieldset[data-field=sibling]")
    assert has_element?(view, "fieldset[data-field=hard_negatives]")
    assert has_element?(view, "fieldset[data-field=easy_negatives]")
    assert has_element?(view, "fieldset[data-field=exclusions]")
  end

  test "each dynamic list supports add/remove independently of the others", %{conn: conn} do
    conn = stub_conn(conn, &always_succeeds/3)
    {:ok, view, _html} = live(conn, ~p"/skill_taxonomy/roles/new")

    view
    |> form("fieldset[data-field=synonyms] form", %{"text" => "barkeep"})
    |> render_submit()

    view
    |> form("fieldset[data-field=supporting] form", %{"text" => "cocktail prep"})
    |> render_submit()

    html = render(view)
    assert html =~ "barkeep"
    assert html =~ "cocktail prep"

    # removing from synonyms doesn't touch supporting
    view |> element("fieldset[data-field=synonyms] button", "Remove") |> render_click()

    html = render(view)
    refute html =~ "barkeep"
    assert html =~ "cocktail prep"
  end

  test "submitting builds the same documents CsvImporter would for equivalent input", %{
    conn: conn
  } do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    responder = fn method, url, body ->
      Agent.update(agent, &[{method, body} | &1])
      always_succeeds(method, url, body)
    end

    conn = stub_conn(conn, responder)
    {:ok, view, _html} = live(conn, ~p"/skill_taxonomy/roles/new")

    # supporting -> Skill is always self-contained (the skill is created
    # in the same import call); a role target (e.g. hard_negatives)
    # would hit the documented cross-batch-reference gap instead.
    view |> form("fieldset[data-field=synonyms] form", %{"text" => "barkeep"}) |> render_submit()

    view
    |> form("fieldset[data-field=supporting] form", %{"text" => "cocktail prep"})
    |> render_submit()

    view
    |> form("form[phx-submit=save]", %{
      "role" => %{
        "primary" => "Bartender",
        "description" => "",
        "context" => "",
        "locale" => "en",
        "industry" => "hospitality/F&B",
        "confidence" => "guess"
      }
    })
    |> render_submit()

    live_view_bodies =
      Agent.get(agent, & &1) |> Enum.map(fn {_m, body} -> body end) |> Enum.reverse()

    # Same input, built directly through CsvImporter for comparison.
    csv = """
    primary,description,context,synonyms,supporting,type_of,sibling,hard_negatives,easy_negatives,exclusions,locale,industry,confidence
    Bartender,,,barkeep,cocktail prep,,,,,,en,hospitality/F&B,guess
    """

    {:ok, parsed} = CsvImporter.parse(csv)

    {:ok, agent2} = Agent.start_link(fn -> [] end)

    csv_config =
      TerminusDB.Config.new(
        endpoint: "http://stub.local",
        adapter: fn req ->
          body = if req.body, do: req.body |> IO.iodata_to_binary() |> Jason.decode!()
          Agent.update(agent2, &[body | &1])
          {status, response_body} = always_succeeds(req.method, req.url, body)
          {req, Req.Response.new(status: status, body: response_body)}
        end
      )
      |> TerminusDB.Config.with_database("test_db")

    {:ok, _} = CsvImporter.import(csv_config, parsed)
    csv_bodies = Agent.get(agent2, & &1) |> Enum.reverse()

    live_view_roles = Enum.filter(live_view_bodies, &(&1["@type"] == "Role"))
    csv_roles = Enum.filter(csv_bodies, &(&1["@type"] == "Role"))
    assert live_view_roles == csv_roles

    live_view_relations = Enum.filter(live_view_bodies, &(&1["@type"] == "RoleRelation"))
    csv_relations = Enum.filter(csv_bodies, &(&1["@type"] == "RoleRelation"))
    assert live_view_relations == csv_relations
  end

  test "submitting with primary blank shows a validation error and never calls Document.insert",
       %{conn: conn} do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    responder = fn method, url, body ->
      Agent.update(agent, &[body | &1])
      always_succeeds(method, url, body)
    end

    conn = stub_conn(conn, responder)
    {:ok, view, _html} = live(conn, ~p"/skill_taxonomy/roles/new")

    html =
      view
      |> form("form[phx-submit=save]", %{
        "role" => %{
          "primary" => "",
          "description" => "",
          "context" => "",
          "locale" => "en",
          "industry" => "hospitality/F&B",
          "confidence" => "guess"
        }
      })
      |> render_submit()

    assert html =~ "primary"
    assert Agent.get(agent, & &1) == []
  end

  test "editing an existing role pre-fills every section, including list-valued fields", %{
    conn: conn
  } do
    role = %{
      "@id" => "Role/Bartender+",
      "@type" => "Role",
      "primary_name" => "Bartender",
      "context" => "",
      "description" => "Serves drinks",
      "locale" => "en",
      "industry" => "hospitality/F&B",
      "synonyms" => [%{"@type" => "Synonym", "term" => "barkeep", "locale" => "en"}]
    }

    relations = [
      %{
        "@type" => "RoleRelation",
        "from" => "Role/Bartender+",
        "to" => "Skill/cocktail%20prep",
        "relation_type" => "supporting",
        "confidence" => "sure"
      }
    ]

    docs = %{
      "Role/Bartender+" => role,
      "Skill/cocktail%20prep" => %{"@type" => "Skill", "name" => "cocktail prep"}
    }

    responder = fn
      :get, url, _body ->
        id = URI.decode_query(url.query || "")["id"]
        {200, Map.fetch!(docs, id)}

      :post, _url, %{"query" => %{"@type" => "RoleRelation"}} ->
        {200, relations}
    end

    conn = stub_conn(conn, responder)
    {:ok, _view, html} = live(conn, ~p"/skill_taxonomy/roles/edit?id=Role%2FBartender%2B")

    assert html =~ "Serves drinks"
    assert html =~ "barkeep"
    assert html =~ "cocktail prep"
  end
end
