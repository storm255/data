defmodule Data.Reasoning.Catalogs.Rbac do
  @moduledoc """
  Catalog for role-based access control: role inheritance through a role
  hierarchy plus direct grants, deriving every role each user effectively
  holds.

  Relations:

    * `role_parent/2` — `{parent_role, child_role}`; a role grants
      everything its child roles grant (e.g. `admin` implies `editor`).
    * `user_direct_role/2` — `{user, role}`; roles assigned directly to a
      user.
    * `has_role/2` — derived: every role a user holds, direct or inherited.

  This is schema only — see `Data.Reasoning.Loader` for how facts get
  loaded from an external source, and `Data.Reasoning.Store` for
  materializing and querying this catalog.
  """

  alias Data.Reasoning.Catalog

  @doc """
  Builds the RBAC catalog.

  ## Examples

      iex> catalog = Data.Reasoning.Catalogs.Rbac.build()
      iex> catalog.name
      :rbac
      iex> length(catalog.rules)
      2

  """
  @spec build() :: Catalog.t()
  def build do
    Catalog.new(
      :rbac,
      [
        {"role_parent", [:atom, :atom]},
        {"user_direct_role", [:atom, :atom]},
        {"has_role", [:atom, :atom]}
      ],
      [
        # A user has a role if it was assigned directly.
        {
          {"has_role", [:User, :Role]},
          [{:positive, {"user_direct_role", [:User, :Role]}}]
        },
        # A user also has a role if they hold a role that it inherits from.
        {
          {"has_role", [:User, :Role]},
          [
            {:positive, {"has_role", [:User, :ParentRole]}},
            {:positive, {"role_parent", [:ParentRole, :Role]}}
          ]
        }
      ]
    )
  end
end
