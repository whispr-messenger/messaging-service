defmodule WhisprMessagingWeb.JsonHelpers do
  @moduledoc """
  Helper functions for JSON serialization.

  Provides camelCase key conversion for API responses to match
  the spec contract (e.g., `conversationId` instead of `conversation_id`).
  """

  @doc """
  Converts a map with snake_case atom keys to camelCase string keys.

  Recursively converts nested maps and lists.

  ## Examples

      iex> camelize_keys(%{conversation_id: "abc", sender_id: "def"})
      %{"conversationId" => "abc", "senderId" => "def"}

      iex> camelize_keys(%{members: [%{user_id: "abc", is_active: true}]})
      %{"members" => [%{"userId" => "abc", "isActive" => true}]}
  """
  @spec camelize_keys(map() | list()) :: map() | list()
  def camelize_keys(%{__struct__: _} = struct), do: struct

  def camelize_keys(%{} = map) do
    Map.new(map, fn {key, value} ->
      {camelize_key(key), camelize_value(value)}
    end)
  end

  def camelize_keys(list) when is_list(list) do
    Enum.map(list, &camelize_keys/1)
  end

  def camelize_keys(value), do: value

  defp camelize_value(%{__struct__: _} = struct), do: struct
  defp camelize_value(%{} = map), do: camelize_keys(map)
  defp camelize_value(list) when is_list(list), do: Enum.map(list, &camelize_value/1)
  defp camelize_value(value), do: value

  defp camelize_key(key) when is_atom(key) do
    key
    |> Atom.to_string()
    |> snake_to_camel()
  end

  defp camelize_key(key) when is_binary(key) do
    snake_to_camel(key)
  end

  defp camelize_key(key), do: key

  defp snake_to_camel(string) do
    [first | rest] = String.split(string, "_")
    Enum.join([first | Enum.map(rest, &String.capitalize/1)])
  end
end
