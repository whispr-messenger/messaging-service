defmodule WhisprMessagingWeb.AdminSocketController do
  @moduledoc """
  Endpoint interne pour forcer la fermeture de toutes les sessions WebSocket
  actives d'un user_id donne (WHISPR-1243).

  Use cases : ban, reset mot de passe, compromission d'appareil.

  Protege par le pipeline :internal_api (header x-internal-token).
  """

  use WhisprMessagingWeb, :controller

  require Logger

  @doc """
  Force-disconnecte toutes les sockets actives du user_id.

  Phoenix emet un broadcast sur le topic "user_socket:<user_id>"
  avec l'event "disconnect". Chaque socket active enregistree sous
  cet id reoit le message et s'arrete via {:stop, {:shutdown, :disconnected}}.
  """
  def disconnect(conn, %{"user_id" => user_id}) do
    WhisprMessagingWeb.Endpoint.broadcast("user_socket:#{user_id}", "disconnect", %{})

    Logger.info("ws_force_disconnect",
      event: "ws_force_disconnect",
      user_id: user_id,
      domain: :admin
    )

    json(conn, %{ok: true, user_id: user_id})
  end
end
