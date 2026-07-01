defmodule Data.Reasoning.Loader do
  @moduledoc """
  Behaviour for fetching the ground facts for a `Data.Reasoning.Catalog`
  from an external source (typically TerminusDB documents, via
  `Data.TerminusDB` and `TerminusDB.Document`).

  Splitting this out keeps catalog definitions under
  `Data.Reasoning.Catalogs.*` pure schema, and keeps the fact source
  swappable per environment (e.g. a real loader backed by TerminusDB in
  dev/prod, a hardcoded fixture in tests) without touching the catalog or
  `Data.Reasoning.Store`.

  Concrete implementations live under `Data.Reasoning.Loaders.*`, named
  after the catalog they populate.
  """

  @doc """
  Fetches the current facts for the relations this loader knows how to
  populate, as a list of `{relation_name, values}` tuples suitable for
  `Data.Reasoning.Catalog.build_program/2`.
  """
  @callback facts() :: [{String.t(), [term()]}]
end
