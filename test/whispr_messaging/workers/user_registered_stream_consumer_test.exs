defmodule WhisprMessaging.Workers.UserRegisteredStreamConsumerTest do
  use WhisprMessaging.DataCase, async: false

  alias WhisprMessaging.Accounts.User
  alias WhisprMessaging.Repo
  alias WhisprMessaging.Workers.UserRegisteredStreamConsumer

  @stream "stream:user.registered"

  # Stub XACK injectable via config pour eviter Redix reel en tests unitaires
  setup do
    test_pid = self()

    Application.put_env(:whispr_messaging, :user_registered_xack_fn, fn _redis,
                                                                        _stream,
                                                                        _group,
                                                                        id ->
      send(test_pid, {:xack, id})
      {:ok, 1}
    end)

    on_exit(fn -> Application.delete_env(:whispr_messaging, :user_registered_xack_fn) end)
    :ok
  end

  describe "extract_messages/1" do
    test "renvoie une liste vide pour nil" do
      assert [] == UserRegisteredStreamConsumer.extract_messages(nil)
    end

    test "renvoie une liste vide pour une reponse vide" do
      assert [] == UserRegisteredStreamConsumer.extract_messages([])
    end

    test "extrait correctement les messages du format XREADGROUP" do
      raw = [[@stream, [["1-0", ["userId", "uuid-1", "phoneNumber", "+33600000001"]]]]]

      assert [["1-0", "userId", "uuid-1", "phoneNumber", "+33600000001"]] ==
               UserRegisteredStreamConsumer.extract_messages(raw)
    end
  end

  describe "parse_fields/1" do
    test "convertit une liste plate en map" do
      assert %{"userId" => "uuid-1", "phoneNumber" => "+33600000001"} ==
               UserRegisteredStreamConsumer.parse_fields([
                 "userId",
                 "uuid-1",
                 "phoneNumber",
                 "+33600000001"
               ])
    end

    test "ignore un element impair en fin de liste" do
      assert %{"userId" => "uuid-1"} ==
               UserRegisteredStreamConsumer.parse_fields(["userId", "uuid-1", "orphan"])
    end
  end

  describe "upsert_user/1" do
    test "insere un nouvel utilisateur dans la projection locale" do
      user_id = Ecto.UUID.generate()

      assert {:ok, %User{id: ^user_id}} =
               UserRegisteredStreamConsumer.upsert_user(%{
                 "userId" => user_id,
                 "phoneNumber" => "+33600000002"
               })

      assert Repo.get(User, user_id) != nil
    end

    test "idempotent : un second appel avec le meme user_id ne renvoie pas d'erreur" do
      user_id = Ecto.UUID.generate()
      attrs = %{"userId" => user_id, "phoneNumber" => "+33600000003"}

      assert {:ok, _} = UserRegisteredStreamConsumer.upsert_user(attrs)
      assert {:ok, _} = UserRegisteredStreamConsumer.upsert_user(attrs)

      assert 1 == Repo.aggregate(User, :count, :id)
    end

    test "retourne une erreur si userId est manquant" do
      assert {:error, _} =
               UserRegisteredStreamConsumer.upsert_user(%{"phoneNumber" => "+33600000004"})
    end

    test "retourne une erreur si phoneNumber est manquant" do
      assert {:error, _} =
               UserRegisteredStreamConsumer.upsert_user(%{"userId" => Ecto.UUID.generate()})
    end

    test "retourne une erreur si les champs sont vides" do
      assert {:error, _} =
               UserRegisteredStreamConsumer.upsert_user(%{"userId" => "", "phoneNumber" => ""})
    end
  end

  describe "process_messages/2" do
    test "insere le user en DB, XACK le message et retourne le nombre de messages traites" do
      user_id = Ecto.UUID.generate()
      messages = [["1-0", "userId", user_id, "phoneNumber", "+33600000010"]]

      acked = UserRegisteredStreamConsumer.process_messages(messages, :stub_redis)

      assert acked == 1
      assert Repo.get(User, user_id) != nil
      assert_receive {:xack, "1-0"}
    end

    test "retourne 0 et ne XACK pas un message avec champs invalides" do
      messages = [["2-0", "champInconnu", "valeur"]]

      assert 0 == UserRegisteredStreamConsumer.process_messages(messages, :stub_redis)
      refute_receive {:xack, _}, 50
    end
  end

  describe "ensure_group/1 (integration avec Redix reel en test)" do
    @tag :skip
    test "cree le groupe si absent et est idempotent" do
      # Ce test necessite un Redis reel. Desactive par defaut (CI sans Redis).
      # Activer avec MIX_TEST_INCLUDE=integration mix test --include integration
      redis_opts = WhisprMessaging.RedisConfig.build()
      {:ok, redis} = Redix.start_link(redis_opts)

      assert :ok = UserRegisteredStreamConsumer.ensure_group(redis)
      # Deuxieme appel : BUSYGROUP doit etre gere silencieusement
      assert :ok = UserRegisteredStreamConsumer.ensure_group(redis)

      Redix.stop(redis)
    end
  end
end
