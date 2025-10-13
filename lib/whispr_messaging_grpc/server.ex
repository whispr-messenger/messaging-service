defmodule WhisprMessaging.GRPC.Server do
  @moduledoc """
  gRPC Server configuration for WhisprMessaging service.

  This module defines the gRPC server that exposes messaging functionalities
  to other microservices in the Whispr ecosystem.

  NOTE: gRPC service is currently disabled. To enable:
  1. Define your protobuf services
  2. Compile them with protoc
  3. Update the service list below
  """

  # Temporarily disabled until gRPC services are properly defined
  # use GRPC.Server, service: []

  @doc """
  Returns the gRPC server configuration for supervision.

  This is called by the application supervisor to start the gRPC server.
  """
  def child_spec(_port) do
    # TODO: Re-enable when gRPC services are implemented
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, []}
    }
  end

  def start_link do
    :ignore
  end
end
