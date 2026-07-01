defmodule Data.Reasoning.Catalogs.RbacTest do
  use ExUnit.Case, async: true

  alias Data.Reasoning.Catalogs.Rbac
  alias ExDatalog.Knowledge

  test "declares the expected relations" do
    catalog = Rbac.build()

    assert catalog.name == :rbac

    assert Enum.sort(catalog.relations) == [
             {"has_role", [:atom, :atom]},
             {"role_parent", [:atom, :atom]},
             {"user_direct_role", [:atom, :atom]}
           ]
  end

  test "derives direct and inherited roles" do
    facts = [
      {"role_parent", [:admin, :editor]},
      {"role_parent", [:editor, :viewer]},
      {"user_direct_role", [:alice, :admin]},
      {"user_direct_role", [:bob, :editor]},
      {"user_direct_role", [:charlie, :viewer]}
    ]

    {:ok, knowledge} =
      Rbac.build()
      |> Data.Reasoning.Catalog.build_program(facts)
      |> ExDatalog.materialize()

    assert Knowledge.match(knowledge, "has_role", [:alice, :_]) ==
             MapSet.new([{:alice, :admin}, {:alice, :editor}, {:alice, :viewer}])

    assert Knowledge.match(knowledge, "has_role", [:bob, :_]) ==
             MapSet.new([{:bob, :editor}, {:bob, :viewer}])

    assert Knowledge.match(knowledge, "has_role", [:charlie, :_]) ==
             MapSet.new([{:charlie, :viewer}])
  end
end
