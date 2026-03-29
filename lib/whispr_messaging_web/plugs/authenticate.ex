defmodule WhisprMessagingWeb.Plugs.Authenticate do
  @moduledoc """
  Plug to authenticate users and assign user_id to the connection.

  ## Authentication chain

  1. **x-user-id** trusted gateway header — used when the upstream API gateway
     has already validated the JWT and forwarded the user ID.
  2. **Authorization: Bearer <jwt>** — validates the JWT against the EC P-256
     public key loaded dynamically from the auth-service JWKS endpoint
     (`JWT_JWKS_URL`).  The `sub` claim is used as the user ID.

  ## Migration from PEM file (WHISPR-386)

  The previous implementation read a static PEM public key file at startup.
  This version fetches the key from the JWKS endpoint via `JwksCache`, enabling:
  - Zero-downtime key rotation (new key takes effect on next cache refresh)
  - No shared volume mount between the auth-service and this service

  ## Configuration

  - `JWT_JWKS_URL` — JWKS endpoint URL (default: http://auth-service/auth/.well-known/jwks.json)
  - `JWT_JWKS_REFRESH_MS` — Key refresh interval in ms (default: 3_600_000)
  """

  import Plug.Conn
  require Logger

  alias WhisprMessaging.JwksCache

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_user_id(conn) do
      {:ok, user_id} ->
        assign(conn, :user_id, user_id)

      {:error, :unauthorized} ->
        conn
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp get_user_id(conn) do
    # 1. Trusted gateway header (already authenticated upstream)
    case get_req_header(conn, "x-user-id") do
      [user_id | _] when user_id != "" ->
        {:ok, user_id}

      _ ->
        # 2. Bearer JWT
        case get_req_header(conn, "authorization") do
          ["Bearer " <> token] ->
            verify_jwt(token)

          _ ->
            {:error, :unauthorized}
        end
    end
  end

  defp verify_jwt(token) do
    case maybe_test_token(token) do
      {:ok, _user_id} = ok ->
        ok

      :not_test_token ->
        # Extract kid from token header to select the correct cached key
        kid = peek_kid(token)

        with {:ok, pem} <- JwksCache.get_signing_key(kid),
             {:ok, claims} <- validate_token(token, pem),
             {:ok, user_id} <- extract_sub(claims) do
          {:ok, user_id}
        else
          {:error, :not_loaded} ->
            Logger.warning("[Authenticate] JWKS key not yet loaded — rejecting request")
            {:error, :unauthorized}

          {:error, reason} ->
            Logger.debug("[Authenticate] JWT validation failed: #{inspect(reason)}")
            {:error, :unauthorized}
        end
    end
  end

  # In the test environment, accept tokens prefixed with "test_token_" followed
  # by the user-id.  This avoids the need for a real JWKS endpoint during tests.
  if Mix.env() == :test do
    defp maybe_test_token("test_token_" <> user_id) when user_id != "" do
      {:ok, user_id}
    end
  end

  defp maybe_test_token(_token), do: :not_test_token

  # `pem` comes pre-built from JwksCache — no per-request JWK conversion.
  defp validate_token(token, pem) do
    signer = Joken.Signer.create("ES256", %{"pem" => pem})

    case Joken.verify_and_validate(token_config(), token, signer) do
      {:ok, claims} -> {:ok, claims}
      {:error, reason} -> {:error, reason}
    end
  end

  defp token_config do
    # Skip :iat and :nbf (clock-skew prone) but validate :exp so expired tokens
    # are rejected.  Do NOT list :exp in `skip` — that would disable expiration
    # validation regardless of the validate_exp option.
    Joken.Config.default_claims(skip: [:iat, :nbf])
  end

  # Attempt to read the `kid` header field from a JWT without verifying it.
  # Returns nil if the token is malformed or has no kid.
  defp peek_kid(token) do
    with [header_b64 | _] <- String.split(token, "."),
         {:ok, json} <- Base.url_decode64(header_b64, padding: false),
         {:ok, %{"kid" => kid}} when is_binary(kid) <- Jason.decode(json) do
      kid
    else
      _ -> nil
    end
  end

  defp extract_sub(%{"sub" => sub}) when is_binary(sub) and sub != "" do
    {:ok, sub}
  end

  defp extract_sub(_), do: {:error, "missing or invalid sub claim"}
end
