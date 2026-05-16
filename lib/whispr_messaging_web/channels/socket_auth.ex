defmodule WhisprMessagingWeb.SocketAuth do
  @moduledoc """
  Pure JWT helpers used by `UserSocket`. Extracted so the parsing logic
  (kid extraction, aud validation, sub extraction) can be unit-tested
  without touching the Phoenix socket lifecycle.
  """

  @doc """
  Returns the `kid` (key id) value from a JWT header, or `nil` when the
  header is missing, malformed, or does not contain a binary kid.
  """
  @spec peek_kid(String.t()) :: String.t() | nil
  def peek_kid(token) when is_binary(token) do
    with [header_b64 | _] <- String.split(token, "."),
         {:ok, json} <- Base.url_decode64(header_b64, padding: false),
         {:ok, %{"kid" => kid}} when is_binary(kid) <- Jason.decode(json) do
      kid
    else
      _ -> nil
    end
  end

  def peek_kid(_), do: nil

  @doc """
  Accepts the three legitimate audience values: `nil` (HTTP access token
  without aud claim), `"whispr"` (legacy HTTP aud), `"ws"` (short-lived
  websocket token issued by /tokens/ws-token).
  """
  @spec valid_aud?(any()) :: boolean()
  def valid_aud?(nil), do: true
  def valid_aud?(aud) when is_binary(aud), do: aud in ["whispr", "ws"]
  def valid_aud?(_), do: false

  @doc """
  Extracts the `sub` claim from a verified JWT body. Returns
  `{:error, reason}` when the claim is absent or empty.
  """
  @spec extract_sub(map()) :: {:ok, String.t()} | {:error, String.t()}
  def extract_sub(%{"sub" => sub}) when is_binary(sub) and sub != "", do: {:ok, sub}
  def extract_sub(_), do: {:error, "missing or invalid sub claim"}
end
