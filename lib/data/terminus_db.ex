defmodule Data.TerminusDB do
  @moduledoc """
  Builds the `TerminusDB.Config` for this application from
  `config :data, :terminusdb, ...`.

  `TerminusDB.Config` is plain immutable data (no connection process to
  supervise), so this just assembles it on demand from application env.
  """

  alias TerminusDB.Config

  @spec config(keyword()) :: Config.t()
  def config(overrides \\ []) do
    :data
    |> Application.fetch_env!(:terminusdb)
    |> Keyword.merge(overrides)
    |> Config.new()
  end
end
