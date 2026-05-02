defmodule WhisprMessagingWeb.Plugs.LoggerMetadata do
  @moduledoc """
  Propagates request context into Logger metadata for structured logging.

  Sets `request_id` from the response header populated by `Plug.RequestId`.
  Must be placed in the endpoint immediately after `Plug.RequestId`.
  """

  @behaviour Plug

  require Logger

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    request_id =
      case Plug.Conn.get_resp_header(conn, "x-request-id") do
        [id | _] -> id
        _ -> nil
      end

    Logger.metadata(request_id: request_id)
    conn
  end
end
