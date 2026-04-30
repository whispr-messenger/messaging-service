defmodule WhisprMessaging.Services.UserService do
  @moduledoc """
  Interface for interacting with the User Service.

  Direct-conversation authorisation goes through the internal HTTP endpoint
  `GET {USER_SERVICE_INTERNAL_URL}/contacts/check?ownerId=...&contactId=...`,
  which returns `{ "isContact": bool, "isBlocked": bool }` in a single round
  trip — no pagination, no client-side scan.
  """

  @default_internal_url "http://user-service:3011/internal/v1"

  @doc false
  def internal_base_url do
    config = Application.get_env(:whispr_messaging, :user_service_internal, [])

    Keyword.get(config, :url) ||
      System.get_env("USER_SERVICE_INTERNAL_URL", @default_internal_url)
  end

  @doc false
  def internal_token do
    config = Application.get_env(:whispr_messaging, :user_service_internal, [])
    Keyword.get(config, :token) || System.get_env("USER_SERVICE_INTERNAL_TOKEN")
  end

  @doc """
  Returns `{:ok, true}` when `owner_id` and `other_user_id` are mutual contacts
  and neither has blocked the other, `{:ok, false}` otherwise. The
  `_authorization_header` argument is kept for backwards compatibility with
  existing call sites but is unused: the internal endpoint authenticates the
  caller via a service token, not the end-user JWT.
  """
  def check_users_are_contacts(owner_id, other_user_id, _authorization_header \\ nil) do
    owner = String.trim(to_string(owner_id))
    other = String.trim(to_string(other_user_id))

    url =
      internal_base_url() <>
        "/contacts/check?ownerId=" <>
        URI.encode_www_form(owner) <>
        "&contactId=" <> URI.encode_www_form(other)

    :get
    |> Finch.build(url, build_headers())
    |> Finch.request(WhisprMessaging.Finch)
    |> handle_check_response()
  end

  defp build_headers do
    base = [{"accept", "application/json"}]

    case internal_token() do
      token when is_binary(token) and token != "" ->
        base ++ [{"authorization", "Bearer " <> token}]

      _ ->
        base
    end
  end

  defp handle_check_response({:ok, %Finch.Response{status: 200, body: body}}) do
    case Jason.decode(body) do
      {:ok, %{"isContact" => is_contact} = json} ->
        is_blocked = Map.get(json, "isBlocked", false) == true
        {:ok, is_contact == true and not is_blocked}

      _ ->
        {:error, :invalid_response}
    end
  end

  defp handle_check_response({:ok, %Finch.Response{status: status}})
       when status in [401, 403] do
    {:error, :unauthorized}
  end

  defp handle_check_response({:ok, %Finch.Response{}}), do: {:error, :request_failed}
  defp handle_check_response({:error, _reason}), do: {:error, :request_failed}

  @doc """
  Checks if a user exists.
  """
  def check_user_exists(_user_id) do
    # Stub: returns true until gRPC integration with user service is done
    # For now, assume user exists
    {:ok, true}
  end

  @doc """
  Checks if a user is blocked by another user.
  Returns {:ok, boolean} where boolean is true if blocked.
  """
  def check_user_blocked(_blocker_id, _blocked_id) do
    # Stub: returns false until gRPC integration with user service is done
    # For now, assume not blocked
    {:ok, false}
  end
end
