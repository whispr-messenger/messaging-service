#!/bin/bash
# Setup script for messaging-service database
# Usage: ./scripts/setup-db.sh

set -e

# Configuration
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"
DB_USER="${DB_USER:-root}"
DB_PASSWORD="${DB_PASSWORD:-root}"
DB_NAME="${DB_NAME:-whispr_messaging_dev}"
DB_NAME_TEST="${DB_NAME_TEST:-whispr_messaging_test}"
APP_USER="${APP_USER:-messaging_service}"
APP_PASSWORD="${APP_PASSWORD:-development_password}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== Messaging Service Database Setup ===${NC}"

# Check if psql is available
if command -v psql &> /dev/null; then
    PSQL="psql"
elif [ -f "/opt/homebrew/opt/postgresql@15/bin/psql" ]; then
    PSQL="/opt/homebrew/opt/postgresql@15/bin/psql"
elif [ -f "/usr/local/opt/postgresql@15/bin/psql" ]; then
    PSQL="/usr/local/opt/postgresql@15/bin/psql"
else
    echo -e "${RED}Error: psql not found. Install PostgreSQL or use Docker.${NC}"
    exit 1
fi

export PGPASSWORD="$DB_PASSWORD"

echo -e "${YELLOW}Creating application user...${NC}"
$PSQL -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d postgres -c "
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$APP_USER') THEN
        CREATE ROLE $APP_USER WITH LOGIN PASSWORD '$APP_PASSWORD';
    END IF;
END
\$\$;
" 2>/dev/null || true

echo -e "${YELLOW}Creating development database...${NC}"
$PSQL -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d postgres -c "
SELECT 'CREATE DATABASE $DB_NAME OWNER $APP_USER'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$DB_NAME')
\gexec
" 2>/dev/null || true

echo -e "${YELLOW}Creating test database...${NC}"
$PSQL -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d postgres -c "
SELECT 'CREATE DATABASE $DB_NAME_TEST OWNER $APP_USER'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$DB_NAME_TEST')
\gexec
" 2>/dev/null || true

echo -e "${YELLOW}Granting permissions...${NC}"
$PSQL -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d postgres -c "
GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $APP_USER;
GRANT ALL PRIVILEGES ON DATABASE $DB_NAME_TEST TO $APP_USER;
" 2>/dev/null || true

echo -e "${YELLOW}Running migrations...${NC}"
cd "$(dirname "$0")/.."

if [ -f "mix.exs" ]; then
    # Elixir project
    export DATABASE_URL="postgresql://$APP_USER:$APP_PASSWORD@$DB_HOST:$DB_PORT/$DB_NAME"
    mix ecto.migrate 2>/dev/null || echo -e "${YELLOW}Note: Run 'mix ecto.migrate' manually if needed${NC}"
fi

echo ""
echo -e "${GREEN}=== Setup Complete ===${NC}"
echo ""
echo "Connection details:"
echo "  Host:     $DB_HOST"
echo "  Port:     $DB_PORT"
echo "  Database: $DB_NAME"
echo "  User:     $APP_USER"
echo "  Password: $APP_PASSWORD"
echo ""
echo "Or use superuser:"
echo "  User:     $DB_USER"
echo "  Password: $DB_PASSWORD"
