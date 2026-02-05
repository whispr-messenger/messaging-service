defmodule WhisprMessagingWeb.SwaggerInfo do
  @moduledoc """
  Swagger API documentation configuration.
  """

  use PhoenixSwagger

  def swagger_info do
    # Get the base URL from environment or use default
    base_url = System.get_env("SWAGGER_BASE_URL") || "localhost"

    # Determine scheme based on environment
    scheme =
      case System.get_env("MIX_ENV") do
        "prod" -> "https"
        _ -> "http"
      end

    # Get port from HTTP_PORT environment variable
    port_str = System.get_env("HTTP_PORT") || "4000"
    port = ":#{port_str}"

    # Remove port for standard ports (80 for http, 443 for https)
    port =
      case {scheme, port} do
        {"http", ":80"} -> ""
        {"https", ":443"} -> ""
        _ -> port
      end

    host_with_port = "#{base_url}#{port}"

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
      host: host_with_port,
      basePath: "/api/v1",
      schemes: [scheme],
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
