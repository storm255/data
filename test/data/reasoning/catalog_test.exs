defmodule Data.Reasoning.CatalogTest do
  use ExUnit.Case, async: true

  alias Data.Reasoning.Catalog

  describe "new/3" do
    test "builds a catalog struct from relations and rules" do
      catalog = Catalog.new(:example, [{"edge", [:atom, :atom]}], [])

      assert catalog.name == :example
      assert catalog.relations == [{"edge", [:atom, :atom]}]
      assert catalog.rules == []
    end
  end

  describe "merge/2" do
    test "unions relations and rules from independent catalogs" do
      a =
        Catalog.new(:a, [{"edge", [:atom, :atom]}], [
          {{"path", [:X, :Y]}, [{:positive, {"edge", [:X, :Y]}}]}
        ])

      b = Catalog.new(:b, [{"weight", [:atom, :integer]}], [])

      merged = Catalog.merge([a, b], :combined)

      assert merged.name == :combined

      assert Enum.sort(merged.relations) == [
               {"edge", [:atom, :atom]},
               {"weight", [:atom, :integer]}
             ]

      assert merged.rules == a.rules
    end

    test "raises when catalogs disagree on a relation's column types" do
      a = Catalog.new(:a, [{"edge", [:atom, :atom]}], [])
      b = Catalog.new(:b, [{"edge", [:atom, :integer]}], [])

      assert_raise ArgumentError, ~r/conflicting schema for relation/, fn ->
        Catalog.merge([a, b], :combined)
      end
    end

    test "is a no-op conflict when catalogs agree on a shared relation" do
      a = Catalog.new(:a, [{"edge", [:atom, :atom]}], [])
      b = Catalog.new(:b, [{"edge", [:atom, :atom]}], [])

      merged = Catalog.merge([a, b], :combined)

      assert merged.relations == [{"edge", [:atom, :atom]}]
    end
  end

  describe "build_program/2" do
    test "declares relations, facts, and rules on an ExDatalog.Program" do
      catalog =
        Catalog.new(:example, [{"edge", [:atom, :atom]}, {"path", [:atom, :atom]}], [
          {{"path", [:X, :Y]}, [{:positive, {"edge", [:X, :Y]}}]}
        ])

      program = Catalog.build_program(catalog, [{"edge", [:a, :b]}])

      assert program.facts == [{"edge", [:a, :b]}]
      assert length(program.rules) == 1
      assert Map.has_key?(program.relations, "edge")
      assert Map.has_key?(program.relations, "path")
    end
  end
end
