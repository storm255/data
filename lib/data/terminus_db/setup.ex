defmodule Data.TerminusDB.Setup do
  @moduledoc """
  Idempotent provisioning for TerminusDB: ensures the configured database
  exists and that a given set of document schema classes are in place.

  Run via `mix terminus.setup`, not on application boot — a `TerminusDB.Config`
  is just data, so there's nothing to supervise, and provisioning over HTTP at
  boot would make the app fail to start whenever TerminusDB is unreachable.
  """

  alias TerminusDB.{Config, Database, Document}

  @doc """
  Creates the database scoped in `config` if it doesn't already exist.
  """
  @spec ensure_database!(Config.t()) :: :ok
  def ensure_database!(%Config{database: nil}) do
    raise ArgumentError, "no database scoped in config"
  end

  def ensure_database!(%Config{database: db_name, organization: org} = config) do
    unless Database.exists?(config, db_name, organization: org) do
      Database.create!(config, db_name, organization: org, schema: true)
    end

    :ok
  end

  @doc """
  Syncs the given schema `classes` (a list of `Class` document maps) into the
  database's schema graph. Existing classes are replaced, missing ones
  inserted — safe to run repeatedly.
  """
  @spec ensure_schema!(Config.t(), [map()]) :: :ok
  def ensure_schema!(_config, []), do: :ok

  def ensure_schema!(config, classes) when is_list(classes) do
    Document.replace!(config, classes,
      graph_type: :schema,
      create: true,
      author: "system",
      message: "sync schema"
    )

    :ok
  end
end
