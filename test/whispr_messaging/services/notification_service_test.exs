defmodule WhisprMessaging.Services.NotificationServiceTest do
  use ExUnit.Case, async: true

  alias WhisprMessaging.Services.NotificationService

  test "queue_push_notifications/2 returns {:ok, :queued}" do
    assert {:ok, :queued} =
             NotificationService.queue_push_notifications(
               ["u1", "u2"],
               %{id: "m1"}
             )
  end

  test "queue_push_notifications/2 accepts an empty user list" do
    assert {:ok, :queued} = NotificationService.queue_push_notifications([], %{id: "m1"})
  end
end
