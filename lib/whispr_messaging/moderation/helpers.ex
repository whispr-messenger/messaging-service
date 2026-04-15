defmodule WhisprMessaging.Moderation.Helpers do
  @moduledoc """
  Shared helper functions for moderation contexts.
  """

  require Logger

  @doc """
  Applies `fun` to the unwrapped value of `{:ok, value}` tuples,
  then returns the original result unchanged. Error tuples pass through.
  """
  def tap_ok({:ok, value} = result, fun) do
    fun.(value)
    result
  end

  def tap_ok(error, _fun), do: error

  @doc """
  Publishes a message to a Redis channel via Redix.
  Catches any error so the caller is never crashed by a Redis failure.
  """
  def redis_publish(channel, payload) do
    Redix.command(:redix, ["PUBLISH", channel, payload])
  rescue
    error ->
      Logger.error("[Moderation] Redis publish failed on #{channel}: #{inspect(error)}")
  end
end
