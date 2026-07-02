defmodule DataWeb.SkillTaxonomy.ReconciliationLive do
  @moduledoc """
  Lists close-named `Role` clusters (`Data.SkillTaxonomy.Reconciliation`)
  and lets a human resolve each one via
  `Data.SkillTaxonomy.ClusterResolver` — the stub/near-duplicate
  reconciliation view from design doc §9 roadmap item 8 / §11.

  Phase 1 only: merge (auto-mergeable and pick-canonical clusters) and
  mark-unrelated (two-member clusters only). Clusters needing a human
  weight decision (keep-separate-but-related) render as needing manual
  review for now — the drag-and-drop weight widget is a separate,
  larger follow-on (design doc §11 "Phase 2").

  The `TerminusDB.Config` used comes from the connect session
  (`"terminus_config"`), falling back to `Data.TerminusDB.config/0` —
  the same seam `RoleLive` uses for test stubbing.
  """

  use DataWeb, :live_view

  alias Data.SkillTaxonomy.{ClusterResolver, Reconciliation}

  @impl true
  def mount(_params, session, socket) do
    config = Map.get(session, "terminus_config") || Data.TerminusDB.config()
    {:ok, socket |> assign(config: config) |> load_reviewable()}
  end

  defp load_reviewable(socket) do
    config = socket.assigns.config

    with {:ok, roles} <- TerminusDB.Document.query(config, %{"@type" => "Role"}),
         {:ok, relations} <- TerminusDB.Document.query(config, %{"@type" => "RoleRelation"}) do
      already_related = MapSet.new(relations, fn r -> {r["from"], r["to"]} end)

      reviewable =
        roles
        |> Reconciliation.cluster(0.75, already_related)
        |> Enum.map(&Reconciliation.classify/1)
        |> Enum.reject(&(&1 == :no_action_needed))
        |> Enum.with_index()
        |> Enum.map(fn {classification, index} ->
          %{index: index, classification: classification}
        end)

      assign(socket, reviewable: reviewable, error: nil)
    else
      {:error, reason} -> assign(socket, reviewable: [], error: inspect(reason))
    end
  end

  @impl true
  def handle_event("merge", %{"index" => index, "canonical_id" => canonical_id}, socket) do
    index = String.to_integer(index)
    item = Enum.find(socket.assigns.reviewable, &(&1.index == index))

    duplicate_ids =
      item
      |> members()
      |> Enum.map(& &1["@id"])
      |> List.delete(canonical_id)

    case ClusterResolver.merge(socket.assigns.config, canonical_id, duplicate_ids) do
      {:ok, summary} ->
        {:noreply,
         socket
         |> put_flash(:info, "Merged #{summary.merged} role(s) into the canonical role.")
         |> load_reviewable()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Merge failed: #{inspect(reason)}")}
    end
  end

  def handle_event("mark_unrelated", %{"index" => index}, socket) do
    index = String.to_integer(index)
    item = Enum.find(socket.assigns.reviewable, &(&1.index == index))

    case members(item) do
      [role_a, role_b] ->
        case ClusterResolver.mark_unrelated(socket.assigns.config, role_a["@id"], role_b["@id"]) do
          {:ok, _id} ->
            {:noreply,
             socket
             |> put_flash(
               :info,
               "Marked #{role_a["primary_name"]} and #{role_b["primary_name"]} as unrelated."
             )
             |> load_reviewable()}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Failed: #{inspect(reason)}")}
        end
    end
  end

  defp members(%{classification: {:auto_mergeable, canonical, duplicates}}),
    do: [canonical | duplicates]

  defp members(%{classification: {:pick_canonical, candidates}}), do: candidates
  defp members(%{classification: {:needs_manual_review, cluster}}), do: cluster

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-3xl mx-auto">
      <.header>Stub Reconciliation</.header>

      <p :if={@error} class="alert alert-error">{@error}</p>

      <p :if={@reviewable == [] && !@error}>No clusters need review right now.</p>

      <div :for={item <- @reviewable} class="border rounded p-4 mb-4" data-cluster-index={item.index}>
        <ul class="mb-2">
          <li :for={role <- members(item)}>
            {role["primary_name"]}
            <span class="badge">{role["status"]}</span>
          </li>
        </ul>

        {render_action(assigns, item)}

        <button
          :if={
            length(members(item)) == 2 and not match?({:needs_manual_review, _}, item.classification)
          }
          type="button"
          phx-click="mark_unrelated"
          phx-value-index={item.index}
          class="btn btn-soft"
        >
          Not related
        </button>
      </div>
    </div>
    """
  end

  defp render_action(assigns, %{classification: {:auto_mergeable, canonical, _duplicates}} = item) do
    assigns = assign(assigns, canonical: canonical, index: item.index)

    ~H"""
    <button
      type="button"
      phx-click="merge"
      phx-value-index={@index}
      phx-value-canonical_id={@canonical["@id"]}
      class="btn btn-primary btn-soft"
    >
      Merge into "{@canonical["primary_name"]}"
    </button>
    """
  end

  defp render_action(assigns, %{classification: {:pick_canonical, candidates}} = item) do
    assigns = assign(assigns, candidates: candidates, index: item.index)

    ~H"""
    <form phx-submit="merge">
      <input type="hidden" name="index" value={@index} />
      <label :for={candidate <- @candidates}>
        <input type="radio" name="canonical_id" value={candidate["@id"]} /> {candidate["primary_name"]}
      </label>
      <button type="submit" class="btn btn-primary btn-soft">Merge</button>
    </form>
    """
  end

  defp render_action(assigns, %{classification: {:needs_manual_review, _cluster}}) do
    ~H"""
    <p class="text-warning">Needs manual review — multiple differentiated roles in this cluster.</p>
    """
  end
end
