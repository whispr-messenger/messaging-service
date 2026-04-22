defmodule WhisprMessaging.Services.UserService do
  @moduledoc """
  Interface for interacting with the User Service via gRPC.
  Currently a stub implementation.
  """

  def check_users_are_contacts(owner_id, other_user_id, authorization_header \\ nil) do
    base_url = System.get_env("USER_SERVICE_HTTP_URL", "http://user-service:3002/user/v1")

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
       when pages >= 10 do
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
    limit = 200

    url =
      base_url <>
        "/contacts?limit=#{limit}" <>
        if(cursor, do: "&cursor=#{URI.encode_www_form(to_string(cursor))}", else: "")

    headers =
      [{"accept", "application/json"}] ++
        if(is_binary(authorization_header) and String.trim(authorization_header) != "",
          do: [{"authorization", authorization_header}],
          else: []
        )

    req = Finch.build(:get, url, headers)

    case Finch.request(req, WhisprMessaging.Finch) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        with {:ok, json} <- Jason.decode(body) do
          data = if(is_map(json) and Map.has_key?(json, "data"), do: json["data"], else: json)

          items =
            cond do
              is_list(data) -> data
              is_map(data) and is_list(data["contacts"]) -> data["contacts"]
              is_map(data) and is_list(data["data"]) -> data["data"]
              true -> []
            end

          found =
            Enum.any?(items, fn item ->
              contact_id =
                (is_map(item) && (item["contactId"] || item["contact_id"])) ||
                  (is_map(item) && (item["id"] || item["contact_id"])) ||
                  nil

              to_string(contact_id || "") == other_user_id
            end)

          if found do
            {:ok, true}
          else
            next_cursor =
              (is_map(json) && (json["nextCursor"] || json["next_cursor"])) ||
                (is_map(data) && (data["nextCursor"] || data["next_cursor"])) ||
                nil

            has_more =
              (is_map(json) && (json["hasMore"] || json["has_more"])) ||
                (is_map(data) && (data["hasMore"] || data["has_more"])) ||
                false

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
        else
          _ -> {:error, :invalid_response}
        end

      {:ok, %Finch.Response{status: status}} when status in [401, 403] ->
        {:error, :unauthorized}

      {:ok, %Finch.Response{status: status}} when status in [404] ->
        {:ok, false}

      {:ok, %Finch.Response{status: _status}} ->
        {:error, :request_failed}

      {:error, _reason} ->
        {:error, :request_failed}
    end
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
