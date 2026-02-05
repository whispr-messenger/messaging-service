#!/bin/bash
set -e

echo "=================================================="
echo "  Starting Whispr Messaging Service (Production)"
echo "=================================================="
echo ""

# Run environment checks
echo "Step 1: Validating environment variables..."
/app/check-env.sh

if [ $? -ne 0 ]; then
    echo "Environment validation failed. Exiting."
    exit 1
fi

echo ""
echo "Step 2: Generating Swagger documentation..."
# Generate swagger.json with runtime environment variables
/app/bin/whispr_messaging eval "
  # Ensure swagger info is loaded with current env vars
  spec = WhisprMessagingWeb.Router.swagger_info()
  json = Jason.encode!(spec, pretty: true)
  File.write!('/app/lib/whispr_messaging-1.0.0/priv/static/swagger.json', json)
  IO.puts('Swagger documentation generated successfully')
"

echo ""
echo "Step 3: Running database migrations..."
/app/bin/whispr_messaging eval "WhisprMessaging.Release.migrate()"

echo ""
echo "Step 4: Starting application..."
echo "=================================================="
echo ""

# Start the application
exec /app/bin/whispr_messaging start
