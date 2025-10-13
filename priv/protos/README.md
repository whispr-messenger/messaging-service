# Protocol Buffer Definitions

This directory contains the `.proto` files that define the gRPC services for WhisprMessaging.

## Generating Elixir Code

To generate Elixir code from these proto files, run:

```bash
# From the project root
protoc --elixir_out=plugins=grpc:./lib/whispr_messaging_grpc priv/protos/*.proto
```

Or use the Mix task (if configured):

```bash
mix protobuf.generate
```

## Proto Files

- `messaging_service.proto`: Main messaging service API for inter-service communication

## Adding New Services

1. Create a new `.proto` file in this directory
2. Define your service and messages
3. Run the code generation command
4. Implement the service in `lib/whispr_messaging_grpc/services/`
5. Register the service in `lib/whispr_messaging_grpc/endpoint.ex`

## Service Design Guidelines

- Use semantic versioning in package names (e.g., `whispr.messaging.v1`)
- Document all services and messages with comments
- Use appropriate field types (timestamps as int64, IDs as string)
- Include error fields in response messages for proper error handling
- Keep messages focused and cohesive

## References

- [Protocol Buffers Language Guide](https://protobuf.dev/programming-guides/proto3/)
- [gRPC Elixir Documentation](https://hexdocs.pm/grpc/)
