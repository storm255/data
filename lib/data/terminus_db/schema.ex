defmodule Data.TerminusDB.Schema do
  @moduledoc """
  The document schema (TerminusDB `Class` definitions) for this application.
  Synced into the database by `mix terminus.setup` via `Data.TerminusDB.Setup.ensure_schema!/2`.
  """

  @doc "Returns the list of `Class` document maps that make up the schema."
  @spec classes() :: [map()]
  def classes do
    []
  end
end
