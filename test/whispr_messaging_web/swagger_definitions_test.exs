defmodule WhisprMessagingWeb.SwaggerDefinitionsTest do
  @moduledoc """
  Exercises `swagger_definitions/0` of each controller — these are runtime
  functions executed by PhoenixSwagger to build the /swagger document.
  Tests cover them so they're not counted as dead code in coverage.
  """
  use ExUnit.Case, async: true

  test "ConversationController.swagger_definitions/0 returns a map of schemas" do
    defs = WhisprMessagingWeb.ConversationController.swagger_definitions()
    assert is_map(defs)
    assert map_size(defs) > 0
  end

  test "ConversationMemberController.swagger_definitions/0 returns a map of schemas" do
    defs = WhisprMessagingWeb.ConversationMemberController.swagger_definitions()
    assert is_map(defs)
  end

  test "MessageController.swagger_definitions/0 returns a map of schemas" do
    defs = WhisprMessagingWeb.MessageController.swagger_definitions()
    assert is_map(defs)
    assert map_size(defs) > 0
  end

  test "ScheduledMessageController.swagger_definitions/0 returns a map of schemas" do
    defs = WhisprMessagingWeb.ScheduledMessageController.swagger_definitions()
    assert is_map(defs)
  end

  test "DraftController.swagger_definitions/0 returns a map of schemas" do
    defs = WhisprMessagingWeb.DraftController.swagger_definitions()
    assert is_map(defs)
  end

  test "AttachmentController.swagger_definitions/0 returns a map of schemas" do
    defs = WhisprMessagingWeb.AttachmentController.swagger_definitions()
    assert is_map(defs)
  end

  test "ReportController.swagger_definitions/0 returns a map of schemas" do
    defs = WhisprMessagingWeb.ReportController.swagger_definitions()
    assert is_map(defs)
  end

  test "SanctionController.swagger_definitions/0 returns a map of schemas" do
    defs = WhisprMessagingWeb.SanctionController.swagger_definitions()
    assert is_map(defs)
  end

  test "HealthController.swagger_definitions/0 returns a map of schemas" do
    defs = WhisprMessagingWeb.HealthController.swagger_definitions()
    assert is_map(defs)
  end

  test "AnalyticsController.swagger_path_dashboard/1 returns a Path-like value" do
    path =
      WhisprMessagingWeb.AnalyticsController.swagger_path_dashboard(
        %PhoenixSwagger.Path.PathObject{}
      )

    # The path is returned as a struct; we just exercise the function.
    assert is_struct(path) or is_map(path)
  end
end
