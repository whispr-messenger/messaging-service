defmodule WhisprMessagingWeb.Plugs.ValidatePathUuid do
  @moduledoc """
  Plug that rejects requests whose `:id` path parameter is not a valid UUID.

  Without this plug, malformed UUIDs propagate to Ecto where they are silently
  treated as a missing record, hiding the underlying client error behind a
  generic 404. This plug surfaces the issue as a 400 Bad Request with a clear
  message, matching the contract expected by API consumers.

  The plug is a no-op for requests that:
    * do not carry an `:id` path parameter, or
    * have not been authenticated yet (when `conn.assigns[:user_id]` is nil) —
      this preserves the precedence of the 401 response coming from the
      controllers when the auth plug runs but the request is anonymous.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(%Plug.Conn{path_params: %{"id" => id}, assigns: %{user_id: user_id}} = conn, _opts)
      when not is_nil(user_id) do
    validate(conn, id)
  end

  def call(conn, _opts), do: conn

  defp validate(conn, id) do
    case Ecto.UUID.cast(id) do
      {:ok, _} ->
        conn

      :error ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{error: "Invalid id format"}))
        |> halt()
    end
  end
end
