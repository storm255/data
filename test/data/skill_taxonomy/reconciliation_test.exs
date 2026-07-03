defmodule Data.SkillTaxonomy.ReconciliationTest do
  use ExUnit.Case, async: true

  alias Data.SkillTaxonomy.Reconciliation

  defp role(id, primary_name, status \\ "stub") do
    %{"@id" => id, "primary_name" => primary_name, "status" => status}
  end

  describe "cluster/2 (default threshold, real near-duplicate examples)" do
    test "groups roles whose names are the same words differently punctuated/ordered" do
      # Real examples from the Bangkok Scope import's stub list. Raw
      # String.jaro_distance/2 on these is only ~0.79-0.83 (would miss the
      # default threshold entirely) — clustering normalizes first
      # (downcase, strip punctuation, dedupe+sort words) specifically
      # because this "same words, different order/punctuation/repetition"
      # pattern is the dominant real-world near-duplicate shape, not
      # single-character typos.
      roles = [
        role("a", "Laundry Attendant"),
        role("b", "Laundry Attendant / Linen Attendant"),
        role("c", "Laundry/Linen Attendant"),
        role("d", "Bartender", "differentiated")
      ]

      clusters = Reconciliation.cluster(roles)

      assert length(clusters) == 1
      [cluster] = clusters
      assert Enum.map(cluster, & &1["@id"]) |> Enum.sort() == ["a", "b", "c"]
    end

    test "a duplicated inner word doesn't prevent clustering (word set, not raw characters)" do
      # "Steward / Kitchen Steward" repeats "Steward" — normalizing dedupes
      # words before comparing, so this still matches "Kitchen Steward"
      # exactly (raw Jaro distance here is only ~0.71).
      roles = [role("a", "Kitchen Steward"), role("b", "Steward / Kitchen Steward")]
      assert [cluster] = Reconciliation.cluster(roles)
      assert Enum.map(cluster, & &1["@id"]) |> Enum.sort() == ["a", "b"]
    end

    test "genuinely different roles that merely share a word do not cluster" do
      roles = [
        role("a", "Bartender"),
        role("b", "Barista"),
        role("c", "Baker"),
        role("d", "Baker Assistant")
      ]

      assert Reconciliation.cluster(roles) == []
    end

    test "'&' inside a word (e.g. F&B) doesn't split into meaningless single-letter tokens" do
      # Splitting "F&B" into the words "f" and "b" pollutes the word set
      # with generic single-character tokens that every other F&B-titled
      # role also picks up — inflating similarity between roles that
      # only share the abbreviation, not any real meaning. Verified this
      # exact pair crosses the default threshold with the bug present
      # (0.856) and correctly falls below it once "F&B" normalizes to
      # one token ("fb") instead of two spurious single letters (0.656).
      roles = [role("a", "F&B Cashier"), role("b", "Bell Cashier")]
      assert Reconciliation.cluster(roles, 0.75) == []
    end

    test "singletons (no close match) are excluded entirely" do
      roles = [role("a", "Bartender"), role("b", "Zzzz Nonexistent Role")]
      assert Reconciliation.cluster(roles) == []
    end

    test "an empty role list produces no clusters" do
      assert Reconciliation.cluster([]) == []
    end
  end

  describe "cluster/3 (already-related pairs are excluded, so a reviewed pair doesn't resurface)" do
    test "a pair with an existing relation between them is not clustered together" do
      roles = [role("a", "Laundry Attendant"), role("b", "Laundry Attendant / Linen Attendant")]
      already_related = MapSet.new([{"a", "b"}])

      assert Reconciliation.cluster(roles, 0.75, already_related) == []
    end

    test "the exclusion is symmetric — order of the pair in the set doesn't matter" do
      roles = [role("a", "Laundry Attendant"), role("b", "Laundry Attendant / Linen Attendant")]
      already_related = MapSet.new([{"b", "a"}])

      assert Reconciliation.cluster(roles, 0.75, already_related) == []
    end

    test "excluding one already-related pair doesn't prevent the rest of a larger cluster from forming" do
      roles = [
        role("a", "Laundry Attendant"),
        role("b", "Laundry Attendant / Linen Attendant"),
        role("c", "Laundry/Linen Attendant")
      ]

      # a<->b already reviewed and dismissed; b<->c and a<->c (direct, via
      # normalization both are 1.0/0.913) are not — b and c (and a, via c)
      # should still cluster.
      already_related = MapSet.new([{"a", "b"}])

      assert [cluster] = Reconciliation.cluster(roles, 0.75, already_related)
      assert Enum.map(cluster, & &1["@id"]) |> Enum.sort() == ["a", "b", "c"]
    end
  end

  describe "cluster/2 (connected components — transitivity through a bridge)" do
    test "links a and c through b even though a and c alone fall below threshold" do
      # At threshold 0.65: a~b ~0.673 (above), b~c ~0.781 (above), but
      # a~c ~0.57 (below) — proves this is genuine connected-components
      # clustering (a and c only cluster via the b bridge), not just
      # pairwise comparison against every other role independently.
      roles = [
        role("a", "Night Auditor Assistant"),
        role("b", "Night Auditor Lead"),
        role("c", "Day Auditor Lead")
      ]

      clusters = Reconciliation.cluster(roles, 0.65)
      assert length(clusters) == 1
      assert length(hd(clusters)) == 3
    end
  end

  describe "classify/1" do
    # Deliberately just a filter now, not a pre-decided action shape — a
    # cluster surfaced by clustering can turn out to be a long chain of
    # loosely-related names (real example: a Bangkok stub cluster with
    # ~16 members bridged by generic words like "Manager"/"Supervisor"),
    # where the right move is to merge some sub-pairs and leave others
    # for a later pass, not to force one canonical for the whole cluster.
    # The reviewer works through it pairwise instead (anchor_and_candidates/1
    # below, surfaced one candidate at a time in the LiveView); this only
    # decides whether a cluster needs looking at *at all*.
    test "a cluster with at least one stub member is actionable" do
      cluster = [
        role("a", "Laundry Attendant", "differentiated"),
        role("b", "Laundry Attendant / Linen Attendant", "stub"),
        role("c", "Laundry/Linen Attendant", "stub")
      ]

      assert {:actionable, ^cluster} = Reconciliation.classify(cluster)
    end

    test "a cluster of all stubs is actionable" do
      cluster = [
        role("a", "Kitchen Steward", "stub"),
        role("b", "Steward / Kitchen Steward", "stub")
      ]

      assert {:actionable, ^cluster} = Reconciliation.classify(cluster)
    end

    test "a cluster with no stub members needs no action" do
      cluster = [
        role("a", "Bartender", "differentiated"),
        role("b", "Bar Tender", "differentiated")
      ]

      assert Reconciliation.classify(cluster) == :no_action_needed
    end
  end

  describe "anchor_and_candidates/1" do
    test "the differentiated member is the anchor when exactly one exists" do
      cluster = [
        role("a", "Laundry Attendant / Linen Attendant", "stub"),
        role("b", "Laundry Attendant", "differentiated"),
        role("c", "Laundry/Linen Attendant", "stub")
      ]

      assert {anchor, candidates} = Reconciliation.anchor_and_candidates(cluster)
      assert anchor["@id"] == "b"
      assert Enum.map(candidates, & &1["@id"]) |> Enum.sort() == ["a", "c"]
    end

    test "the alphabetically-first name is the anchor when every member is a stub" do
      cluster = [
        role("a", "Steward / Kitchen Steward", "stub"),
        role("b", "Kitchen Steward", "stub")
      ]

      assert {anchor, candidates} = Reconciliation.anchor_and_candidates(cluster)
      assert anchor["@id"] == "b"
      assert Enum.map(candidates, & &1["@id"]) == ["a"]
    end

    test "with two or more differentiated members, the alphabetically-first differentiated one is the anchor" do
      cluster = [
        role("a", "Baker / Bakery Chef", "differentiated"),
        role("b", "Baker", "differentiated"),
        role("c", "Baker Assistant", "stub")
      ]

      assert {anchor, candidates} = Reconciliation.anchor_and_candidates(cluster)
      assert anchor["@id"] == "b"
      assert Enum.map(candidates, & &1["@id"]) |> Enum.sort() == ["a", "c"]
    end
  end

  describe "distance_to_weight/1" do
    test "zero distance (dropped on the reference) is maximum weight" do
      assert Reconciliation.distance_to_weight(0.0) == 1.0
    end

    test "distance of 1.0 (dropped at the outer edge) is minimum weight" do
      assert Reconciliation.distance_to_weight(1.0) == 0.0
    end

    test "a mid-distance drop produces a proportional weight" do
      assert_in_delta Reconciliation.distance_to_weight(0.3), 0.7, 0.0001
    end

    test "distances beyond the widget's edge clamp to 0.0, not negative" do
      assert Reconciliation.distance_to_weight(1.5) == 0.0
    end
  end
end
