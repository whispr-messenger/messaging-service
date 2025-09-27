defmodule WhisprMessaging.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  during tests are automatically rolled back.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias WhisprMessaging.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import WhisprMessaging.DataCase
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(WhisprMessaging.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  @doc """
  Creates a test conversation with default attributes.
  """
  def create_test_conversation(attrs \\ %{}) do
    default_attrs = %{
      type: "direct",
      metadata: %{"test" => true},
      is_active: true
    }

    attrs = Map.merge(default_attrs, attrs)

    case WhisprMessaging.Conversations.create_conversation(attrs) do
      {:ok, conversation} -> conversation
      {:error, changeset} -> raise "Failed to create test conversation: #{inspect(changeset)}"
    end
  end

  @doc """
  Creates a test user ID.
  """
  def create_test_user_id do
    Ecto.UUID.generate()
  end

  @doc """
  Creates a test message with default attributes.
  """
  def create_test_message(conversation_id, sender_id, attrs \\ %{}) do
    default_attrs = %{
      conversation_id: conversation_id,
      sender_id: sender_id,
      message_type: "text",
      content: "test message content",
      client_random: System.unique_integer([:positive]),
      metadata: %{"test" => true}
    }

    attrs = Map.merge(default_attrs, attrs)

    case WhisprMessaging.Messages.create_message(attrs) do
      {:ok, message} -> message
      {:error, changeset} -> raise "Failed to create test message: #{inspect(changeset)}"
    end
  end

  @doc """
  Waits for a condition to be true with timeout.
  """
  def wait_until(fun, timeout \\ 1000) do
    wait_until(fun, timeout, 50)
  end

  defp wait_until(fun, timeout, interval) when timeout > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(interval)
      wait_until(fun, timeout - interval, interval)
    end
  end

  defp wait_until(_fun, _timeout, _interval) do
    {:error, :timeout}
  end
end