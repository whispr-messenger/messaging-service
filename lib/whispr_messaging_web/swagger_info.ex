defmodule WhisprMessagingWeb.SwaggerInfo do
  @moduledoc """
  Swagger API documentation configuration.
  """

  use PhoenixSwagger

  def swagger_info do
    # host and schemes are intentionally omitted: per Swagger 2.0 spec, when host
    # is absent the SwaggerUI uses window.location.host for "Try it out" requests.
    # This makes the spec environment-agnostic and allows build-time generation.
    %{
      swagger: "2.0",
      info: %{
        version: "1.0.0",
        title: "Whispr Messaging Service API",
        description: """
        RESTful API for the Whispr Messaging Service.

        This service handles:
        - Real-time messaging between users
        - Conversation management (1-on-1 and group chats)
        - Message delivery and read receipts
        - Message attachments
        - Conversation members management

        ## Authentication
        All endpoints (except health checks) require a valid JWT token in the Authorization header:
        ```
        Authorization: Bearer <your-jwt-token>
        ```
        """,
        contact: %{
          name: "Whispr Team",
          email: "gabriel.lopez@epitech.eu"
        }
      },
      basePath: "/api/v1",
      consumes: ["application/json"],
      produces: ["application/json"],
      securityDefinitions: %{
        Bearer: %{
          type: "apiKey",
          name: "Authorization",
          in: "header",
          description: "JWT authorization token. Format: 'Bearer {token}'"
        }
      },
      tags: [
        %{name: "Health", description: "Health check endpoints"},
        %{name: "Conversations", description: "Conversation management"},
        %{name: "Messages", description: "Message operations"},
        %{name: "Attachments", description: "Message attachments"}
      ]
    }
  end

  def swagger_path_("/api/swagger") do
    # This is just a placeholder for the swagger UI endpoint
  end
end
