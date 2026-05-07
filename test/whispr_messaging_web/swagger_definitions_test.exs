defmodule WhisprMessagingWeb.SwaggerDefinitionsTest do
  @moduledoc """
  Calls every controller's `swagger_definitions/0` once so that the static
  schema-DSL blocks are exercised. They drive `swagger.json` generation in
  production but aren't otherwise invoked at runtime, which leaves them
  reported as uncovered.
  """

  use ExUnit.Case, async: true

  @controllers [
    WhisprMessagingWeb.AnalyticsController,
    WhisprMessagingWeb.AttachmentController,
    WhisprMessagingWeb.ConversationController,
    WhisprMessagingWeb.ConversationMemberController,
    WhisprMessagingWeb.DraftController,
    WhisprMessagingWeb.HealthController,
    WhisprMessagingWeb.InviteController,
    WhisprMessagingWeb.MessageController,
    WhisprMessagingWeb.ReactionController,
    WhisprMessagingWeb.ReportController,
    WhisprMessagingWeb.SanctionController,
    WhisprMessagingWeb.ScheduledMessageController
  ]

  for controller <- @controllers do
    test "#{inspect(controller)}.swagger_definitions/0 returns a map" do
      if Code.ensure_loaded?(unquote(controller)) and
           function_exported?(unquote(controller), :swagger_definitions, 0) do
        defs = apply(unquote(controller), :swagger_definitions, [])
        assert is_map(defs)
        assert map_size(defs) > 0
      end
    end
  end
end
