defmodule WhisprMessaging.Workers.DeviceRevokedStreamConsumerTest do
  use ExUnit.Case, async: false

  alias WhisprMessaging.Workers.DeviceRevokedStreamConsumer

  @stream "stream:device.revoked"

  # Stubs injectables via config : on capture les XACK et les broadcasts dans
  # la mailbox du test plutot que de dependre d'un Redix reel / de l'Endpoint.
  setup do
    test_pid = self()

    Application.put_env(:whispr_messaging, :device_revoked_xack_fn, fn _redis,
                                                                       _stream,
                                                                       _group,
                                                                       id ->
      send(test_pid, {:xack, id})
      {:ok, 1}
    end)

    Application.put_env(:whispr_messaging, :device_revoked_broadcast_fn, fn topic, event, payload ->
      send(test_pid, {:broadcast, topic, event, payload})
      :ok
    end)

    on_exit(fn ->
      Application.delete_env(:whispr_messaging, :device_revoked_xack_fn)
      Application.delete_env(:whispr_messaging, :device_revoked_broadcast_fn)
    end)

    :ok
  end

  describe "extract_messages/1" do
    test "renvoie une liste vide pour nil" do
      assert [] == DeviceRevokedStreamConsumer.extract_messages(nil)
    end

    test "extrait correctement les messages du format XREADGROUP" do
      raw = [[@stream, [["1-0", ["userId", "u-1", "deviceId", "d-1"]]]]]

      assert [["1-0", "userId", "u-1", "deviceId", "d-1"]] ==
               DeviceRevokedStreamConsumer.extract_messages(raw)
    end
  end

  describe "parse_fields/1" do
    test "convertit une liste plate en map" do
      assert %{"userId" => "u-1", "deviceId" => "d-1"} ==
               DeviceRevokedStreamConsumer.parse_fields(["userId", "u-1", "deviceId", "d-1"])
    end
  end

  describe "revoke_device/2" do
    test "broadcast device_revoked sur le topic du user avec le device_id cible" do
      broadcast = fn topic, event, payload -> send(self(), {:bc, topic, event, payload}) end

      assert :ok =
               DeviceRevokedStreamConsumer.revoke_device(
                 %{"userId" => "u-1", "deviceId" => "d-1"},
                 broadcast
               )

      assert_receive {:bc, "user:u-1", "device_revoked", %{device_id: "d-1"}}
    end

    test "retourne une erreur si userId est manquant" do
      broadcast = fn _, _, _ -> :ok end

      assert {:error, _} =
               DeviceRevokedStreamConsumer.revoke_device(%{"deviceId" => "d-1"}, broadcast)
    end

    test "retourne une erreur si deviceId est manquant" do
      broadcast = fn _, _, _ -> :ok end

      assert {:error, _} =
               DeviceRevokedStreamConsumer.revoke_device(%{"userId" => "u-1"}, broadcast)
    end

    test "retourne une erreur si les champs sont vides" do
      broadcast = fn _, _, _ -> :ok end

      assert {:error, _} =
               DeviceRevokedStreamConsumer.revoke_device(
                 %{"userId" => "", "deviceId" => ""},
                 broadcast
               )
    end
  end

  describe "process_messages/2" do
    test "broadcast, XACK le message et retourne le nombre de messages traites" do
      messages = [["1-0", "userId", "u-1", "deviceId", "d-1"]]

      acked = DeviceRevokedStreamConsumer.process_messages(messages, :stub_redis)

      assert acked == 1
      assert_receive {:broadcast, "user:u-1", "device_revoked", %{device_id: "d-1"}}
      assert_receive {:xack, "1-0"}
    end

    test "retourne 0 et ne XACK pas un message avec champs invalides" do
      messages = [["2-0", "champInconnu", "valeur"]]

      assert 0 == DeviceRevokedStreamConsumer.process_messages(messages, :stub_redis)
      refute_receive {:xack, _}, 50
    end
  end
end
