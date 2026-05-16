defmodule WhisprMessagingWeb.PresenceHelpers do
  @moduledoc """
  Pure helpers extracted from `Presence` so the status-resolution logic can
  be unit-tested without spinning up Phoenix.Presence. External behavior of
  `Presence` is unchanged — the public functions delegate here.
  """

  @doc """
  Reduces a list of meta entries (one per active socket) into a single
  status string, applying the priority `online > away > busy > offline`.
  """
  @spec current_status([map()]) :: String.t()
  def current_status(metas) do
    metas
    |> Enum.map(&Map.get(&1, :status, "online"))
    |> Enum.reduce("offline", fn status, acc ->
      case {status, acc} do
        {"online", _} -> "online"
        {"away", "offline"} -> "away"
        {"away", "busy"} -> "away"
        {"busy", "offline"} -> "busy"
        {_, current} -> current
      end
    end)
  end

  @doc """
  Returns the maximum `:online_at` value across all metas. Defaults to 0
  when none of the entries have the key.
  """
  @spec latest_online_at([map()]) :: integer()
  def latest_online_at(metas) do
    metas
    |> Enum.map(&Map.get(&1, :online_at, 0))
    |> Enum.max(fn -> 0 end)
  end

  @doc """
  Returns the maximum `:started_at` value across all typing-meta entries.
  Used to surface the earliest start timestamp.
  """
  @spec latest_typing_start([map()]) :: integer()
  def latest_typing_start(metas) do
    metas
    |> Enum.map(&Map.get(&1, :started_at, 0))
    |> Enum.max(fn -> 0 end)
  end

  @doc """
  Annotates each meta with the user_id and (if missing) a computed
  device_info map.
  """
  @spec enrich_metas([map()], String.t()) :: [map()]
  def enrich_metas(metas, user_id) do
    Enum.map(metas, fn meta ->
      meta
      |> Map.put(:user_id, user_id)
      |> Map.put_new(:device_info, device_info(meta))
    end)
  end

  @doc """
  Returns the platform/version pair from a meta map, defaulting to
  `"unknown"` when keys are missing.
  """
  @spec device_info(map()) :: %{platform: String.t(), version: String.t()}
  def device_info(meta) do
    %{
      platform: Map.get(meta, :platform, "unknown"),
      version: Map.get(meta, :version, "unknown")
    }
  end
end
