defmodule Data.Repo do
  @moduledoc """
  The Ecto repo for the application's relational (PostgreSQL) data.
  Document data lives in TerminusDB instead — see `Data.TerminusDB`.
  """

  use Ecto.Repo,
    otp_app: :data,
    adapter: Ecto.Adapters.Postgres
end
