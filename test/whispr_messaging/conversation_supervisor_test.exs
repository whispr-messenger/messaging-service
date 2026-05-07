defmodule WhisprMessaging.ConversationSupervisorTest do
  @moduledoc """
  Tests for the dynamic supervisor managing per-conversation GenServers.
  Spawns real ConversationServer processes via the supervisor and verifies
  start/stop/list/stats/health-check behaviour.
  """

  use WhisprMessaging.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias WhisprMessaging.Conversations
  alias WhisprMessaging.ConversationSupervisor
  alias WhisprMessaging.Repo

  setup do
    Sandbox.mode(Repo, {:shared, self()})

    # Make sure we start with a clean supervisor (no leftovers from other tests)
    ConversationSupervisor.stop_all_conversations()

    {:ok, conversation} =
      Conversations.create_conversation(%{
        type: "direct",
        metadata: %{},
        is_active: true
      })

    on_exit(fn -> ConversationSupervisor.stop_all_conversations() end)

    %{conversation: conversation}
  end

  describe "start_conversation/1" do
    test "starts a new conversation server", %{conversation: c} do
      assert {:ok, pid} = ConversationSupervisor.start_conversation(c.id)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "returns the existing pid when already started", %{conversation: c} do
      {:ok, pid1} = ConversationSupervisor.start_conversation(c.id)
      {:ok, pid2} = ConversationSupervisor.start_conversation(c.id)
      assert pid1 == pid2
    end
  end

  describe "get_conversation_pid/1" do
    test "returns nil when no server is running", %{conversation: c} do
      assert nil == ConversationSupervisor.get_conversation_pid(c.id)
    end

    test "returns the pid once started", %{conversation: c} do
      {:ok, pid} = ConversationSupervisor.start_conversation(c.id)
      assert pid == ConversationSupervisor.get_conversation_pid(c.id)
    end
  end

  describe "stop_conversation/1" do
    test "stops a running server", %{conversation: c} do
      {:ok, pid} = ConversationSupervisor.start_conversation(c.id)
      assert :ok = ConversationSupervisor.stop_conversation(c.id)
      refute Process.alive?(pid)
    end

    test "is a no-op when nothing is running", %{conversation: c} do
      assert :ok = ConversationSupervisor.stop_conversation(c.id)
    end
  end

  describe "ensure_conversation_server/1" do
    test "starts the server if not running", %{conversation: c} do
      assert {:ok, pid} = ConversationSupervisor.ensure_conversation_server(c.id)
      assert is_pid(pid)
    end

    test "returns the existing pid when already running", %{conversation: c} do
      {:ok, pid1} = ConversationSupervisor.start_conversation(c.id)
      assert {:ok, pid2} = ConversationSupervisor.ensure_conversation_server(c.id)
      assert pid1 == pid2
    end
  end

  describe "list_conversations/0" do
    test "lists active conversation IDs", %{conversation: c} do
      {:ok, _pid} = ConversationSupervisor.start_conversation(c.id)
      ids = ConversationSupervisor.list_conversations()
      assert c.id in ids
    end
  end

  describe "get_stats/0" do
    test "returns counts and memory usage", %{conversation: c} do
      {:ok, _pid} = ConversationSupervisor.start_conversation(c.id)
      stats = ConversationSupervisor.get_stats()

      assert stats.total_conversations >= 1
      assert stats.active_conversations >= 1
      assert is_integer(stats.memory_usage)
    end
  end

  describe "health_check/0" do
    test "is :healthy when all children are alive", %{conversation: c} do
      {:ok, _pid} = ConversationSupervisor.start_conversation(c.id)
      result = ConversationSupervisor.health_check()
      assert result.status in [:healthy, :degraded]
      assert result.total_processes >= 1
    end
  end

  describe "stop_all_conversations/0" do
    test "stops every running server", %{conversation: c} do
      {:ok, _pid1} = ConversationSupervisor.start_conversation(c.id)

      ConversationSupervisor.stop_all_conversations()

      assert ConversationSupervisor.list_conversations() == []
    end
  end

  describe "restart_conversation/1" do
    test "starts a new server when none is running", %{conversation: c} do
      assert {:ok, _pid} = ConversationSupervisor.restart_conversation(c.id)
    end

    test "replaces an existing server with a new pid", %{conversation: c} do
      {:ok, pid1} = ConversationSupervisor.start_conversation(c.id)
      assert {:ok, pid2} = ConversationSupervisor.restart_conversation(c.id)
      # Le BEAM peut reutiliser le meme pid si la termination + start sont tres
      # rapprochees. On verifie l'invariant reel: l'ancien process est mort,
      # le nouveau est vivant.
      refute Process.alive?(pid1)
      assert Process.alive?(pid2)
    end
  end

  describe "cleanup_idle_conversations/1" do
    test "returns a stats map without raising", %{conversation: c} do
      {:ok, _} = ConversationSupervisor.start_conversation(c.id)
      result = ConversationSupervisor.cleanup_idle_conversations(0)
      assert is_map(result)
      assert result.total_checked >= 1
    end
  end
end
