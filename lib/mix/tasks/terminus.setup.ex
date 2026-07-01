defmodule Mix.Tasks.Terminus.Setup do
  @moduledoc """
  Ensures the configured TerminusDB database exists and its document schema
  is in sync.

      mix terminus.setup
  """
  @shortdoc "Create the TerminusDB database and sync its document schema"

  use Mix.Task

  @doc """
  Starts the application, then ensures the TerminusDB database and schema
  exist. Safe to run repeatedly.
  """
  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    config = Data.TerminusDB.config()
    Data.TerminusDB.Setup.ensure_database!(config)
    Data.TerminusDB.Setup.ensure_schema!(config, Data.TerminusDB.Schema.classes())
  end
end
