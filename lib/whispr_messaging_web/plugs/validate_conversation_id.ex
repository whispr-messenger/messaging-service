defmodule WhisprMessagingWeb.Plugs.ValidateConversationId do
  @moduledoc """
  Plug that rejects requests whose `:id` path parameter is not a valid UUID.

  Without this plug, malformed UUIDs propagate to Ecto where they are silently
  treated as a missing record, hiding the underlying client error behind a
  generic 404. This plug surfaces the issue as a 400 Bad Request with a clear
  message, matching the contract expected by API consumers.

  The plug is a no-op for requests that do not carry an `:id` path parameter,
  so it is safe to attach to a broad pipeline.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(%Plug.Conn{path_params: %{"id" => id}} = conn, _opts) do
    case Ecto.UUID.cast(id) do
      {:ok, _} ->
        conn

      :error ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{error: "Invalid conversation id"}))
        |> halt()
    end
  end

  def call(conn, _opts), do: conn
end
