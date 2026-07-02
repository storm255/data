defmodule DataWeb.SkillTaxonomy.ReconciliationLiveTest do
  use DataWeb.ConnCase

  import Phoenix.LiveViewTest

  # Same session-injected-config seam as RoleLiveTest.
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

  defp role(id, primary_name, status \\ "stub") do
    %{
      "@id" => id,
      "@type" => "Role",
      "primary_name" => primary_name,
      "status" => status,
      "synonyms" => [],
      "locale" => "en"
    }
  end

  defp roles_and_relations_responder(roles, relations) do
    fn
      :post, _url, %{"query" => %{"@type" => "Role"}} -> {200, roles}
      :post, _url, %{"query" => %{"@type" => "RoleRelation"}} -> {200, relations}
    end
  end

  test "lists an auto-mergeable cluster with a merge-into-canonical button", %{conn: conn} do
    roles = [
      role("Role/Laundry+", "Laundry Attendant", "differentiated"),
      role("Role/LaundryLinen+", "Laundry Attendant / Linen Attendant"),
      role("Role/Bartender+", "Bartender", "differentiated")
    ]

    conn = stub_conn(conn, roles_and_relations_responder(roles, []))
    {:ok, _view, html} = live(conn, ~p"/skill_taxonomy/reconciliation")

    assert html =~ "Laundry Attendant"
    assert html =~ "Laundry Attendant / Linen Attendant"
    assert html =~ "Merge"
    refute html =~ "Bartender"
  end

  test "a cluster of all stubs shows a pick-canonical form, not a single merge button", %{
    conn: conn
  } do
    roles = [role("Role/A+", "Kitchen Steward"), role("Role/B+", "Steward / Kitchen Steward")]

    conn = stub_conn(conn, roles_and_relations_responder(roles, []))
    {:ok, view, html} = live(conn, ~p"/skill_taxonomy/reconciliation")

    assert html =~ "Kitchen Steward"
    assert has_element?(view, "form[phx-submit=merge] input[type=radio]")
  end

  test "a cluster with two differentiated roles is shown as needing manual review, no merge action",
       %{conn: conn} do
    roles = [
      role("Role/A+", "Baker", "differentiated"),
      role("Role/B+", "Baker / Bakery Chef", "differentiated"),
      role("Role/C+", "Baker Bakery Chef Assistant", "stub")
    ]

    conn = stub_conn(conn, roles_and_relations_responder(roles, []))
    {:ok, _view, html} = live(conn, ~p"/skill_taxonomy/reconciliation")

    assert html =~ "needs manual review" or html =~ "Needs manual review"
    refute html =~ "phx-click=\"merge\""
  end

  test "a pair with an existing relation between them is not shown at all", %{conn: conn} do
    roles = [
      role("Role/A+", "Laundry Attendant"),
      role("Role/B+", "Laundry Attendant / Linen Attendant")
    ]

    relations = [
      %{
        "@type" => "RoleRelation",
        "from" => "Role/A+",
        "to" => "Role/B+",
        "relation_type" => "easy_negative",
        "confidence" => "sure",
        "weight" => 1.0
      }
    ]

    conn = stub_conn(conn, roles_and_relations_responder(roles, relations))
    {:ok, _view, html} = live(conn, ~p"/skill_taxonomy/reconciliation")

    refute html =~ "Laundry Attendant / Linen Attendant"
  end

  test "clicking merge on an auto-mergeable cluster calls ClusterResolver.merge and reloads the list",
       %{
         conn: conn
       } do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    roles = [
      role("Role/Laundry+", "Laundry Attendant", "differentiated"),
      role("Role/LaundryLinen+", "Laundry Attendant / Linen Attendant")
    ]

    responder = fn
      :post, _url, %{"query" => %{"@type" => "Role"}} ->
        {200, roles}

      :post, _url, %{"query" => %{"@type" => "RoleRelation", "from" => "Role/LaundryLinen+"}} ->
        {200, []}

      :post, _url, %{"query" => %{"@type" => "RoleRelation", "to" => "Role/LaundryLinen+"}} ->
        {200, []}

      :post, _url, %{"query" => %{"@type" => "RoleRelation"}} ->
        {200, []}

      :get, _url, _body ->
        {200, role("Role/Laundry+", "Laundry Attendant", "differentiated")}

      :put, _url, %{"@type" => "Role"} = body ->
        Agent.update(agent, &[{:put_role, body} | &1])
        {200, ["terminusdb:///data/#{body["@id"]}"]}

      :delete, _url, _body ->
        Agent.update(agent, &[:delete | &1])
        {200, %{"api:status" => "api:success"}}
    end

    conn = stub_conn(conn, responder)
    {:ok, view, _html} = live(conn, ~p"/skill_taxonomy/reconciliation")

    view |> element("button", "Merge") |> render_click()

    calls = Agent.get(agent, & &1) |> Enum.reverse()
    assert Enum.any?(calls, &match?({:put_role, %{"@id" => "Role/Laundry+"}}, &1))
    assert Enum.any?(calls, &(&1 == :delete))
  end

  test "an empty stub list renders without error", %{conn: conn} do
    conn = stub_conn(conn, roles_and_relations_responder([], []))
    {:ok, _view, html} = live(conn, ~p"/skill_taxonomy/reconciliation")
    assert html =~ "Reconciliation"
  end
end
