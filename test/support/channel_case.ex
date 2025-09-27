defmodule WhisprMessagingWeb.ChannelCase do
  @moduledoc """
  This module defines the test case to be used by
  channel tests.

  Such tests rely on `Phoenix.ChannelTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  during tests are automatically rolled back.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # Import conveniences for testing with channels
      import Phoenix.ChannelTest
      import WhisprMessagingWeb.ChannelCase

      # The default endpoint for testing
      @endpoint WhisprMessagingWeb.Endpoint
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(WhisprMessaging.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  @doc """
  Creates a socket with user authentication for testing.
  """
  def authenticated_socket(user_id) do
    # Simplified for testing - this would normally create a proper socket
    %{user_id: user_id}
  end

  @doc """
  Creates a test conversation and returns it with member user IDs.
  """
  def setup_test_conversation do
    user1_id = Ecto.UUID.generate()
    user2_id = Ecto.UUID.generate()

    {:ok, conversation} = WhisprMessaging.Conversations.create_conversation(%{
      type: "direct",
      metadata: %{"test" => true},
      is_active: true
    })

    {:ok, _member1} = WhisprMessaging.Conversations.add_conversation_member(conversation.id, user1_id)
    {:ok, _member2} = WhisprMessaging.Conversations.add_conversation_member(conversation.id, user2_id)

    {conversation, user1_id, user2_id}
  end

  @doc """
  Subscribes to a conversation channel and returns the socket.
  """
  def subscribe_to_conversation(socket, conversation_id) do
    # Simplified for testing - this would normally subscribe to a channel
    socket
  end

  @doc """
  Waits for a specific broadcast message.
  """
  def wait_for_broadcast(event, timeout \\ 1000) do
    receive do
      %Phoenix.Socket.Broadcast{event: ^event} = broadcast ->
        broadcast.payload
    after
      timeout ->
        flunk("Expected broadcast #{event} within #{timeout}ms")
    end
  end

  @doc """
  Asserts that a broadcast was sent with specific payload.
  """
  def assert_broadcast_with(event, expected_payload) do
    receive do
      %Phoenix.Socket.Broadcast{event: ^event, payload: payload} ->
        assert payload == expected_payload
        payload
    after
      100 ->
        flunk("Expected broadcast #{event} with payload #{inspect(expected_payload)}")
    end
  end
end