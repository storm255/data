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

  describe "nested anchor/candidate navigation" do
    test "sidebar top level lists one entry per cluster, labeled by its anchor", %{conn: conn} do
      roles = [
        role("Role/Laundry+", "Laundry Attendant", "differentiated"),
        role("Role/LaundryLinen+", "Laundry Attendant / Linen Attendant"),
        role("Role/Bartender+", "Bartender", "differentiated")
      ]

      conn = stub_conn(conn, roles_and_relations_responder(roles, []))
      {:ok, _view, html} = live(conn, ~p"/skill_taxonomy/reconciliation")

      assert html =~ "Laundry Attendant"
      refute html =~ "Bartender"
    end

    test "selecting a cluster auto-selects its first candidate and shows the pairwise comparison",
         %{conn: conn} do
      roles = [
        role("Role/Laundry+", "Laundry Attendant", "differentiated"),
        role("Role/LaundryLinen+", "Laundry Attendant / Linen Attendant")
      ]

      conn = stub_conn(conn, roles_and_relations_responder(roles, []))
      {:ok, view, html} = live(conn, ~p"/skill_taxonomy/reconciliation")

      assert html =~ "Laundry Attendant / Linen Attendant"
      assert has_element?(view, "[data-candidate-item='Role/LaundryLinen+'].selected")
    end

    test "a candidate that is itself differentiated cannot be merged, but other actions remain",
         %{
           conn: conn
         } do
      roles = [
        role("Role/A+", "Baker", "differentiated"),
        role("Role/B+", "Baker / Bakery Chef", "differentiated"),
        role("Role/C+", "Baker Bakery Chef Assistant", "stub")
      ]

      conn = stub_conn(conn, roles_and_relations_responder(roles, []))
      {:ok, view, _html} = live(conn, ~p"/skill_taxonomy/reconciliation")

      # anchor is "Baker" (alphabetically-first differentiated); default
      # selected candidate is "Baker / Bakery Chef" (alphabetically next)
      refute has_element?(view, "button[phx-click='merge']")
      assert has_element?(view, "button", "Not related")
    end

    test "a pair with an existing relation between them is not offered as a candidate", %{
      conn: conn
    } do
      roles = [
        role("Role/A+", "Laundry Attendant", "differentiated"),
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
  end

  describe "merge (pairwise — one candidate at a time)" do
    test "clicking merge merges only the selected candidate, calling ClusterResolver.merge", %{
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

      view |> element("button[phx-click='merge']") |> render_click()

      calls = Agent.get(agent, & &1) |> Enum.reverse()
      assert Enum.any?(calls, &match?({:put_role, %{"@id" => "Role/Laundry+"}}, &1))
      assert Enum.any?(calls, &(&1 == :delete))
    end

    test "with three members, merging one candidate leaves the other still selectable afterward",
         %{conn: conn} do
      # This is the concrete case that motivated pairwise review: a
      # cluster with multiple candidates where only some are actually
      # duplicates — merging one must not force a decision on the rest.
      #
      # `live/2` renders twice (static then connected), each calling
      # `mount/3` — so the responder's "have we merged yet" state must
      # track the real DELETE call the merge performs, not a render
      # ordinal, or the second render would already see post-merge data
      # before the test ever clicks anything.
      {:ok, merged?} = Agent.start_link(fn -> false end)

      roles1 = [
        role("Role/Laundry+", "Laundry Attendant", "differentiated"),
        role("Role/LaundryLinen1+", "Laundry Attendant / Linen Attendant"),
        role("Role/LaundryLinen2+", "Laundry/Linen Attendant")
      ]

      # After merging the first candidate away, the second is still there.
      roles2 = [
        role("Role/Laundry+", "Laundry Attendant", "differentiated"),
        role("Role/LaundryLinen2+", "Laundry/Linen Attendant")
      ]

      responder = fn
        :post, _url, %{"query" => %{"@type" => "Role"}} ->
          if Agent.get(merged?, & &1), do: {200, roles2}, else: {200, roles1}

        :post,
        _url,
        %{"query" => %{"@type" => "RoleRelation", "from" => "Role/LaundryLinen1+"}} ->
          {200, []}

        :post, _url, %{"query" => %{"@type" => "RoleRelation", "to" => "Role/LaundryLinen1+"}} ->
          {200, []}

        :post, _url, %{"query" => %{"@type" => "RoleRelation"}} ->
          {200, []}

        :get, _url, _body ->
          {200, role("Role/Laundry+", "Laundry Attendant", "differentiated")}

        :put, _url, %{"@type" => "Role"} = body ->
          {200, ["terminusdb:///data/#{body["@id"]}"]}

        :delete, _url, _body ->
          Agent.update(merged?, fn _ -> true end)
          {200, %{"api:status" => "api:success"}}
      end

      conn = stub_conn(conn, responder)
      {:ok, view, html} = live(conn, ~p"/skill_taxonomy/reconciliation")
      assert html =~ "Laundry Attendant / Linen Attendant"
      assert html =~ "Laundry/Linen Attendant"

      view |> element("[data-candidate-item='Role/LaundryLinen1+']") |> render_click()
      view |> element("button[phx-click='merge']") |> render_click()

      # cluster (anchored on "Laundry Attendant") is still reachable, now
      # with only "Laundry/Linen Attendant" left to decide on
      assert has_element?(view, "[data-candidate-item='Role/LaundryLinen2+']")
    end
  end

  describe "mark_unrelated (pairwise)" do
    test "marks just the selected candidate as unrelated to the anchor", %{conn: conn} do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      roles = [
        role("Role/A+", "Laundry Attendant", "differentiated"),
        role("Role/B+", "Laundry Attendant / Linen Attendant")
      ]

      responder = fn
        :post, _url, %{"query" => %{"@type" => "Role"}} ->
          {200, roles}

        :post, _url, %{"query" => %{"@type" => "RoleRelation"}} ->
          {200, []}

        :put, _url, %{"@type" => "RoleRelation"} = body ->
          Agent.update(agent, &[body | &1])
          {200, ["terminusdb:///data/RoleRelation/x"]}
      end

      conn = stub_conn(conn, responder)
      {:ok, view, _html} = live(conn, ~p"/skill_taxonomy/reconciliation")

      view |> element("button", "Not related") |> render_click()

      [written] = Agent.get(agent, & &1)
      assert written["relation_type"] == "easy_negative"
      assert written["from"] == "Role/A+"
      assert written["to"] == "Role/B+"
    end
  end

  describe "drag widget" do
    test "renders small unlabeled handles, with names shown as plain HTML text outside the SVG",
         %{conn: conn} do
      roles = [
        role("Role/Laundry+", "Laundry Attendant", "differentiated"),
        role("Role/LaundryLinen+", "Laundry Attendant / Linen Attendant")
      ]

      conn = stub_conn(conn, roles_and_relations_responder(roles, []))
      {:ok, view, html} = live(conn, ~p"/skill_taxonomy/reconciliation")

      assert has_element?(view, "svg[data-reference-id='Role/Laundry+'][phx-hook]")
      assert has_element?(view, "g[data-candidate-id='Role/LaundryLinen+']")
      refute has_element?(view, "svg text")
      assert html =~ "Laundry Attendant / Linen Attendant"
    end

    test "shows a legend explaining what each ring threshold means", %{conn: conn} do
      roles = [
        role("Role/A+", "Laundry Attendant", "differentiated"),
        role("Role/B+", "Laundry Attendant / Linen Attendant")
      ]

      conn = stub_conn(conn, roles_and_relations_responder(roles, []))
      {:ok, _view, html} = live(conn, ~p"/skill_taxonomy/reconciliation")

      assert html =~ "close" or html =~ "Close"
      assert html =~ "related" or html =~ "Related"

      assert html =~ "unrelated" or html =~ "Unrelated" or html =~ "not related" or
               html =~ "Not related"
    end

    test "candidate_positioned writes a sibling relation between anchor and the selected candidate",
         %{conn: conn} do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      roles = [
        role("Role/Laundry+", "Laundry Attendant", "differentiated"),
        role("Role/LaundryLinen+", "Laundry Attendant / Linen Attendant")
      ]

      responder = fn
        :post, _url, %{"query" => %{"@type" => "Role"}} ->
          {200, roles}

        :post, _url, %{"query" => %{"@type" => "RoleRelation"}} ->
          {200, []}

        :put, _url, %{"@type" => "RoleRelation"} = body ->
          Agent.update(agent, &[body | &1])
          {200, ["terminusdb:///data/RoleRelation/x"]}
      end

      conn = stub_conn(conn, responder)
      {:ok, view, _html} = live(conn, ~p"/skill_taxonomy/reconciliation")

      view
      |> element("svg[data-reference-id='Role/Laundry+']")
      |> render_hook("candidate_positioned", %{
        "candidate_id" => "Role/LaundryLinen+",
        "distance" => "0.3"
      })

      [written] = Agent.get(agent, & &1)
      assert written["from"] == "Role/Laundry+"
      assert written["to"] == "Role/LaundryLinen+"
      assert written["relation_type"] == "sibling"
      assert_in_delta written["weight"], 0.7, 0.0001
    end

    test "candidate_excluded writes an easy_negative relation", %{conn: conn} do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      roles = [
        role("Role/Laundry+", "Laundry Attendant", "differentiated"),
        role("Role/LaundryLinen+", "Laundry Attendant / Linen Attendant")
      ]

      responder = fn
        :post, _url, %{"query" => %{"@type" => "Role"}} ->
          {200, roles}

        :post, _url, %{"query" => %{"@type" => "RoleRelation"}} ->
          {200, []}

        :put, _url, %{"@type" => "RoleRelation"} = body ->
          Agent.update(agent, &[body | &1])
          {200, ["terminusdb:///data/RoleRelation/x"]}
      end

      conn = stub_conn(conn, responder)
      {:ok, view, _html} = live(conn, ~p"/skill_taxonomy/reconciliation")

      view
      |> element("svg[data-reference-id='Role/Laundry+']")
      |> render_hook("candidate_excluded", %{"candidate_id" => "Role/LaundryLinen+"})

      [written] = Agent.get(agent, & &1)
      assert written["relation_type"] == "easy_negative"
    end
  end

  test "an empty stub list renders without error", %{conn: conn} do
    conn = stub_conn(conn, roles_and_relations_responder([], []))
    {:ok, _view, html} = live(conn, ~p"/skill_taxonomy/reconciliation")
    assert html =~ "Reconciliation"
  end
end
