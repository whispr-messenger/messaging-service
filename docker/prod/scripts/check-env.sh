#!/bin/bash

# Environment validation for production container

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

MISSING_VARS=0
OPTIONAL_VARS=0

check_required() {
    local var_name=$1
    local value="${!var_name}"
    
    if [ -z "$value" ] || [ -z "$(echo "$value" | xargs)" ]; then
        echo -e "${RED}✗${NC} $var_name is NOT set (REQUIRED)"
        ((MISSING_VARS++))
        return 1
    fi
    echo -e "${GREEN}✓${NC} $var_name is set"
    return 0
}

check_optional() {
    local var_name=$1
    local default_value="${2:-}"
    local value="${!var_name}"
    
    if [ -z "$value" ] || [ -z "$(echo "$value" | xargs)" ]; then
        local msg=""
        if [ -n "$default_value" ]; then
            msg=" (will use default: $default_value)"
        fi
        echo -e "${YELLOW}⚠${NC} $var_name is NOT set${msg}"
        ((OPTIONAL_VARS++))
        return 1
    fi
    echo -e "${GREEN}✓${NC} $var_name is set"
    return 0
}

echo "=================================================="
echo "  Whispr Messaging Service - Environment Check"
echo "=================================================="
echo ""

echo "Checking REQUIRED environment variables..."

# Mix/Elixir
check_required "MIX_ENV"

# Database
check_required "DB_HOST"
check_required "DB_PORT"
check_required "DB_USERNAME"
check_required "DB_PASSWORD"
check_required "DB_NAME"

# Phoenix
check_required "SECRET_KEY_BASE"
check_required "PHX_HOST"

# Ports
check_required "HTTP_PORT"
check_required "GRPC_PORT"

# Redis
check_required "REDIS_HOST"
check_required "REDIS_PORT"

# gRPC services
check_required "SCHEDULING_SERVICE_GRPC_URL"

# Encryption
check_required "ENCRYPTION_KEY"
check_required "JWT_SECRET"

echo ""
echo "Checking OPTIONAL environment variables..."

check_optional "DB_POOL_SIZE" "10"
check_optional "REDIS_DB" "0"
check_optional "REDIS_PASSWORD" "(no password)"
check_optional "PHX_PORT" "3999"
check_optional "LOG_LEVEL" "info"
check_optional "HTTPS_PORT" "4443"

echo ""
echo "=================================================="

if [ $MISSING_VARS -gt 0 ]; then
    echo -e "${RED}ERROR: $MISSING_VARS required environment variable(s) missing!${NC}"
    exit 1
fi

if [ $OPTIONAL_VARS -gt 0 ]; then
    echo -e "${YELLOW}WARNING: $OPTIONAL_VARS optional environment variable(s) not set.${NC}"
fi

echo -e "${GREEN}✓ All required environment variables are set!${NC}"
echo "=================================================="
echo ""
