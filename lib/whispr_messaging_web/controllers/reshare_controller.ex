defmodule WhisprMessagingWeb.ReshareController do
  @moduledoc """
  E2EE key_packet re-share endpoint.

  When a user logs in on a brand new browser / app install, the resulting
  device has a fresh identity key that no previously-encrypted message
  targets. Their other devices (which already hold the per-message keys)
  re-encrypt each key for the new device locally and POST the opaque
  packets here.

  The server only stores the packets; it never sees plaintext. Reads
  splice the packets back into the message envelope returned to the
  matching recipient device (see MessageController.index).
  """

  use WhisprMessagingWeb, :controller

  alias WhisprMessaging.Messages

  require Logger

  @doc """
  POST /api/v1/messages/reshares

  Body:
    {
      "reshares": [
        {
          "message_id": "uuid",
          "recipient_user_id": "uuid",
          "recipient_device_id": "uuid",
          "nonce": "base64",
          "box": "base64"
        },
        ...
      ]
    }
  """
  def create(conn, %{"reshares" => reshares}) when is_list(reshares) do
    user_id = conn.assigns[:user_id]
    device_id = conn.assigns[:device_id]

    cond do
      is_nil(user_id) ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Unauthorized"})

      is_nil(device_id) ->
        # Without knowing which device produced the reshare we cannot audit
        # it or prevent a different user's gateway from impersonating the
        # resharer; fail closed.
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Missing device identity"})

      true ->
        case Messages.insert_reshares(device_id, reshares) do
          {:ok, count} ->
            Logger.info(
              "Stored #{count} reshare packets",
              user_id: user_id,
              device_id: device_id
            )

            conn
            |> put_status(:created)
            |> json(%{inserted: count})

          {:error, reason} ->
            Logger.warning("Reshare insert failed", reason: inspect(reason))

            conn
            |> put_status(:bad_request)
            |> json(%{error: "Failed to store reshares"})
        end
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing reshares array"})
  end
end
