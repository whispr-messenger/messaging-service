defmodule WhisprMessaging.Services.UserService do
  @moduledoc """
  Interface for interacting with the User Service via gRPC.
  Currently a stub implementation.
  """

  @doc """
  Checks if a user exists.
  """
  def check_user_exists(_user_id) do
    # TODO: Implement actual gRPC call
    # For now, assume user exists
    {:ok, true}
  end

  @doc """
  Checks if a user is blocked by another user.
  Returns {:ok, boolean} where boolean is true if blocked.
  """
  def check_user_blocked(_blocker_id, _blocked_id) do
    # TODO: Implement actual gRPC call
    # For now, assume not blocked
    {:ok, false}
  end
end
