defmodule WhisprMessaging.Services.UserService do
  @moduledoc """
  Facade pour parler avec user-service.

  L'autorisation des conversations directes passe par l'endpoint interne
  `GET {USER_SERVICE_INTERNAL_URL}/contacts/check?ownerId=...&contactId=...`,
  qui renvoie `{ "isContact": bool, "isBlocked": bool }` en un seul
  aller-retour - pas de pagination, pas de scan cote client.
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
    Keyword.get(config, :token) || System.get_env("INTERNAL_API_TOKEN")
  end

  @doc """
  Renvoie `{:ok, true}` quand `owner_id` et `other_user_id` sont contacts
  mutuels et qu'aucun n'a bloque l'autre, `{:ok, false}` sinon.
  L'argument `_authorization_header` est garde par compat avec les
  call sites existants mais n'est plus utilise : l'endpoint interne
  s'authentifie via le secret partage `x-internal-token`, pas le JWT
  end-user.
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
        base ++ [{"x-internal-token", token}]

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
  Verifie l'existence d'un utilisateur.

  Delegue au module configure dans
  `:whispr_messaging, :user_service_client` (defaut :
  `WhisprMessaging.Services.HttpUserServiceClient`). Voir le behaviour
  `WhisprMessaging.Services.UserServiceBehaviour` pour le contrat.
  """
  def check_user_exists(user_id) do
    client().check_user_exists(user_id)
  end

  @doc """
  Verifie si un utilisateur est bloque par un autre.

  Renvoie `{:ok, true}` si bloque, `{:ok, false}` sinon. Sur erreur
  transitoire les appelants doivent fail-closed (considerer comme
  bloque) : cette fonction renvoie `{:error, _}` dans ce cas pour que
  la chaine `with` court-circuite.
  """
  def check_user_blocked(blocker_id, blocked_id) do
    client().check_user_blocked(blocker_id, blocked_id)
  end

  @doc false
  def client do
    Application.get_env(
      :whispr_messaging,
      :user_service_client,
      WhisprMessaging.Services.HttpUserServiceClient
    )
  end
end
