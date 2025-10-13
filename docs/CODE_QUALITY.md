# Code Quality Tools for Whispr Messaging Service

This document describes the code quality and security analysis tools used in the Whispr Messaging Service Elixir/Phoenix application.

## 🎯 Why Not SonarQube?

**TL;DR:** SonarQube does not support Elixir.

### The Situation

- ❌ **No Official Support:** SonarQube supports 35+ languages, but Elixir is NOT one of them (as of 2025)
- ❌ **Abandoned Plugin:** The community `sonar-elixir` plugin is unmaintained and incompatible with SonarQube 10.x+
- ❌ **No Roadmap:** There are no plans from SonarSource to add Elixir support
- ✅ **Better Alternatives:** Elixir's native ecosystem has excellent, purpose-built tools

### Our Approach

We use **Elixir-native tools** that provide comprehensive code quality analysis specifically designed for the BEAM ecosystem.

## 🛠️ Code Quality Tools Stack

### 1. **mix format** - Code Formatting

**Purpose:** Enforce consistent code formatting across the codebase

**Configuration:** [.formatter.exs](../.formatter.exs)

**Usage:**
```bash
# Check formatting
mix format --check-formatted

# Auto-format code
mix format
```

**In CI:** ✅ **Blocking** - Fails if code is not properly formatted

**Key Features:**
- Built into Elixir
- Zero configuration needed
- Deterministic formatting
- Fast execution

---

### 2. **Credo** - Static Code Analysis

**Purpose:** Code style, consistency, and refactoring suggestions

**Configuration:** [.credo.exs](../.credo.exs)

**Usage:**
```bash
# Run with strict checks
mix credo --strict

# Get detailed explanation
mix credo explain <issue>

# List all checks
mix credo list
```

**In CI:** ✅ **Blocking** - Fails on warnings and errors

**What It Checks:**
- **Consistency:** Naming conventions, code patterns
- **Design:** Code structure, module organization
- **Readability:** Complexity, naming, documentation
- **Refactoring:** Duplicate code, long functions, complex conditions
- **Warnings:** Common mistakes, anti-patterns

**Example Checks:**
- Enforces 120 character line limit
- Detects TODO/FIXME comments
- Identifies nested functions (max depth: 2)
- Warns about expensive operations like `length/1`
- Suggests `Enum.empty?/1` over `length(list) == 0`

---

### 3. **Dialyzer** - Type Checking

**Purpose:** Static type analysis and discrepancy detection

**Usage:**
```bash
# Generate PLT (first time only)
mix dialyzer --plt

# Run type checking
mix dialyzer
```

**In CI:** ⚠️ **Non-blocking** - Reports issues but doesn't fail the build

**What It Checks:**
- Type inconsistencies
- Unreachable code
- Redundant code
- Type specifications (@spec) violations
- Pattern matching errors

**Why Non-blocking?**
Dialyzer can be overly strict, especially with:
- Dynamic Phoenix code
- Macro-heavy code
- Some library functions
- Fresh codebases without full type specs

**Best Practices:**
- Add `@spec` annotations gradually
- Focus on critical business logic first
- Use `@dialyzer` attribute to suppress false positives

---

### 4. **Sobelow** - Security Analysis 🔒

**Purpose:** Security-focused static analysis for Phoenix applications

**Configuration:** [.sobelow-conf](../.sobelow-conf)

**Usage:**
```bash
# Run with configuration
mix sobelow --config

# Verbose output
mix sobelow --verbose

# Check specific module
mix sobelow --router lib/whispr_messaging_web/router.ex
```

**In CI:** ⚠️ **Non-blocking** - Reports issues but doesn't fail initially

**Security Checks:**

#### SQL Injection
- Detects unsafe `Ecto.Query` usage
- Identifies string interpolation in queries
- Checks for raw SQL execution

#### Cross-Site Scripting (XSS)
- Unsafe HTML rendering
- Raw HTML in templates
- Unsafe JavaScript generation

#### Command Injection
- Unsafe system calls
- Shell command execution
- File system operations

#### Configuration Issues
- Insecure cookie settings
- Missing CSRF protection
- Weak password hashing
- Debug mode in production

#### Known Vulnerabilities
- Checks dependencies for known CVEs
- Suggests updates for vulnerable packages

**Security Levels:**
- `low`: Minor issues, potential improvements
- `medium`: Notable security concerns
- `high`: Serious vulnerabilities, should be fixed
- `critical`: Immediate action required

---

### 5. **ExCoveralls** - Code Coverage

**Purpose:** Track test coverage and generate reports

**Configuration:**
- [.coveralls.exs](../.coveralls.exs) - Coverage settings
- [mix.exs](../mix.exs) - Test coverage configuration

**Usage:**
```bash
# Generate HTML report
mix coveralls.html

# Generate JSON for CI
mix coveralls.json

# Show detailed coverage
mix coveralls.detail

# View in browser
open cover/excoveralls.html
```

**In CI:** ⚠️ **Non-blocking** - Reports coverage but doesn't enforce minimum

**Coverage Target:** 80%

**Excluded Paths:**
- Migrations: `priv/repo/migrations/`
- Test support: `test/support/`
- Build artifacts: `_build/`, `deps/`
- Configuration: `config/`
- Generated files: Phoenix templates

**Reports Generated:**
- `cover/excoveralls.json` - For CI integration
- `cover/excoveralls.html` - For local viewing
- Coverage stats per module
- Line-by-line coverage

---

### 6. **Codecov** - Coverage Tracking

**Purpose:** Visualize and track coverage over time

**Integration:** Automatic upload in CI workflow

**Features:**
- Coverage trends over time
- Pull request coverage diffs
- Coverage by file/folder
- Branch coverage analysis
- Public coverage badges

**Setup:**
```yaml
- name: Upload coverage to Codecov
  uses: codecov/codecov-action@v4
  with:
    files: ./cover/excoveralls.json
    flags: unittests
    name: codecov-whispr-messaging
```

---

## 📊 Tool Comparison

### vs SonarQube

| Feature | SonarQube | Our Stack |
|---------|-----------|-----------|
| **Elixir Support** | ❌ No | ✅ Native |
| **Setup Complexity** | 🔴 High (server required) | 🟢 Low (just dependencies) |
| **Speed** | 🟡 Slow | 🟢 Fast |
| **Accuracy for Elixir** | ❌ N/A | ✅ Excellent |
| **Community** | Large (but no Elixir) | Large (Elixir-focused) |
| **Cost** | Free/Enterprise | Free (Open Source) |
| **Security Analysis** | Limited without plugin | ✅ Sobelow |
| **Coverage Tracking** | Yes | ✅ ExCoveralls + Codecov |

### vs Other Language Tools

| Elixir | JavaScript | Python | Java |
|--------|------------|--------|------|
| mix format | Prettier | Black | google-java-format |
| Credo | ESLint | Pylint | Checkstyle |
| Dialyzer | TypeScript | mypy | Static analysis in compiler |
| Sobelow | npm audit | Bandit | SpotBugs |
| ExCoveralls | Istanbul | Coverage.py | JaCoCo |

---

## 🔄 CI/CD Integration

### Workflow Steps

1. **Setup**
   - Checkout code
   - Set up Elixir 1.15 + OTP 26
   - Cache dependencies
   - Install dependencies

2. **Compilation**
   - Compile dependencies
   - Compile project (with `--warnings-as-errors`)

3. **Code Quality** (runs in parallel)
   - ✅ **Blocking:** `mix format --check-formatted`
   - ✅ **Blocking:** `mix credo --strict`
   - ⚠️ **Non-blocking:** `mix dialyzer`
   - ⚠️ **Non-blocking:** `mix sobelow --config`

4. **Testing**
   - Set up test database
   - Run migrations
   - Execute tests with coverage

5. **Reporting**
   - Upload coverage to Codecov

### Exit Codes

- **0:** All checks passed
- **Non-zero:** At least one blocking check failed

**Blocking checks:**
- Code formatting
- Credo strict analysis
- Test failures
- Compilation errors

**Non-blocking checks:**
- Dialyzer warnings
- Sobelow security warnings
- Coverage thresholds

---

## 🚀 Local Development

### Pre-commit Checks

Run before committing:

```bash
# Quick check
mix format && mix credo

# Full quality check
mix format && \
mix credo --strict && \
mix dialyzer && \
mix sobelow --config && \
mix test
```

### Setting Up Tools

```bash
# Install dependencies
mix deps.get

# Generate Dialyzer PLT (first time, takes ~5 minutes)
mix dialyzer --plt

# Run all quality checks
mix format --check-formatted
mix credo --strict
mix dialyzer
mix sobelow --config
```

### IDE Integration

#### VS Code
- **ElixirLS:** Built-in formatting, Dialyzer, Credo
- **Elixir Linter (Credo):** Real-time Credo feedback

#### JetBrains IntelliJ/RubyMine
- **Elixir plugin:** Formatting, Credo, Dialyzer support

#### Vim/Neovim
- **vim-mix-format:** Auto-formatting on save
- **ale:** Async linting with Credo

---

## 📈 Quality Metrics

### What We Track

1. **Code Style Compliance** (Credo)
   - Current: ~90% compliance
   - Target: 95%+

2. **Type Safety** (Dialyzer)
   - Current: Baseline being established
   - Target: Zero critical issues

3. **Security Posture** (Sobelow)
   - Current: Active monitoring
   - Target: Zero high/critical issues

4. **Test Coverage** (ExCoveralls)
   - Current: Being tracked
   - Target: 80%+ coverage

### Quality Gates

Before merging to `main`:
- ✅ All tests must pass
- ✅ Code must be formatted
- ✅ Credo must pass strict mode
- ✅ No blocking compilation warnings
- ⚠️ Dialyzer warnings reviewed
- ⚠️ Sobelow issues reviewed

---

## 🔧 Configuration Files

| File | Purpose | Location |
|------|---------|----------|
| `.formatter.exs` | Code formatting rules | Root |
| `.credo.exs` | Static analysis configuration | Root |
| `.sobelow-conf` | Security analysis settings | Root |
| `.coveralls.exs` | Coverage configuration | Root |
| `.dialyzer_ignore.exs` | Dialyzer suppressions | Root (optional) |

---

## 📚 Further Reading

### Official Documentation
- [Credo Documentation](https://hexdocs.pm/credo/)
- [Dialyxir Documentation](https://hexdocs.pm/dialyxir/)
- [Sobelow Documentation](https://hexdocs.pm/sobelow/)
- [ExCoveralls Documentation](https://hexdocs.pm/excoveralls/)
- [Mix Format Guide](https://hexdocs.pm/mix/Mix.Tasks.Format.html)

### Community Resources
- [Elixir Style Guide](https://github.com/christopheradams/elixir_style_guide)
- [Phoenix Security Best Practices](https://hexdocs.pm/phoenix/security.html)
- [Dialyzer: A DIscrepancy AnaLYZer for ERlang programs](https://www.erlang.org/doc/apps/dialyzer/dialyzer_chapter.html)

### Related Tools
- [ExDoc](https://hexdocs.pm/ex_doc/) - Documentation generation
- [Doctor](https://hexdocs.pm/doctor/) - Documentation coverage
- [Boundary](https://hexdocs.pm/boundary/) - Architecture boundaries
- [Machete](https://hexdocs.pm/machete/) - Testing utilities

---

## 🎯 Summary

Our Elixir-native code quality stack provides:

✅ **Comprehensive Analysis** - From formatting to security
✅ **Fast Feedback** - Run locally in seconds
✅ **Accurate Results** - Purpose-built for Elixir/Phoenix
✅ **Zero Infrastructure** - No servers to maintain
✅ **Open Source** - Free forever
✅ **Community-Driven** - Active development and support

**Result:** Superior code quality analysis compared to generic tools like SonarQube.
