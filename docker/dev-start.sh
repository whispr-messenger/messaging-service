#!/bin/bash
# Development environment startup script for WhisprMessaging Service

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.dev.yml"

echo "🚀 WhisprMessaging Development Environment Startup"
echo "=================================================="
echo ""

# Check if Docker is installed
if ! command -v docker &> /dev/null; then
    echo "❌ Docker is not installed. Please install Docker first."
    exit 1
fi

# Check if Docker Compose is installed
if ! command -v docker-compose &> /dev/null; then
    echo "❌ Docker Compose is not installed. Please install Docker Compose first."
    exit 1
fi

# Build images
echo "📦 Building Docker images..."
docker-compose -f "$COMPOSE_FILE" build

# Start services
echo ""
echo "🔧 Starting services..."
docker-compose -f "$COMPOSE_FILE" up

# Note: User can stop with Ctrl+C
trap 'echo ""; echo "👋 Stopping services..."; docker-compose -f "$COMPOSE_FILE" down' EXIT
