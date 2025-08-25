# Configuration Redis pour le messaging-service

import Config

# Configuration Redis par environnement
case Mix.env() do
  :dev ->
    config :whispr_messaging, :redis,
      # Pool principal pour cache général
      main_pool: [
        host: System.get_env("REDIS_HOST") || "localhost",
        port: String.to_integer(System.get_env("REDIS_PORT") || "6379"),
        database: String.to_integer(System.get_env("REDIS_DB") || "0")
      ],
      # Pool dédié pour les sessions et présence
      session_pool: [
        host: System.get_env("REDIS_HOST") || "localhost", 
        port: String.to_integer(System.get_env("REDIS_PORT") || "6379"),
        database: String.to_integer(System.get_env("REDIS_SESSION_DB") || "1")
      ],
      # Pool pour les files d'attente de messages
      queue_pool: [
        host: System.get_env("REDIS_HOST") || "localhost",
        port: String.to_integer(System.get_env("REDIS_PORT") || "6379"), 
        database: String.to_integer(System.get_env("REDIS_QUEUE_DB") || "2")
      ]

  :test ->
    config :whispr_messaging, :redis,
      main_pool: [
        host: "localhost",
        port: 6379,
        database: 15, # DB dédiée aux tests
        pool_size: 3
      ],
      session_pool: [
        host: "localhost", 
        port: 6379,
        database: 14,
        pool_size: 2
      ],
      queue_pool: [
        host: "localhost",
        port: 6379,
        database: 13, 
        pool_size: 2
      ]

  :prod ->
    config :whispr_messaging, :redis,
      main_pool: [
        host: System.fetch_env!("REDIS_HOST"),
        port: String.to_integer(System.fetch_env!("REDIS_PORT")),
        database: String.to_integer(System.get_env("REDIS_DB") || "0"),
        password: System.fetch_env!("REDIS_PASSWORD"),
        pool_size: 20,
        socket_opts: [:inet6],
        # Configuration production
        sync_connect: false,
        backoff_initial: 500,
        backoff_max: 30_000
      ],
      session_pool: [
        host: System.fetch_env!("REDIS_HOST"),
        port: String.to_integer(System.fetch_env!("REDIS_PORT")),
        database: String.to_integer(System.get_env("REDIS_SESSION_DB") || "1"),
        password: System.fetch_env!("REDIS_PASSWORD"),
        pool_size: 10
      ],
      queue_pool: [
        host: System.fetch_env!("REDIS_HOST"),
        port: String.to_integer(System.fetch_env!("REDIS_PORT")),
        database: String.to_integer(System.get_env("REDIS_QUEUE_DB") || "2"),
        password: System.fetch_env!("REDIS_PASSWORD"),
        pool_size: 15
      ]
end

# Configuration de TTL par type de cache
config :whispr_messaging, :redis_ttl,
  # Cache utilisateur et présence
  user_presence: 300,        # 5 minutes
  user_preferences: 3600,    # 1 heure
  user_session: 1800,        # 30 minutes
  
  # Cache de conversation
  typing_indicator: 10,      # 10 secondes
  conversation_presence: 300, # 5 minutes
  message_delivery: 604800,  # 7 jours
  
  # Cache de recherche et performance
  search_results: 300,       # 5 minutes
  search_term_frequency: 3600, # 1 heure
  performance_stats: 1800,   # 30 minutes
  
  # Synchronisation multi-appareils
  sync_state: 600,          # 10 minutes
  sync_pending: 86400,      # 24 heures
  sync_lock: 30,            # 30 secondes
  sync_conflicts: 3600      # 1 heure
