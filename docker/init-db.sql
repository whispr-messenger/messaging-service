-- Database initialization script for WhisprMessaging
-- This script sets up the database with required extensions and initial configuration

-- Enable UUID extension (required for binary_id primary keys)
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Enable pgcrypto extension for encryption functions
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- Enable pg_stat_statements for query performance monitoring
CREATE EXTENSION IF NOT EXISTS "pg_stat_statements";

-- Create application-specific database user (if needed)
-- Note: In production, this should be handled by your infrastructure/deployment scripts
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'messaging_service') THEN
        CREATE ROLE messaging_service WITH LOGIN PASSWORD 'development_password';
    END IF;
END
$$;

-- Grant necessary permissions
GRANT CONNECT ON DATABASE whispr_messaging_dev TO messaging_service;
GRANT USAGE ON SCHEMA public TO messaging_service;
GRANT CREATE ON SCHEMA public TO messaging_service;

-- Set up recommended PostgreSQL settings for messaging workloads
-- These are development settings; adjust for production

-- Configure shared_preload_libraries (requires restart)
-- shared_preload_libraries = 'pg_stat_statements'

-- Memory settings
-- shared_buffers = 256MB
-- effective_cache_size = 1GB
-- work_mem = 16MB
-- maintenance_work_mem = 64MB

-- Logging settings for development
-- log_statement = 'all'
-- log_duration = on
-- log_min_duration_statement = 100

-- Connection settings
-- max_connections = 200

-- Write ahead log settings
-- wal_buffers = 16MB
-- checkpoint_completion_target = 0.9

-- Query planner settings
-- random_page_cost = 1.1
-- effective_io_concurrency = 200

-- Create initial database schema comment
COMMENT ON DATABASE whispr_messaging_dev IS 'WhisprMessenger real-time messaging service database';

-- Create a simple health check function
CREATE OR REPLACE FUNCTION health_check()
RETURNS TEXT AS $$
BEGIN
    RETURN 'Database is healthy at ' || NOW();
END;
$$ LANGUAGE plpgsql;

-- Create function to get database statistics
CREATE OR REPLACE FUNCTION get_db_stats()
RETURNS TABLE(
    total_size TEXT,
    table_count BIGINT,
    index_count BIGINT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        pg_size_pretty(pg_database_size(current_database())) as total_size,
        (SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public') as table_count,
        (SELECT count(*) FROM pg_indexes WHERE schemaname = 'public') as index_count;
END;
$$ LANGUAGE plpgsql;