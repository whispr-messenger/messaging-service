defmodule WhisprMessagingWeb do
  @moduledoc """
  The entrypoint for defining your web interface.

  This module provides the foundation for controllers, channels,
  and other web components for the messaging microservice.

  This can be used in your application as:

      use WhisprMessagingWeb, :controller
      use WhisprMessagingWeb, :channel

  The definitions below will be executed for every controller,
  component, etc, so keep them short and clean, focused
  on imports, uses and aliases.
  """

  def static_paths, do: ~w(assets fonts images favicon.ico robots.txt swagger.json)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      # Import common connection and controller functions to use in pipelines
      import Plug.Conn
      import Phoenix.Controller
    end
  end

  def channel do
    quote do
      use Phoenix.Channel

      import WhisprMessagingWeb.Gettext
    end
  end

  def controller do
    quote do
      use Phoenix.Controller,
        formats: [:json]

      import Plug.Conn
      import WhisprMessagingWeb.Gettext

      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: WhisprMessagingWeb.Endpoint,
        router: WhisprMessagingWeb.Router,
        statics: WhisprMessagingWeb.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
