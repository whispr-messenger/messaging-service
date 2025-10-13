defmodule WhisprMessaging.GRPC.Endpoint do
  @moduledoc """
  gRPC Endpoint that aggregates all gRPC services.

  This endpoint serves as the main entry point for gRPC requests.
  Services are registered here and will be available once their
  .proto files are defined and compiled.

  NOTE: Currently disabled until gRPC services are properly implemented.
  """

  use GRPC.Endpoint

  # Temporarily commented out until gRPC logging is configured
  # intercept(GRPC.Logger.Server)

  # Services will be added here once proto files are generated
  # Example:
  # run(WhisprMessaging.GRPC.Services.MessagingService.Server)
end
