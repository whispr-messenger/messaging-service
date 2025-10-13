# Coveralls configuration for code coverage reporting
# Documentation: https://github.com/parroty/excoveralls

import Config

# Coverage settings
config :excoveralls,
  # Template for output
  template: "coverage/coverage.html.eex",

  # Path patterns to exclude from coverage
  coverage_options: %{
    treat_no_relevant_lines_as_covered: true,
    minimum_coverage: 80
  },

  # Paths to exclude from coverage
  skip_files: [
    # Migrations
    ~r/priv\/repo\/migrations/,

    # Test support files
    ~r/test\/support/,

    # Generated files
    ~r/_build/,
    ~r/deps/,

    # Configuration
    ~r/config/,

    # Phoenix generated files
    ~r/lib\/whispr_messaging_web\/channels\/user_socket\.ex/,
    ~r/lib\/whispr_messaging_web\/views\/error_helpers\.ex/,
    ~r/lib\/whispr_messaging_web\/gettext\.ex/,

    # Application entry point (hard to test)
    ~r/lib\/whispr_messaging\/application\.ex/,

    # Release tasks
    ~r/lib\/whispr_messaging\/release\.ex/
  ]
