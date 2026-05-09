defmodule WhisprMessagingWeb.Plugs.InternalApiToken do
  @moduledoc """
  Plug qui restreint l'acces a un endpoint aux callers internes.

  Verifie le header `x-internal-token` contre la valeur configuree sous
  `:whispr_messaging, :user_service_internal, :token` (alimentee par la var
  d'env `INTERNAL_API_TOKEN`, deja partagee avec le user-service).

  Si le token est absent, vide ou invalide, on repond 404 (plutot que 401)
  pour ne pas confirmer l'existence de l'endpoint a un attaquant.

  En `:test`, le plug accepte la valeur statique `"test-internal-token"`
  pour faciliter les controller tests sans toucher au runtime config.

  Si aucun token n'est configure cote serveur (vide / nil), tout l'endpoint
  reste verrouille (404) — fail-closed.
  """

  import Plug.Conn

  require Logger

  @header "x-internal-token"

  def init(opts), do: opts

  def call(conn, _opts) do
    expected = expected_token()
    provided = conn |> get_req_header(@header) |> List.first()

    if valid?(expected, provided) do
      conn
    else
      Logger.warning(
        "rejected request to internal-only endpoint",
        path: conn.request_path,
        domain: :health
      )

      not_found(conn)
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  if Mix.env() == :test do
    defp expected_token, do: "test-internal-token"
  else
    defp expected_token do
      :whispr_messaging
      |> Application.get_env(:user_service_internal, [])
      |> Keyword.get(:token)
    end
  end

  defp valid?(expected, provided)
       when is_binary(expected) and expected != "" and is_binary(provided) and provided != "" do
    Plug.Crypto.secure_compare(expected, provided)
  end

  defp valid?(_expected, _provided), do: false

  defp not_found(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{error: "not_found"}))
    |> halt()
  end
end
