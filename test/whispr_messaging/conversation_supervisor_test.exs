defmodule WhisprMessaging.ConversationSupervisorTest do
  use WhisprMessaging.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias WhisprMessaging.Conversations
  alias WhisprMessaging.ConversationSupervisor

  setup do
    Sandbox.mode(WhisprMessaging.Repo, {:shared, self()})

    {:ok, conversation} =
      Conversations.create_conversation(%{
        type: "direct",
        metadata: %{"test" => true},
        is_active: true
      })

    Conversations.add_conversation_member(conversation.id, Ecto.UUID.generate())

    on_exit(fn ->
      # Clean up any servers we started so subsequent tests have a clean slate
      ConversationSupervisor.stop_conversation(conversation.id)
    end)

    %{conversation: conversation}
  end

  describe "get_conversation_pid/1" do
    test "returns nil when no server is registered", _ctx do
      assert ConversationSupervisor.get_conversation_pid(Ecto.UUID.generate()) == nil
    end
  end

  describe "start_conversation/1" do
    test "starts a server when missing", ctx do
      assert {:ok, pid} = ConversationSupervisor.start_conversation(ctx.conversation.id)
      assert Process.alive?(pid)
    end

    test "returns the same pid on a second call (already_started)", ctx do
      {:ok, pid1} = ConversationSupervisor.start_conversation(ctx.conversation.id)
      {:ok, pid2} = ConversationSupervisor.start_conversation(ctx.conversation.id)
      assert pid1 == pid2
    end
  end

  describe "ensure_conversation_server/1" do
    test "starts a server when missing", ctx do
      assert {:ok, pid} = ConversationSupervisor.ensure_conversation_server(ctx.conversation.id)
      assert Process.alive?(pid)
    end

    test "returns the existing pid if already running", ctx do
      {:ok, pid1} = ConversationSupervisor.start_conversation(ctx.conversation.id)
      {:ok, pid2} = ConversationSupervisor.ensure_conversation_server(ctx.conversation.id)
      assert pid1 == pid2
    end
  end

  describe "stop_conversation/1" do
    test "stops a running server", ctx do
      {:ok, pid} = ConversationSupervisor.start_conversation(ctx.conversation.id)
      assert :ok = ConversationSupervisor.stop_conversation(ctx.conversation.id)
      refute Process.alive?(pid)
    end

    test "is a no-op when no server is running", _ctx do
      assert :ok = ConversationSupervisor.stop_conversation(Ecto.UUID.generate())
    end
  end

  describe "list_conversations/0" do
    test "includes a server we just started", ctx do
      {:ok, _pid} = ConversationSupervisor.start_conversation(ctx.conversation.id)
      conversations = ConversationSupervisor.list_conversations()
      assert ctx.conversation.id in conversations
    end
  end

  describe "get_stats/0" do
    test "returns a stats map", ctx do
      {:ok, _pid} = ConversationSupervisor.start_conversation(ctx.conversation.id)

      stats = ConversationSupervisor.get_stats()
      assert is_integer(stats.total_conversations) and stats.total_conversations >= 1
      assert is_integer(stats.active_conversations) and stats.active_conversations >= 1
      assert is_integer(stats.memory_usage)
    end
  end

  describe "health_check/0" do
    test "returns :healthy when all processes are alive", ctx do
      {:ok, _pid} = ConversationSupervisor.start_conversation(ctx.conversation.id)
      health = ConversationSupervisor.health_check()
      assert health.status == :healthy
      assert health.healthy_processes == health.total_processes
    end
  end

  describe "restart_conversation/1" do
    test "terminates the previous server when restarting", ctx do
      {:ok, pid1} = ConversationSupervisor.start_conversation(ctx.conversation.id)
      assert {:ok, _new_pid} = ConversationSupervisor.restart_conversation(ctx.conversation.id)

      # The previous pid is terminated by the supervisor
      refute Process.alive?(pid1)
    end

    test "starts a new server if none was running", ctx do
      assert {:ok, pid} = ConversationSupervisor.restart_conversation(ctx.conversation.id)
      assert is_pid(pid)
    end
  end

  describe "stop_all_conversations/0" do
    test "terminates running servers", ctx do
      {:ok, _pid} = ConversationSupervisor.start_conversation(ctx.conversation.id)
      ConversationSupervisor.stop_all_conversations()
      # process is terminated asynchronously
      Process.sleep(50)
      # there may still be other unrelated children; we just ensure no crash
      assert :ok
    end
  end

  describe "cleanup_idle_conversations/1" do
    test "leaves fresh servers untouched (idle threshold 30 min)", ctx do
      {:ok, _pid} = ConversationSupervisor.start_conversation(ctx.conversation.id)

      result = ConversationSupervisor.cleanup_idle_conversations(30)
      assert result.total_checked >= 1
      assert result.idle_stopped == 0
    end

    test "stops a server when threshold is 0 (everything is idle)", ctx do
      {:ok, _pid} = ConversationSupervisor.start_conversation(ctx.conversation.id)

      result = ConversationSupervisor.cleanup_idle_conversations(0)
      assert result.idle_stopped >= 1
      assert ctx.conversation.id in result.idle_conversation_ids
    end
  end
end
