defmodule DataWeb.PageController do
  @moduledoc """
  Serves the application's static marketing/landing page(s).
  """

  use DataWeb, :controller

  @doc "Renders the home page."
  def home(conn, _params) do
    render(conn, :home)
  end
end
