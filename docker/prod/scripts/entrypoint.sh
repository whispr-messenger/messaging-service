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
echo "Step 2: Running database migrations..."
# swagger.json is pre-generated at build time (host omitted per Swagger 2.0 spec)
/app/bin/whispr_messaging eval "WhisprMessaging.Release.migrate()"

echo ""
echo "Step 3: Starting application..."
echo "=================================================="
echo ""

# Start the application
exec /app/bin/whispr_messaging start
