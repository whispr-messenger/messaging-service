defmodule WhisprMessagingWeb.PageHTML do
  @moduledoc """
  HTML rendering for PageController.
  """

  use WhisprMessagingWeb, :html

  def home(assigns) do
    ~H"""
    <div style="font-family: system-ui; max-width: 800px; margin: 2rem auto; padding: 2rem;">
      <h1 style="color: #333;">Whispr Messaging Service</h1>
      <p style="color: #666; font-size: 1.1rem;">Real-time messaging service with E2E encryption</p>

      <div style="margin-top: 2rem; padding: 1.5rem; background: #f5f5f5; border-radius: 8px;">
        <h2 style="margin-top: 0;">API Endpoints</h2>
        <ul style="line-height: 1.8;">
          <li><strong>Health:</strong> GET /api/v1/health</li>
          <li><strong>Conversations:</strong> GET/POST /api/v1/conversations</li>
          <li><strong>Messages:</strong> GET/POST /api/v1/conversations/:id/messages</li>
          <li><strong>WebSocket:</strong> ws://localhost:4000/socket</li>
        </ul>
      </div>

      <div style="margin-top: 2rem; padding: 1.5rem; background: #e3f2fd; border-radius: 8px;">
        <h2 style="margin-top: 0;">Service Status</h2>
        <p>✅ Service Running</p>
        <p>📡 WebSocket Channels Active</p>
        <p>🔒 E2E Encryption Enabled</p>
      </div>
    </div>
    """
  end
end
