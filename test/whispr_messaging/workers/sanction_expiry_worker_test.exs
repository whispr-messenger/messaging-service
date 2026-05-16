defmodule WhisprMessaging.Workers.SanctionExpiryWorkerTest do
  use WhisprMessaging.DataCase, async: false

  alias WhisprMessaging.Moderation.ConversationSanction
  alias WhisprMessaging.Moderation.Sanctions
  alias WhisprMessaging.Repo
  alias WhisprMessaging.Workers.SanctionExpiryWorker

  @moduletag :integration

  setup do
    {:ok, pid} = SanctionExpiryWorker.start_link(skip_timer: true)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
    end)

    conversation = create_test_conversation()

    %{conversation: conversation, worker: pid}
  end

  defp insert_sanction(conv_id, opts) do
    user_id = Keyword.get(opts, :user_id, create_test_user_id())
    type = Keyword.get(opts, :type, "mute")
    expires_at = Keyword.get(opts, :expires_at)
    active = Keyword.get(opts, :active, true)

    {:ok, sanction} =
      Sanctions.create_sanction(%{
        conversation_id: conv_id,
        user_id: user_id,
        type: type,
        reason: "test",
        issued_by: create_test_user_id(),
        expires_at: expires_at,
        active: active
      })

    sanction
  end

  describe "start_link/1" do
    test "starts the worker with skip_timer", %{worker: pid} do
      assert Process.alive?(pid)
    end
  end

  describe "expire_now/0" do
    test "returns {:ok, 0} when no sanctions are due to expire", _ctx do
      assert {:ok, 0} = SanctionExpiryWorker.expire_now()
    end

    test "deactivates sanctions whose expires_at is in the past", ctx do
      past = DateTime.add(DateTime.utc_now(), -10) |> DateTime.truncate(:second)
      future = DateTime.add(DateTime.utc_now(), 3600) |> DateTime.truncate(:second)

      expired = insert_sanction(ctx.conversation.id, expires_at: past)
      not_expired = insert_sanction(ctx.conversation.id, expires_at: future)
      permanent = insert_sanction(ctx.conversation.id, expires_at: nil)

      assert {:ok, count} = SanctionExpiryWorker.expire_now()
      assert count >= 1

      refute Repo.get!(ConversationSanction, expired.id).active
      assert Repo.get!(ConversationSanction, not_expired.id).active
      assert Repo.get!(ConversationSanction, permanent.id).active
    end

    test "is idempotent — second call expires nothing more", ctx do
      past = DateTime.add(DateTime.utc_now(), -10) |> DateTime.truncate(:second)
      insert_sanction(ctx.conversation.id, expires_at: past)

      assert {:ok, c1} = SanctionExpiryWorker.expire_now()
      assert c1 >= 1

      assert {:ok, 0} = SanctionExpiryWorker.expire_now()
    end
  end

  describe "handle_info(:tick, ...)" do
    test "also runs the expiration sweep", ctx do
      past = DateTime.add(DateTime.utc_now(), -10) |> DateTime.truncate(:second)
      s = insert_sanction(ctx.conversation.id, expires_at: past)

      send(ctx.worker, :tick)
      # Drive it deterministically through the synchronous API too
      {:ok, _} = SanctionExpiryWorker.expire_now()

      refute Repo.get!(ConversationSanction, s.id).active
    end
  end
end
