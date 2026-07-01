defmodule Data.Reasoning.StoreTest do
  use ExUnit.Case, async: true

  alias Data.Reasoning.{Catalog, Store}
  alias Data.Reasoning.Catalogs.Rbac
  alias ExDatalog.Knowledge

  setup do
    name = :"rbac_test_#{System.unique_integer([:positive])}"
    on_exit(fn -> Store.drop(name) end)
    %{name: name}
  end

  test "materializes and caches knowledge under a name", %{name: name} do
    facts = [
      {"role_parent", [:admin, :editor]},
      {"user_direct_role", [:alice, :admin]}
    ]

    assert {:ok, knowledge} = Store.materialize(name, Rbac.build(), facts)
    assert Knowledge.match(knowledge, "has_role", [:alice, :editor]) |> MapSet.size() == 1
    assert {:ok, ^knowledge} = Store.get(name)
  end

  test "get/1 returns :error when nothing has been materialized under that name" do
    assert Store.get(:nonexistent_reasoning_group) == :error
  end

  test "materializing a different name does not disturb an existing group", %{name: name} do
    other = :"rbac_test_other_#{System.unique_integer([:positive])}"
    on_exit(fn -> Store.drop(other) end)

    {:ok, _} = Store.materialize(name, Rbac.build(), [{"user_direct_role", [:alice, :admin]}])
    {:ok, _} = Store.materialize(other, Rbac.build(), [{"user_direct_role", [:bob, :editor]}])

    {:ok, first} = Store.get(name)
    {:ok, second} = Store.get(other)

    assert Knowledge.match(first, "has_role", [:alice, :_]) |> MapSet.size() == 1
    assert Knowledge.match(second, "has_role", [:bob, :_]) |> MapSet.size() == 1
  end

  test "refresh/4 replaces the cached knowledge for a name", %{name: name} do
    {:ok, _} = Store.materialize(name, Rbac.build(), [{"user_direct_role", [:alice, :admin]}])
    {:ok, before_refresh} = Store.get(name)
    assert Knowledge.size(before_refresh, "has_role") == 1

    {:ok, _} =
      Store.refresh(name, Rbac.build(), [
        {"user_direct_role", [:alice, :admin]},
        {"user_direct_role", [:bob, :editor]}
      ])

    {:ok, after_refresh} = Store.get(name)
    assert Knowledge.size(after_refresh, "has_role") == 2
  end

  test "combining independent catalogs reasons across both", %{name: name} do
    team = Catalog.new(:team, [{"manager_of", [:atom, :atom]}])
    combined = Catalog.merge([Rbac.build(), team], :"#{name}_combined")
    on_exit(fn -> Store.drop(combined.name) end)

    facts = [
      {"user_direct_role", [:alice, :admin]},
      {"role_parent", [:admin, :editor]},
      {"manager_of", [:alice, :bob]}
    ]

    {:ok, knowledge} = Store.materialize(combined.name, combined, facts)

    assert Knowledge.match(knowledge, "has_role", [:alice, :editor]) |> MapSet.size() == 1
    assert Knowledge.match(knowledge, "manager_of", [:alice, :bob]) |> MapSet.size() == 1
  end
end
