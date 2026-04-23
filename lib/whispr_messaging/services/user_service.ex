defmodule WhisprMessaging.Services.UserService do
  @moduledoc """
  Interface for interacting with the User Service via gRPC.
  Currently a stub implementation.
  """

  @max_pages 10
  @page_limit 200
  # user-service's HTTP port is 3011 in the k8s Service (see
  # infrastructure/k8s/whispr/preprod/user-service/service.yaml). Keep the
  # fallback aligned with the cluster port — the messaging-service Deployment
  # does not export USER_SERVICE_HTTP_URL, so this default is what is used in
  # practice.
  @default_user_service_url "http://user-service:3011/user/v1"

  @doc false
  def user_service_base_url do
    System.get_env("USER_SERVICE_HTTP_URL", @default_user_service_url)
  end

  def check_users_are_contacts(owner_id, other_user_id, authorization_header \\ nil) do
    base_url = user_service_base_url()

    do_check_users_are_contacts(
      String.trim(to_string(owner_id)),
      String.trim(to_string(other_user_id)),
      authorization_header,
      base_url,
      nil,
      0
    )
  end

  defp do_check_users_are_contacts(_owner_id, _other_user_id, _auth, _base_url, _cursor, pages)
       when pages >= @max_pages do
    {:ok, false}
  end

  defp do_check_users_are_contacts(
         owner_id,
         other_user_id,
         authorization_header,
         base_url,
         cursor,
         pages
       ) do
    url = build_contacts_url(base_url, cursor)
    headers = build_headers(authorization_header)
    req = Finch.build(:get, url, headers)

    req
    |> Finch.request(WhisprMessaging.Finch)
    |> handle_contacts_response(
      owner_id,
      other_user_id,
      authorization_header,
      base_url,
      pages
    )
  end

  defp build_contacts_url(base_url, nil) do
    base_url <> "/contacts?limit=#{@page_limit}"
  end

  defp build_contacts_url(base_url, cursor) do
    base_url <>
      "/contacts?limit=#{@page_limit}&cursor=#{URI.encode_www_form(to_string(cursor))}"
  end

  defp build_headers(authorization_header) do
    base = [{"accept", "application/json"}]

    if is_binary(authorization_header) and String.trim(authorization_header) != "" do
      base ++ [{"authorization", authorization_header}]
    else
      base
    end
  end

  defp handle_contacts_response(
         {:ok, %Finch.Response{status: 200, body: body}},
         owner_id,
         other_user_id,
         authorization_header,
         base_url,
         pages
       ) do
    case Jason.decode(body) do
      {:ok, json} ->
        process_contacts_page(
          json,
          owner_id,
          other_user_id,
          authorization_header,
          base_url,
          pages
        )

      _ ->
        {:error, :invalid_response}
    end
  end

  defp handle_contacts_response(
         {:ok, %Finch.Response{status: status}},
         _owner_id,
         _other_user_id,
         _authorization_header,
         _base_url,
         _pages
       )
       when status in [401, 403] do
    {:error, :unauthorized}
  end

  defp handle_contacts_response(
         {:ok, %Finch.Response{status: 404}},
         _owner_id,
         _other_user_id,
         _authorization_header,
         _base_url,
         _pages
       ) do
    {:ok, false}
  end

  defp handle_contacts_response({:ok, %Finch.Response{}}, _, _, _, _, _) do
    {:error, :request_failed}
  end

  defp handle_contacts_response({:error, _reason}, _, _, _, _, _) do
    {:error, :request_failed}
  end

  defp process_contacts_page(
         json,
         owner_id,
         other_user_id,
         authorization_header,
         base_url,
         pages
       ) do
    data = extract_data(json)
    items = extract_items(data)

    if contact_found?(items, other_user_id) do
      {:ok, true}
    else
      maybe_fetch_next_page(
        json,
        data,
        owner_id,
        other_user_id,
        authorization_header,
        base_url,
        pages
      )
    end
  end

  defp extract_data(json) when is_map(json) do
    if Map.has_key?(json, "data"), do: json["data"], else: json
  end

  defp extract_data(json), do: json

  defp extract_items(data) when is_list(data), do: data

  defp extract_items(data) when is_map(data) do
    cond do
      is_list(data["contacts"]) -> data["contacts"]
      is_list(data["data"]) -> data["data"]
      true -> []
    end
  end

  defp extract_items(_), do: []

  defp contact_found?(items, other_user_id) do
    Enum.any?(items, fn item -> item_matches?(item, other_user_id) end)
  end

  defp item_matches?(item, other_user_id) when is_map(item) do
    contact_id = item["contactId"] || item["contact_id"] || item["id"]
    to_string(contact_id || "") == other_user_id
  end

  defp item_matches?(_item, _other_user_id), do: false

  defp maybe_fetch_next_page(
         json,
         data,
         owner_id,
         other_user_id,
         authorization_header,
         base_url,
         pages
       ) do
    next_cursor = pick_field(json, data, ["nextCursor", "next_cursor"])
    has_more = pick_field(json, data, ["hasMore", "has_more"]) || false

    if next_cursor && has_more do
      do_check_users_are_contacts(
        owner_id,
        other_user_id,
        authorization_header,
        base_url,
        next_cursor,
        pages + 1
      )
    else
      {:ok, false}
    end
  end

  defp pick_field(json, data, keys) do
    from_json = if is_map(json), do: first_present(json, keys), else: nil
    from_json || if(is_map(data), do: first_present(data, keys), else: nil)
  end

  defp first_present(map, keys) do
    Enum.find_value(keys, fn key -> map[key] end)
  end

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

