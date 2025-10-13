# CI/CD Workflows Documentation

This directory contains GitHub Actions workflows for the Whispr Messaging Service.

## 🧪 Quality Assurance Workflow (`tests.yml`)

### Overview
The Quality Assurance workflow has been adapted from the NestJS version to work with Elixir/Phoenix. It performs comprehensive code analysis, testing, and quality checks.

### Key Changes from NestJS Version

#### 1. **Environment Setup**
- **Before (NestJS):** Node.js 20
- **After (Elixir):** Elixir 1.15 + OTP 26.0
- Uses `erlef/setup-beam` action instead of Node setup

#### 2. **Dependency Management**
- **Before:** `npm install`
- **After:** `mix deps.get` + `mix deps.compile`
- Caching configured for `deps/` and `_build/` directories

#### 3. **Linting & Code Quality**

| NestJS | Elixir/Phoenix | Purpose |
|--------|----------------|---------|
| `npm run lint` | `mix format --check-formatted` | Code formatting check |
| `npx prettier --check` | `mix credo --strict` | Static code analysis |
| N/A | `mix dialyzer` | Type checking |
| N/A | `mix sobelow --config` | Security analysis |

#### 4. **Testing**

| NestJS | Elixir/Phoenix |
|--------|----------------|
| `npm run test:cov` | `mix coveralls.json --trace` |
| `npm run test:e2e` | Included in `mix test` |

#### 5. **Coverage Reporting**

| Aspect | NestJS | Elixir/Phoenix |
|--------|--------|----------------|
| Coverage Tool | Jest | ExCoveralls |
| Report Format | `lcov.info` | `excoveralls.json` |
| Output Path | `./coverage/lcov.info` | `./cover/excoveralls.json` |

#### 6. **Database Setup**

**NestJS approach:**
```yaml
DATABASE_NAME: whispr_scheduling_dev
DATABASE_USERNAME: whisper_user
DATABASE_PASSWORD: whisper_password
```

**Elixir approach:**
```yaml
DB_NAME: whispr_messaging_test
DB_USERNAME: postgres
DB_PASSWORD: postgres
```

Plus explicit migration steps:
```bash
mix ecto.create
mix ecto.migrate
```

#### 7. **Docker Compose Configuration**

**File path changes:**
- **Before:** `docker/docker-compose.dev.yml`
- **After:** `docker/dev/docker-compose.yml`

**Service name changes:**
- **Before:** `scheduling-service`
- **After:** `messaging-service` (Phoenix application)

#### 8. **Health Checks**

**NestJS:**
```bash
curl -f http://localhost:3001/api/v1/monitoring/health
```

**Elixir/Phoenix:**
- Relies on database and Redis health checks
- No explicit HTTP health check endpoint needed (yet)

### Workflow Triggers

The workflow can be triggered in three ways:

1. **Manual dispatch:**
   ```yaml
   repository_dispatch:
     types: [run-tests]
   ```

2. **Called by main CI pipeline:**
   ```yaml
   workflow_call:
     inputs:
       ref: # Git ref to test
   ```

3. **Main CI pipeline** calls this workflow when:
   - Push to `main` or `develop`
   - Pull request to `main` or `develop`

### Code Quality Tools Stack

This workflow uses **Elixir-native** code quality tools:

| Tool | Purpose | In Workflow | Blocking |
|------|---------|-------------|----------|
| **mix format** | Code formatting check | ✅ Yes | ✅ Yes |
| **Credo** | Static code analysis & style | ✅ Yes | ✅ Yes |
| **Dialyzer** | Type checking & discrepancies | ✅ Yes | ❌ No |
| **Sobelow** | Security-focused analysis | ✅ Yes | ❌ No |
| **ExCoveralls** | Code coverage tracking | ✅ Yes | ❌ No |
| **Codecov** | Coverage visualization | ✅ Yes | ❌ No |

**Why not SonarQube?**
- ❌ SonarQube does NOT officially support Elixir (as of 2025)
- ❌ Community plugin (`sonar-elixir`) is unmaintained
- ❌ Incompatible with SonarQube 10.x+
- ✅ Elixir's native tools provide superior analysis

## 📋 Required GitHub Secrets

| Secret | Required | Purpose |
|--------|----------|---------|
| `GITHUB_TOKEN` | Auto-provided | GitHub API access |
| `CODECOV_TOKEN` | Optional | Enhanced Codecov integration |

## 🚀 Running Locally

### Run the full test suite:
```bash
# Install dependencies
mix deps.get

# Run formatter check
mix format --check-formatted

# Run Credo (linter)
mix credo --strict

# Run Dialyzer (type checker)
mix dialyzer

# Run Sobelow (security analysis)
mix sobelow --config

# Run tests with coverage
mix coveralls.html

# Open coverage report
open cover/excoveralls.html
```

### Run with Docker Compose:
```bash
# Start services
docker compose -f docker/dev/docker-compose.yml up -d

# Run tests inside container
docker compose -f docker/dev/docker-compose.yml exec messaging-service mix test

# Stop services
docker compose -f docker/dev/docker-compose.yml down -v
```

## 📊 Code Coverage

Coverage reports are generated using ExCoveralls and uploaded to:
- **Codecov** (for visualization and tracking)

### Coverage Configuration

Configuration files:
- [.coveralls.exs](.coveralls.exs) - ExCoveralls settings

Minimum coverage target: **80%**

## 🔍 Static Analysis Tools

### Credo
Configuration: [.credo.exs](.credo.exs)

Credo performs static code analysis and enforces:
- Code consistency
- Design patterns
- Readability standards
- Refactoring opportunities
- Common warnings

Run with:
```bash
mix credo --strict
```

### Dialyzer
Dialyzer performs static type analysis to find type errors.

Generate PLT (first time):
```bash
mix dialyzer --plt
```

Run type checking:
```bash
mix dialyzer
```

### Sobelow
Security-focused static analysis tool for Phoenix applications.

Configuration: [.sobelow-conf](.sobelow-conf)

Sobelow checks for:
- SQL injection vulnerabilities
- XSS (Cross-Site Scripting)
- Command injection
- Directory traversal
- Insecure configurations
- Known vulnerable dependencies

Run with:
```bash
mix sobelow --config
```

Run with detailed output:
```bash
mix sobelow --verbose
```

### Mix Format
Elixir's built-in code formatter.

Configuration: [.formatter.exs](.formatter.exs)

Check formatting:
```bash
mix format --check-formatted
```

Auto-format code:
```bash
mix format
```

## 🐛 Troubleshooting

### Issue: Tests fail locally but pass in CI
**Solution:** Ensure you're using the same Elixir/OTP versions:
```bash
elixir --version  # Should be 1.15.x
erl -eval 'erlang:display(erlang:system_info(otp_release)), halt().' -noshell  # Should be 26
```

### Issue: Dialyzer takes too long
**Solution:** Dialyzer builds a PLT (Persistent Lookup Table) on first run. Subsequent runs are faster. In CI, we use caching to speed this up.

### Issue: Coverage reports not uploading
**Solution:** Verify the coverage file exists:
```bash
ls -la cover/excoveralls.json
```

### Issue: Docker services not ready
**Solution:** The workflow includes health checks and timeouts. If issues persist, increase the timeout values in the workflow.

## 📚 Additional Resources

- [Elixir Testing Guide](https://hexdocs.pm/ex_unit/ExUnit.html)
- [ExCoveralls Documentation](https://hexdocs.pm/excoveralls/)
- [Credo Documentation](https://hexdocs.pm/credo/)
- [Dialyxir Documentation](https://hexdocs.pm/dialyxir/)
- [GitHub Actions for Elixir](https://github.com/erlef/setup-beam)
