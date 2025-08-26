# Whispr Messenger - Messaging Service

A real-time messaging service built with Phoenix Framework, implementing secure messaging, group conversations, and WebSocket communications.

## 🚀 Features

- **Real-time messaging** with WebSocket support
- **Group conversations** with role-based permissions
- **Message delivery tracking** and read receipts
- **Multi-device synchronization**
- **Anti-harassment protection** and content moderation
- **Redis caching** for performance optimization
- **gRPC communication** for microservices architecture
- **Security** with rate limiting and JWT authentication

## 🏗️ Architecture

This service follows a modular architecture based on Phoenix Framework:

```
messaging-service/
├── lib/
│   ├── whispr_messaging/           # Core business logic
│   │   ├── messages/              # Message handling
│   │   ├── conversations/         # Conversation management
│   │   ├── cache/                 # Redis caching layer
│   │   ├── security/              # Security & rate limiting
│   │   └── workers/               # Background workers
│   ├── whispr_messaging_grpc/      # gRPC services
│   ├── whispr_messaging_web/       # Phoenix web layer
│   │   ├── channels/              # WebSocket channels
│   │   ├── controllers/           # HTTP controllers
│   │   └── router.ex              # Route definitions
│   └── whispr_messaging_workers/   # Worker supervisors
├── documentation/                  # Complete project documentation
├── priv/
│   ├── protos/                    # Protocol buffer definitions
│   └── repo/                      # Database migrations
└── config/                        # Configuration files
```

## 🛠️ Quick Start

### Prerequisites

- **Elixir** 1.15+ and **Erlang** 26+
- **PostgreSQL** 14+
- **Redis** 6+ (optional, fallback mode available)

### Installation

1. **Clone and setup:**
   ```bash
   cd messaging-service
   mix deps.get
   mix ecto.create
   mix ecto.migrate
   ```

2. **Start the server:**
   ```bash
   mix phx.server
   ```

3. **Access the application:**
   - API: `http://localhost:4000/api/v1`
   - Dashboard: `http://localhost:4000/dev/dashboard`
   - WebSocket: `ws://localhost:4000/socket`

## 📡 API Endpoints

### Messages
- `GET /api/v1/conversations/:id/messages` - List messages
- `POST /api/v1/conversations/:id/messages` - Send message
- `PUT /api/v1/messages/:id` - Edit message
- `DELETE /api/v1/messages/:id` - Delete message

### Conversations
- `POST /api/v1/conversations` - Create conversation
- `POST /api/v1/conversations/:id/members/:user_id` - Add member
- `DELETE /api/v1/conversations/:id/members/:user_id` - Remove member

### Groups
- `GET /api/v1/groups` - List user groups
- `POST /api/v1/groups` - Create group
- `POST /api/v1/groups/:id/members` - Add members
- `POST /api/v1/groups/:id/leave` - Leave group

### Status & Delivery
- `GET /api/v1/status/messages/:id` - Get message status
- `POST /api/v1/status/messages/:id/read` - Mark as read
- `POST /api/v1/status/messages/:id/delivered` - Mark as delivered

## 🔌 WebSocket Channels

### User Channel (`user:#{user_id}`)
- Real-time message notifications
- Presence updates
- Delivery status notifications

### Conversation Channel (`conversation:#{conversation_id}`)
- Live message broadcasting
- Typing indicators
- Member activity

## ⚙️ Configuration

### Environment Variables

```bash
# Database
DB_USERNAME=your_username
DB_PASSWORD=your_password

# Redis (optional)
REDIS_ENABLED=true
REDIS_HOST=localhost
REDIS_PORT=6379

# Application
PORT=4000
SECRET_KEY_BASE=your_secret_key
```

### Redis Configuration

The application supports fallback mode when Redis is not available:

```elixir
# config/dev.exs
config :whispr_messaging, :redis_enabled, System.get_env("REDIS_ENABLED") == "true"
```

## 🔒 Security Features

- **Rate limiting** per user and IP
- **JWT authentication** for API access
- **Content moderation** and anti-harassment
- **Message encryption** support
- **Security headers** and CORS protection

## 📊 Monitoring

- **Phoenix LiveDashboard** for real-time metrics
- **Telemetry** for performance monitoring
- **Health checks** for service status
- **Error tracking** and logging

## 🧪 Testing

```bash
# Run tests
mix test

# Run with coverage
mix test --cover

# Code quality checks
mix credo
mix dialyzer
```

## 📚 Documentation

Complete documentation is available in the `/documentation` folder:

- **Architecture**: System design and database schema
- **Functional Specs**: Feature specifications and workflows
- **Technical Specs**: Implementation guides and best practices

## 🚀 Deployment

### Production Setup

1. **Environment setup:**
   ```bash
   export MIX_ENV=prod
   export SECRET_KEY_BASE=$(mix phx.gen.secret)
   ```

2. **Database setup:**
   ```bash
   mix ecto.create
   mix ecto.migrate
   ```

3. **Build and start:**
   ```bash
   mix deps.get --only prod
   mix compile
   mix phx.server
   ```

### Docker Support

```dockerfile
# Dockerfile included for containerized deployment
docker build -t whispr-messaging .
docker run -p 4000:4000 whispr-messaging
```

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch
3. Follow the coding standards (mix format)
4. Add tests for new features
5. Submit a pull request

## 📝 License

This project is licensed under the MIT License - see the LICENSE file for details.

## 📞 Support

For support and questions:
- Create an issue on GitHub
- Check the documentation in `/documentation`
- Review the implementation guides

---

**Built with ❤️ using Phoenix Framework and Elixir**