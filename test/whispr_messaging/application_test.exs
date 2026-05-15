defmodule WhisprMessaging.ApplicationTest do
  use ExUnit.Case, async: true

  describe "config_change/3" do
    test "delegates to the Endpoint and returns :ok" do
      # No real config to change; we just exercise the callback so the line
      # is covered. The endpoint accepts an empty changed list.
      assert :ok = WhisprMessaging.Application.config_change([], [], [])
    end
  end
end
