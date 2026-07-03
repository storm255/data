defmodule DataWeb.SkillTaxonomy.ReconciliationLive do
  @moduledoc """
  Lists close-named `Role` clusters (`Data.SkillTaxonomy.Reconciliation`)
  and lets a human resolve each one via
  `Data.SkillTaxonomy.ClusterResolver` — the stub/near-duplicate
  reconciliation view from design doc §9 roadmap item 8 / §11.

  **Pairwise, nested navigation** — "a human only deals with pairs at
  any time" (design doc §11). The sidebar's top level is one entry per
  cluster, labeled by an *anchor* role
  (`Reconciliation.anchor_and_candidates/1` — the alphabetically-first
  differentiated member if any exist, else the alphabetically-first
  member overall); the sub-list is every other cluster member. Selecting
  a sub-item shows a pairwise comparison (anchor vs that one candidate)
  with Merge/Not related/drag-widget scoped to just that pair. This
  replaced an earlier checkbox-multi-select design mid-build, once real
  usage (a live cluster chaining ~16 loosely-related names together
  through generic words like "Manager"/"Supervisor") showed a flat
  N-way list wasn't how a reviewer actually wants to work through a
  messy cluster — merge the pairs that are obviously the same role,
  leave the rest for a later pass, one decision at a time.

  Merging a candidate that's itself `status: "differentiated"` is
  disabled for that pair (out of scope — needs its own
  description/relations/guidance reconciliation, not just an empty stub
  disappearing) — every *other* candidate under the same anchor stays
  independently actionable.

  The drag widget lets a human express "these are different but
  related" as a continuous weight (dragged distance from the anchor,
  converted via `Reconciliation.distance_to_weight/1`) rather than
  typing a decimal — dragging past the outer ring means "not related"
  instead (an `easy_negative` relation, same as the explicit "Not
  related" button). Implemented as a `Phoenix.LiveView.ColocatedHook`,
  this app's first — plain SVG and Pointer Events, no new JS dependency.
  Role names are rendered as normal HTML text *outside* the SVG, not as
  `<text>` elements inside it — a real screenshot of the earlier design
  showed long names (e.g. "Banquet / Event F&B Supervisor") colliding
  no matter how the in-widget label was positioned; arbitrary-length
  text only behaves predictably in normal document flow. The SVG itself
  is just small drag handles plus concentric guide rings, with a plain
  HTML legend (not more SVG text) explaining what crossing each ring
  means.

  The `TerminusDB.Config` used comes from the connect session
  (`"terminus_config"`), falling back to `Data.TerminusDB.config/0` —
  the same seam `RoleLive` uses for test stubbing.
  """

  use DataWeb, :live_view

  alias Data.SkillTaxonomy.{ClusterResolver, Reconciliation}

  @impl true
  def mount(_params, session, socket) do
    config = Map.get(session, "terminus_config") || Data.TerminusDB.config()

    {:ok,
     socket
     |> assign(config: config, reviewable: [], selected_cluster: nil, selected_candidate_id: nil)
     |> load_reviewable()}
  end

  defp load_reviewable(socket) do
    config = socket.assigns.config
    previous_anchor_id = previous_anchor_id(socket)

    with {:ok, roles} <- TerminusDB.Document.query(config, %{"@type" => "Role"}),
         {:ok, relations} <- TerminusDB.Document.query(config, %{"@type" => "RoleRelation"}) do
      already_related = MapSet.new(relations, fn r -> {r["from"], r["to"]} end)

      reviewable =
        roles
        |> Reconciliation.cluster(0.75, already_related)
        |> Enum.map(&Reconciliation.classify/1)
        |> Enum.reject(&(&1 == :no_action_needed))
        |> Enum.map(fn {:actionable, cluster} ->
          Reconciliation.anchor_and_candidates(cluster)
        end)
        |> Enum.with_index()
        |> Enum.map(fn {{anchor, candidates}, index} ->
          %{index: index, anchor: anchor, candidates: candidates}
        end)

      socket
      |> assign(reviewable: reviewable, error: nil)
      |> reselect(previous_anchor_id)
    else
      {:error, reason} ->
        assign(socket,
          reviewable: [],
          selected_cluster: nil,
          selected_candidate_id: nil,
          error: inspect(reason)
        )
    end
  end

  defp previous_anchor_id(socket) do
    case socket.assigns.selected_cluster do
      nil ->
        nil

      index ->
        case Enum.find(socket.assigns.reviewable, &(&1.index == index)) do
          nil -> nil
          item -> item.anchor["@id"]
        end
    end
  end

  # Stays on the same cluster (matched by anchor id, since indices are
  # recomputed fresh every load) if it still has candidates, so working
  # through a messy multi-candidate cluster one pair at a time doesn't
  # bounce back to the top of the sidebar after every decision.
  defp reselect(socket, previous_anchor_id) do
    reviewable = socket.assigns.reviewable
    match = previous_anchor_id && Enum.find(reviewable, &(&1.anchor["@id"] == previous_anchor_id))
    selected = match || List.first(reviewable)

    case selected do
      nil ->
        assign(socket, selected_cluster: nil, selected_candidate_id: nil)

      item ->
        assign(socket,
          selected_cluster: item.index,
          selected_candidate_id: first_candidate_id(item)
        )
    end
  end

  defp first_candidate_id(%{candidates: [first | _]}), do: first["@id"]
  defp first_candidate_id(%{candidates: []}), do: nil

  @impl true
  def handle_event("select_cluster", %{"index" => index}, socket) do
    index = String.to_integer(index)
    item = Enum.find(socket.assigns.reviewable, &(&1.index == index))

    {:noreply,
     assign(socket, selected_cluster: index, selected_candidate_id: first_candidate_id(item))}
  end

  def handle_event("select_candidate", %{"candidate_id" => candidate_id}, socket) do
    {:noreply, assign(socket, selected_candidate_id: candidate_id)}
  end

  def handle_event("merge", _params, socket) do
    item = selected_item(socket)
    candidate = selected_candidate(socket)

    case ClusterResolver.merge(socket.assigns.config, item.anchor["@id"], [candidate["@id"]]) do
      {:ok, _summary} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Merged \"#{candidate["primary_name"]}\" into \"#{item.anchor["primary_name"]}\"."
         )
         |> load_reviewable()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Merge failed: #{inspect(reason)}")}
    end
  end

  def handle_event("mark_unrelated", _params, socket) do
    item = selected_item(socket)
    candidate = selected_candidate(socket)

    case ClusterResolver.mark_unrelated(
           socket.assigns.config,
           item.anchor["@id"],
           candidate["@id"]
         ) do
      {:ok, _id} ->
        {:noreply,
         socket
         |> put_flash(:info, "Marked \"#{candidate["primary_name"]}\" as unrelated.")
         |> load_reviewable()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed: #{inspect(reason)}")}
    end
  end

  def handle_event(
        "candidate_positioned",
        %{"candidate_id" => candidate_id, "distance" => distance},
        socket
      ) do
    {distance, _} = Float.parse(distance)
    item = selected_item(socket)
    weight = Reconciliation.distance_to_weight(distance)

    case ClusterResolver.keep_separate(
           socket.assigns.config,
           item.anchor["@id"],
           candidate_id,
           weight
         ) do
      {:ok, _id} ->
        {:noreply,
         socket
         |> put_flash(:info, "Recorded #{Float.round(weight, 2)} closeness.")
         |> load_reviewable()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed: #{inspect(reason)}")}
    end
  end

  def handle_event("candidate_excluded", %{"candidate_id" => candidate_id}, socket) do
    item = selected_item(socket)

    case ClusterResolver.mark_unrelated(socket.assigns.config, item.anchor["@id"], candidate_id) do
      {:ok, _id} ->
        {:noreply, socket |> put_flash(:info, "Marked as unrelated.") |> load_reviewable()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed: #{inspect(reason)}")}
    end
  end

  defp selected_item(socket) do
    Enum.find(socket.assigns.reviewable, &(&1.index == socket.assigns.selected_cluster))
  end

  defp selected_candidate(socket) do
    item = selected_item(socket)
    Enum.find(item.candidates, &(&1["@id"] == socket.assigns.selected_candidate_id))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-5xl mx-auto flex gap-6 items-start">
      <nav class="w-72 shrink-0 bg-base-100 border border-base-300 rounded shadow-sm">
        <div class="p-4 pb-2">
          <.header>Stub Reconciliation</.header>
        </div>
        <p :if={@reviewable == []} class="px-4 pb-4 text-sm text-base-content/70">
          No clusters need review right now.
        </p>
        <ul>
          <li :for={item <- @reviewable}>
            <button
              type="button"
              phx-click="select_cluster"
              phx-value-index={item.index}
              class={[
                "w-full text-left px-4 py-2 border-t border-base-300 text-sm",
                item.index == @selected_cluster && "bg-primary text-primary-content font-semibold",
                item.index != @selected_cluster && "hover:bg-base-200"
              ]}
            >
              {item.anchor["primary_name"]}
              <span class="block text-xs opacity-70">{length(item.candidates)} candidate(s)</span>
            </button>
            <ul :if={item.index == @selected_cluster} class="bg-base-200/50">
              <li :for={candidate <- item.candidates}>
                <button
                  type="button"
                  phx-click="select_candidate"
                  phx-value-candidate_id={candidate["@id"]}
                  data-candidate-item={candidate["@id"]}
                  class={[
                    "w-full text-left pl-8 pr-4 py-1.5 text-sm border-t border-base-300",
                    candidate["@id"] == @selected_candidate_id &&
                      "selected bg-secondary text-secondary-content",
                    candidate["@id"] != @selected_candidate_id && "hover:bg-base-200"
                  ]}
                >
                  {candidate["primary_name"]}
                </button>
              </li>
            </ul>
          </li>
        </ul>
      </nav>

      <div class="flex-1">
        <p :if={@error} class="alert alert-error">{@error}</p>
        {render_pairwise(assigns)}
      </div>
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".ReconciliationDragWidget">
      export default {
        mounted() {
          const svg = this.el
          const center = { x: 150, y: 150 }
          const maxRadius = 120
          const excludeRadius = maxRadius * 1.15
          let dragging = null
          let start = null

          const toSvgPoint = (clientX, clientY) => {
            const rect = svg.getBoundingClientRect()
            return {
              x: (clientX - rect.left) * (300 / rect.width),
              y: (clientY - rect.top) * (300 / rect.height)
            }
          }

          svg.addEventListener("pointerdown", (e) => {
            const target = e.target.closest("[data-candidate-id]")
            if (!target) return
            dragging = target
            start = toSvgPoint(e.clientX, e.clientY)
            target.setPointerCapture(e.pointerId)
          })

          svg.addEventListener("pointermove", (e) => {
            if (!dragging) return
            const p = toSvgPoint(e.clientX, e.clientY)
            const dx = p.x - start.x
            const dy = p.y - start.y
            dragging.setAttribute("transform", `translate(${dx}, ${dy})`)
          })

          svg.addEventListener("pointerup", (e) => {
            if (!dragging) return
            const candidateId = dragging.dataset.candidateId
            const originX = parseFloat(dragging.dataset.originX)
            const originY = parseFloat(dragging.dataset.originY)
            const p = toSvgPoint(e.clientX, e.clientY)
            const finalX = originX + (p.x - start.x)
            const finalY = originY + (p.y - start.y)
            const rawDistance = Math.hypot(finalX - center.x, finalY - center.y)

            if (rawDistance > excludeRadius) {
              this.pushEvent("candidate_excluded", { candidate_id: candidateId })
            } else {
              const distance = Math.min(rawDistance / maxRadius, 1.0)
              this.pushEvent("candidate_positioned", { candidate_id: candidateId, distance: distance.toString() })
            }

            dragging.removeAttribute("transform")
            dragging = null
            start = null
          })
        }
      }
    </script>
    """
  end

  defp render_pairwise(assigns) do
    item = Enum.find(assigns.reviewable, &(&1.index == assigns.selected_cluster))
    candidate = item && Enum.find(item.candidates, &(&1["@id"] == assigns.selected_candidate_id))
    assigns = assign(assigns, item: item, candidate: candidate)

    ~H"""
    <div :if={@item && @candidate} class="bg-base-100 border border-base-300 rounded shadow-sm p-4">
      <p class="mb-1">
        <span class="font-medium">{@item.anchor["primary_name"]}</span>
        <span class="badge ml-2">{@item.anchor["status"]}</span>
      </p>
      <p class="mb-3">
        <span class="font-medium">{@candidate["primary_name"]}</span>
        <span class="badge ml-2">{@candidate["status"]}</span>
      </p>

      <p class="text-sm text-base-content/70 mb-2">
        Is "{@candidate["primary_name"]}" really the same job as "{@item.anchor["primary_name"]}",
        just worded differently? Merge it in — it becomes an alternate name (synonym) for
        "{@item.anchor["primary_name"]}". If it's a genuinely different (but maybe related) role,
        use "Not related" or the widget below instead.
      </p>

      <div class="flex items-center gap-2 mb-3 flex-wrap">
        <button
          :if={@candidate["status"] == "stub"}
          type="button"
          phx-click="merge"
          class="btn btn-primary btn-soft"
        >
          Merge into "{@item.anchor["primary_name"]}"
        </button>
        <p :if={@candidate["status"] != "stub"} class="text-warning text-sm">
          "{@candidate["primary_name"]}" already has its own full entry — merging two fully-differentiated
          roles isn't supported here (their descriptions/relations/guidance would need reconciling too).
          Edit the roles directly if they truly need combining.
        </p>
        <button type="button" phx-click="mark_unrelated" class="btn btn-soft">Not related</button>
      </div>

      {render_drag_widget(assigns)}
    </div>
    """
  end

  defp render_drag_widget(assigns) do
    ~H"""
    <div class="mt-3">
      <svg
        id={"drag-widget-#{@item.index}"}
        phx-hook=".ReconciliationDragWidget"
        data-reference-id={@item.anchor["@id"]}
        viewBox="0 0 300 300"
        width="240"
        height="240"
      >
        <circle cx="150" cy="150" r="120" fill="none" stroke="#ccc" stroke-dasharray="4" />
        <circle cx="150" cy="150" r="80" fill="none" stroke="#ccc" stroke-dasharray="4" />
        <circle cx="150" cy="150" r="40" fill="none" stroke="#ccc" stroke-dasharray="4" />
        <circle cx="150" cy="150" r="14" fill="#D9E1F2" stroke="#6b7280" stroke-width="1.5" />
        <g
          data-candidate-id={@candidate["@id"]}
          data-origin-x="230"
          data-origin-y="150"
          style="cursor: grab"
        >
          <circle cx="230" cy="150" r="14" fill="#FFFFCC" stroke="#6b7280" stroke-width="1.5" />
        </g>
      </svg>
      <div class="text-sm text-base-content/70 mt-1 max-w-sm">
        <p class="mb-1">
          <span class="inline-block w-3 h-3 rounded-full align-middle mr-1" style="background:#D9E1F2"></span>
          {@item.anchor["primary_name"]} (fixed center)
          <span
            class="inline-block w-3 h-3 rounded-full align-middle mr-1 ml-3"
            style="background:#FFFFCC"
          ></span>
          {@candidate["primary_name"]} (drag this)
        </p>
        <p class="mb-1">
          Drag the yellow handle closer to the center to record how related they are:
        </p>
        <ul class="list-disc pl-5">
          <li>Innermost ring — very close (consider merging instead)</li>
          <li>Middle ring — closely related</li>
          <li>Outer ring — loosely related</li>
          <li>Past the outer ring — not related</li>
        </ul>
      </div>
    </div>
    """
  end
end
