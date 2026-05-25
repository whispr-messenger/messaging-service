defmodule WhisprMessagingWeb.AdminSocketControllerTest do
  use WhisprMessagingWeb.ConnCase, async: true

  @endpoint WhisprMessagingWeb.Endpoint
  @internal_token "test-internal-token"

  defp with_internal_token(conn, token \\ @internal_token) do
    put_req_header(conn, "x-internal-token", token)
  end

  describe "DELETE /messaging/api/v1/admin/users/:user_id/socket" do
    test "retourne 404 sans le header x-internal-token" do
      user_id = Ecto.UUID.generate()

      conn =
        build_conn()
        |> json_conn()
        |> delete(~p"/messaging/api/v1/admin/users/#{user_id}/socket")

      assert conn.status == 404
    end

    test "retourne 404 avec un token invalide" do
      user_id = Ecto.UUID.generate()

      conn =
        build_conn()
        |> json_conn()
        |> with_internal_token("mauvais-token")
        |> delete(~p"/messaging/api/v1/admin/users/#{user_id}/socket")

      assert conn.status == 404
    end

    test "retourne 200 avec le bon token interne" do
      user_id = Ecto.UUID.generate()

      resp =
        build_conn()
        |> json_conn()
        |> with_internal_token()
        |> delete(~p"/messaging/api/v1/admin/users/#{user_id}/socket")
        |> json_response(200)

      assert resp["ok"] == true
      assert resp["user_id"] == user_id
    end

    test "broadcast Phoenix emet l'event disconnect sur le topic socket du user" do
      user_id = Ecto.UUID.generate()
      topic = "user_socket:#{user_id}"

      # Souscrire au topic PubSub avant le broadcast
      @endpoint.subscribe(topic)

      build_conn()
      |> json_conn()
      |> with_internal_token()
      |> delete(~p"/messaging/api/v1/admin/users/#{user_id}/socket")
      |> json_response(200)

      # Le broadcast "disconnect" doit etre emis sur le bon topic
      assert_receive %Phoenix.Socket.Broadcast{
        topic: ^topic,
        event: "disconnect"
      }
    end

    test "ne broadcast pas sur le topic d'un autre user" do
      user_a = Ecto.UUID.generate()
      user_b = Ecto.UUID.generate()
      topic_b = "user_socket:#{user_b}"

      @endpoint.subscribe(topic_b)

      build_conn()
      |> json_conn()
      |> with_internal_token()
      |> delete(~p"/messaging/api/v1/admin/users/#{user_a}/socket")
      |> json_response(200)

      refute_receive %Phoenix.Socket.Broadcast{topic: ^topic_b, event: "disconnect"}, 200
    end
  end
end

# Test separe pour verifier que le broadcast "disconnect" sur le topic "user_socket:<id>"
# est bien recu par le process de transport de la socket (en dehors de ConnCase pour eviter
# l'ambiguite connect/2 entre Phoenix.ConnTest et Phoenix.ChannelTest).
#
# Phoenix.ChannelTest.connect/2 affecte transport_pid: self(). En production, le cowboy
# transport process recoit ce Broadcast et appelle {:stop, {:shutdown, :disconnected}}.
# En test, on verifie que le message est bien routé vers ce pid.
defmodule WhisprMessagingWeb.AdminSocketDisconnectTest do
  use ExUnit.Case, async: true

  import Phoenix.ChannelTest

  alias WhisprMessagingWeb.UserSocket

  @endpoint WhisprMessagingWeb.Endpoint

  test "broadcast disconnect livre le message au transport de la socket cible" do
    user_id = Ecto.UUID.generate()

    # connect/2 via Phoenix.ChannelTest — transport_pid: self()
    {:ok, _socket} = connect(UserSocket, %{"token" => "test_token_#{user_id}"})

    @endpoint.broadcast("user_socket:#{user_id}", "disconnect", %{})

    # Le process de transport (self() en test) doit recevoir le broadcast
    assert_receive %Phoenix.Socket.Broadcast{
      topic: "user_socket:" <> ^user_id,
      event: "disconnect"
    }
  end

  test "broadcast disconnect user_a ne livre pas de message au transport de user_b" do
    user_a = Ecto.UUID.generate()
    user_b = Ecto.UUID.generate()

    {:ok, _socket_b} = connect(UserSocket, %{"token" => "test_token_#{user_b}"})

    @endpoint.broadcast("user_socket:#{user_a}", "disconnect", %{})

    # user_b ne doit pas recevoir le disconnect de user_a
    refute_receive %Phoenix.Socket.Broadcast{
                     topic: "user_socket:" <> ^user_b,
                     event: "disconnect"
                   },
                   300
  end
end
