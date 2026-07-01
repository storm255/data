defmodule DataWeb do
  @moduledoc """
  The entrypoint for defining your web interface, such
  as controllers, components, channels, and so on.

  This can be used in your application as:

      use DataWeb, :controller
      use DataWeb, :html

  The definitions below will be executed for every controller,
  component, etc, so keep them short and clean, focused
  on imports, uses and aliases.

  Do NOT define functions inside the quoted expressions
  below. Instead, define additional modules and import
  those modules here.
  """

  @doc "Static asset paths served directly by the endpoint and excluded from verified routes."
  def static_paths, do: ~w(assets fonts images favicon.ico robots.txt)

  @doc "Quoted block for `use DataWeb, :router` — imports used by the router module."
  def router do
    quote do
      use Phoenix.Router, helpers: false

      # Import common connection and controller functions to use in pipelines
      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  @doc "Quoted block for `use DataWeb, :channel`."
  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  @doc "Quoted block for `use DataWeb, :controller` — sets up formats, Gettext, and verified routes."
  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]

      use Gettext, backend: DataWeb.Gettext

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  @doc "Quoted block for `use DataWeb, :live_view`."
  def live_view do
    quote do
      use Phoenix.LiveView

      unquote(html_helpers())
    end
  end

  @doc "Quoted block for `use DataWeb, :live_component`."
  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  @doc "Quoted block for `use DataWeb, :html` — used by modules rendering templates/HEEx."
  def html do
    quote do
      use Phoenix.Component

      # Import convenience functions from controllers
      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      # Include general helpers for rendering HTML
      unquote(html_helpers())
    end
  end

  # Shared imports/aliases for anything that renders HEEx (html, live_view,
  # live_component); factored out so each doesn't repeat the same list.
  defp html_helpers do
    quote do
      # Translation
      use Gettext, backend: DataWeb.Gettext

      # HTML escaping functionality
      import Phoenix.HTML
      # Core UI components
      import DataWeb.CoreComponents

      # Common modules used in templates
      alias Phoenix.LiveView.JS
      alias DataWeb.Layouts

      # Routes generation with the ~p sigil
      unquote(verified_routes())
    end
  end

  @doc "Quoted block for `use DataWeb, :verified_routes` — enables the `~p` sigil."
  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: DataWeb.Endpoint,
        router: DataWeb.Router,
        statics: DataWeb.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/live_view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
