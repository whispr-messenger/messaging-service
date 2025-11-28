defmodule WhisprMessaging.MixProject do
  use Mix.Project

  def project do
    [
      app: :whispr_messaging,
      version: "1.0.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ]
    ]
  end

  def application do
    [
      mod: {WhisprMessaging.Application, []},
      extra_applications: [:logger, :runtime_tools, :os_mon]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Phoenix and web dependencies
      {:phoenix, "~> 1.7.0"},
      {:phoenix_ecto, "~> 4.4"},
      {:phoenix_html, "~> 3.3"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 0.19.0"},
      {:phoenix_live_dashboard, "~> 0.8.0"},
      {:phoenix_pubsub, "~> 2.1"},

      # Database
      {:ecto_sql, "~> 3.10"},
      {:postgrex, ">= 0.0.0"},

      # JSON handling
      {:jason, "~> 1.2"},
      {:poison, "~> 5.0"},

      # HTTP client
      {:httpoison, "~> 2.0"},
      {:finch, "~> 0.16"},

      # Email
      {:swoosh, "~> 1.11"},

      # WebSocket and real-time
      {:websockex, "~> 0.4.3"},

      # Redis and caching
      {:redix, "~> 1.2"},
      # {:redix_pubsub, "~> 1.0"}, # Commented out to avoid dependency issues

      # gRPC
      {:grpc, "~> 0.7.0"},
      {:protobuf, "~> 0.11.0"},
      {:google_protos, "~> 0.3.0"},

      # UUID generation
      {:uuid, "~> 1.1"},

      # Date/time handling
      {:timex, "~> 3.7"},

      # Validation
      # {:ex_json_schema, "~> 0.10.0"}, # Temporary removal due to compilation issues

      # Configuration
      {:confex, "~> 3.5"},

      # Monitoring and observability
      {:telemetry, "~> 1.2"},
      {:telemetry_metrics, "~> 0.6"},
      {:telemetry_poller, "~> 1.0"},

      # Logging
      {:logger_json, "~> 5.1"},

      # Testing
      {:excoveralls, "~> 0.16", only: :test},
      {:mock, "~> 0.3.0", only: :test},
      {:ex_machina, "~> 2.7.0", only: :test},

      # Development tools
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.3", only: [:dev], runtime: false},
      {:ex_doc, "~> 0.30", only: :dev, runtime: false},

      # Production monitoring
      {:recon, "~> 2.5"},
      {:observer_cli, "~> 1.7"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.deploy": ["esbuild default --minify", "phx.digest"]
    ]
  end
end
