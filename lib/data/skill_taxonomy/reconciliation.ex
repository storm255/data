defmodule Data.SkillTaxonomy.Reconciliation do
  @moduledoc """
  Groups `Role` documents with close names into review clusters, and
  classifies each cluster by what kind of human decision it needs.
  Pure — no network, no `TerminusDB.Config` — same role `RowBuilder`
  plays for `Importer`: the actual TerminusDB writes for whatever a
  human decides live in `Data.SkillTaxonomy.ClusterResolver`.

  Motivated by a real result: importing the Bangkok Scope workbook
  (design doc §9 roadmap item 7) auto-created 114 stub roles, a
  meaningful fraction of which are the same real-world role spelled
  multiple ways across different sheets (design doc §11's "Stub/
  near-duplicate reconciliation view").
  """

  @type role :: %{required(String.t()) => term()}

  @type classification :: {:actionable, cluster :: [role()]} | :no_action_needed

  @default_threshold 0.75

  @doc """
  Groups `roles` into clusters of close-named roles (connected
  components over pairwise closeness, not just direct pairwise
  matches — see `close?/3`), dropping singletons. `threshold` is a
  `String.jaro_distance/2` value (0.0-1.0) computed on *normalized*
  names (see `normalize/1`), not raw ones.

  The default `0.75` is calibrated against real near-duplicate stub
  names from the Bangkok Scope import, not chosen arbitrarily — see
  the test suite for the actual distances that motivated it. Every
  cluster this produces still requires an explicit human decision
  (`classify/1` plus a `Data.SkillTaxonomy.ClusterResolver` action) —
  nothing here writes anything, so a threshold that's a little too
  permissive costs one extra "not related" click, not bad data.

  `already_related` is a `MapSet` of `{id_a, id_b}` pairs (order
  within a pair doesn't matter — checked both ways) that already have
  *some* `RoleRelation` between them — a prior `ClusterResolver.merge/3`,
  `keep_separate/4`, or `mark_unrelated/3` decision. Such a pair is
  never linked by this closeness graph, even if their names are still
  close — this is what makes a reviewed pair stop resurfacing as a
  candidate on the next call, without needing a separate "dismissed"
  flag anywhere.
  """
  @spec cluster([role()], float(), MapSet.t({String.t(), String.t()})) :: [[role()]]
  def cluster(roles, threshold \\ @default_threshold, already_related \\ MapSet.new()) do
    roles
    |> connected_components(threshold, already_related)
    |> Enum.filter(&(length(&1) > 1))
  end

  @doc """
  Whether a cluster needs a human decision at all — `:no_action_needed`
  if it has no `status: "stub"` members (either a deliberate naming
  decision already made, or out of this tool's scope either way),
  `{:actionable, cluster}` otherwise.

  Deliberately **not** a pre-decided action shape (no more
  auto-mergeable/pick-canonical/needs-manual-review split) — a cluster
  can turn out to be a long chain of only loosely-related names (a real
  Bangkok import cluster had ~16 members bridged by generic words like
  "Manager"/"Supervisor", mixing genuinely-duplicate pairs with
  genuinely-different roles). The right move there is picking which
  *subset* is actually the same role and leaving the rest for a later
  pass, not forcing one canonical choice over the whole cluster — that
  happens pairwise in the LiveView (`anchor_and_candidates/1`), not here.
  """
  @spec classify([role()]) :: classification()
  def classify(cluster) do
    if Enum.any?(cluster, &(&1["status"] == "stub")) do
      {:actionable, cluster}
    else
      :no_action_needed
    end
  end

  @doc """
  Splits an actionable cluster into `{anchor, candidates}` for pairwise
  review — "a human only deals with pairs at any time" (design doc §11):
  the LiveView shows one `{anchor, candidate}` comparison at a time
  instead of asking a reviewer to make sense of an N-way list.

  The anchor is the alphabetically-first `status: "differentiated"`
  member if any exist (an already-differentiated role is always a safer
  default anchor than a placeholder stub), else the alphabetically-first
  member overall. Every other member becomes a `candidates` entry, each
  reviewed independently against the anchor — merging a candidate that's
  *itself* differentiated stays a LiveView-level restriction (design doc
  §11: differentiated-into-differentiated needs its own reconciliation,
  out of scope here), not something this function decides.
  """
  @spec anchor_and_candidates([role()]) :: {role(), [role()]}
  def anchor_and_candidates(cluster) do
    differentiated = Enum.filter(cluster, &(&1["status"] != "stub"))
    pool = if differentiated == [], do: cluster, else: differentiated

    anchor = Enum.min_by(pool, & &1["primary_name"])
    {anchor, cluster -- [anchor]}
  end

  @doc """
  Converts a Phase 2 drag-widget drop distance (0.0 = dropped exactly
  on the fixed reference role, 1.0 = dropped at the widget's outer
  edge) into a `RoleRelation.weight` (1.0 = closest, 0.0 = furthest).
  Clamped to `[0.0, 1.0]` — a drop past the outer edge (still possible
  with a fast drag gesture) doesn't produce a negative weight.
  """
  @spec distance_to_weight(float()) :: float()
  def distance_to_weight(distance) do
    (1.0 - distance) |> max(0.0) |> min(1.0)
  end

  # ---- Clustering internals ----

  defp connected_components(roles, threshold, already_related) do
    ids = Enum.map(roles, & &1["@id"])
    parent = Map.new(ids, &{&1, &1})

    parent =
      for %{"@id" => id_a, "primary_name" => name_a} <- roles,
          %{"@id" => id_b, "primary_name" => name_b} <- roles,
          id_a < id_b,
          not related?(already_related, id_a, id_b),
          close?(name_a, name_b, threshold),
          reduce: parent do
        parent -> union(parent, id_a, id_b)
      end

    roles
    |> Enum.group_by(fn %{"@id" => id} -> find(parent, id) end)
    |> Map.values()
  end

  defp find(parent, id) do
    case Map.fetch!(parent, id) do
      ^id -> id
      next -> find(parent, next)
    end
  end

  defp union(parent, id_a, id_b) do
    root_a = find(parent, id_a)
    root_b = find(parent, id_b)

    if root_a == root_b, do: parent, else: Map.put(parent, root_a, root_b)
  end

  defp close?(name_a, name_b, threshold) do
    String.jaro_distance(normalize(name_a), normalize(name_b)) >= threshold
  end

  defp related?(already_related, id_a, id_b) do
    MapSet.member?(already_related, {id_a, id_b}) or MapSet.member?(already_related, {id_b, id_a})
  end

  # Downcase, strip punctuation, dedupe and sort words — so "Steward /
  # Kitchen Steward" and "Kitchen Steward" normalize to the identical
  # "kitchen steward" instead of comparing as different-length strings
  # with reordered/repeated words. Real near-duplicate role names are
  # overwhelmingly this "same words, different order/punctuation"
  # shape, not single-character typos, so word-set normalization
  # before Jaro distance catches the actual cases that matter (see
  # cluster/2's test suite for the real numbers this was tuned against).
  #
  # "&" is dropped (not treated as a separator like other punctuation)
  # before splitting, so "F&B" — extremely common across otherwise
  # unrelated hospitality titles — normalizes to the single token "fb"
  # instead of splitting into the meaningless single-letter words "f"
  # and "b", which every other F&B-titled role would then also share.
  defp normalize(name) do
    name
    |> String.downcase()
    |> String.replace("&", "")
    |> String.replace(~r/[^a-z0-9]+/, " ")
    |> String.split()
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.join(" ")
  end
end
