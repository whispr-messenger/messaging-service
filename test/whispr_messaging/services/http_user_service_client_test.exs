defmodule WhisprMessaging.Services.HttpUserServiceClientTest do
  use ExUnit.Case, async: false

  import Mock

  alias WhisprMessaging.Services.HttpUserServiceClient

  setup do
    previous_internal = Application.get_env(:whispr_messaging, :user_service_internal)

    Application.put_env(:whispr_messaging, :user_service_internal,
      url: "http://user-service.test/internal/v1",
      token: "secret-token",
      timeout_ms: 1_500
    )

    on_exit(fn ->
      if previous_internal do
        Application.put_env(:whispr_messaging, :user_service_internal, previous_internal)
      else
        Application.delete_env(:whispr_messaging, :user_service_internal)
      end
    end)

    :ok
  end

  defp ok_response(status, body) when is_binary(body) do
    {:ok, %Finch.Response{status: status, body: body, headers: []}}
  end

  describe "check_user_blocked/2" do
    test "returns {:ok, true} when isBlocked is true" do
      with_mock Finch,
        build: fn :get, url, headers ->
          assert url ==
                   "http://user-service.test/internal/v1/contacts/check?ownerId=u1&contactId=u2"

          assert {"x-internal-token", "secret-token"} in headers
          assert {"accept", "application/json"} in headers
          {:built, url, headers}
        end,
        request: fn {:built, _, _}, WhisprMessaging.Finch, _opts ->
          ok_response(200, ~s({"isContact":false,"isBlocked":true}))
        end do
        assert HttpUserServiceClient.check_user_blocked("u1", "u2") == {:ok, true}
      end
    end

    test "returns {:ok, false} when isBlocked is false" do
      with_mock Finch,
        build: fn :get, _url, _headers -> :req end,
        request: fn :req, WhisprMessaging.Finch, _opts ->
          ok_response(200, ~s({"isContact":true,"isBlocked":false}))
        end do
        assert HttpUserServiceClient.check_user_blocked("u1", "u2") == {:ok, false}
      end
    end

    test "returns {:error, :unauthorized} on 401" do
      with_mock Finch,
        build: fn :get, _url, _headers -> :req end,
        request: fn :req, WhisprMessaging.Finch, _opts -> ok_response(401, "") end do
        assert HttpUserServiceClient.check_user_blocked("u1", "u2") == {:error, :unauthorized}
      end
    end

    test "returns {:error, :transient} on 5xx (caller must fail-closed)" do
      with_mock Finch,
        build: fn :get, _url, _headers -> :req end,
        request: fn :req, WhisprMessaging.Finch, _opts -> ok_response(503, "") end do
        assert HttpUserServiceClient.check_user_blocked("u1", "u2") == {:error, :transient}
      end
    end

    test "returns {:error, :transient} on transport error" do
      with_mock Finch,
        build: fn :get, _url, _headers -> :req end,
        request: fn :req, WhisprMessaging.Finch, _opts ->
          {:error, %Mint.TransportError{reason: :timeout}}
        end do
        assert HttpUserServiceClient.check_user_blocked("u1", "u2") == {:error, :transient}
      end
    end

    test "returns {:error, :invalid_response} when payload misses isBlocked" do
      with_mock Finch,
        build: fn :get, _url, _headers -> :req end,
        request: fn :req, WhisprMessaging.Finch, _opts ->
          ok_response(200, ~s({"isContact":true}))
        end do
        assert HttpUserServiceClient.check_user_blocked("u1", "u2") ==
                 {:error, :invalid_response}
      end
    end
  end

  describe "check_user_exists/1" do
    test "returns {:ok, true} when user-service responds 200 (self-paired check)" do
      with_mock Finch,
        build: fn :get, url, _headers ->
          assert url ==
                   "http://user-service.test/internal/v1/contacts/check?ownerId=u1&contactId=u1"

          :req
        end,
        request: fn :req, WhisprMessaging.Finch, _opts ->
          ok_response(200, ~s({"isContact":false,"isBlocked":false}))
        end do
        assert HttpUserServiceClient.check_user_exists("u1") == {:ok, true}
      end
    end

    test "returns {:error, :unauthorized} on 401" do
      with_mock Finch,
        build: fn :get, _url, _headers -> :req end,
        request: fn :req, WhisprMessaging.Finch, _opts -> ok_response(403, "") end do
        assert HttpUserServiceClient.check_user_exists("u1") == {:error, :unauthorized}
      end
    end

    test "returns {:error, :transient} on 5xx" do
      with_mock Finch,
        build: fn :get, _url, _headers -> :req end,
        request: fn :req, WhisprMessaging.Finch, _opts -> ok_response(500, "") end do
        assert HttpUserServiceClient.check_user_exists("u1") == {:error, :transient}
      end
    end

    test "returns {:error, :transient} on transport error" do
      with_mock Finch,
        build: fn :get, _url, _headers -> :req end,
        request: fn :req, WhisprMessaging.Finch, _opts -> {:error, :nxdomain} end do
        assert HttpUserServiceClient.check_user_exists("u1") == {:error, :transient}
      end
    end
  end

  # WHISPR-1304: get_privacy_settings/1 + cache ETS 60s
  describe "get_privacy_settings/1" do
    setup do
      HttpUserServiceClient.reset_privacy_cache()
      :ok
    end

    test "renvoie {:ok, settings} sur 200 et cache le resultat" do
      with_mock Finch,
        build: fn :get, url, headers ->
          assert url == "http://user-service.test/internal/v1/users/u1/privacy"
          assert {"x-internal-token", "secret-token"} in headers
          :req
        end,
        request: fn :req, WhisprMessaging.Finch, _opts ->
          ok_response(
            200,
            ~s({"userId":"u1","readReceipts":false,"lastSeenPrivacy":"contacts","onlineStatus":"nobody"})
          )
        end do
        assert {:ok, settings} = HttpUserServiceClient.get_privacy_settings("u1")
        assert settings.read_receipts == false
        assert settings.last_seen_privacy == "contacts"
        assert settings.online_status == "nobody"

        # 2eme appel = cache hit, le mock Finch a registered build/request
        # une seule fois via with_mock; un second appel reuse le cache.
        assert {:ok, ^settings} = HttpUserServiceClient.get_privacy_settings("u1")
      end
    end

    test "fail-open en renvoyant {:error, :transient} sur 5xx (caller broadcast quand meme)" do
      with_mock Finch,
        build: fn :get, _url, _headers -> :req end,
        request: fn :req, WhisprMessaging.Finch, _opts -> ok_response(503, "") end do
        assert HttpUserServiceClient.get_privacy_settings("u2") == {:error, :transient}
      end
    end

    test "renvoie {:error, :not_found} sur 404 (user inconnu cote user-service)" do
      with_mock Finch,
        build: fn :get, _url, _headers -> :req end,
        request: fn :req, WhisprMessaging.Finch, _opts -> ok_response(404, "") end do
        assert HttpUserServiceClient.get_privacy_settings("u3") == {:error, :not_found}
      end
    end

    test "renvoie read_receipts=true par defaut quand la cle est absente du payload" do
      with_mock Finch,
        build: fn :get, _url, _headers -> :req end,
        request: fn :req, WhisprMessaging.Finch, _opts ->
          ok_response(200, ~s({"userId":"u4","lastSeenPrivacy":"everyone"}))
        end do
        assert {:ok, settings} = HttpUserServiceClient.get_privacy_settings("u4")
        assert settings.read_receipts == true
        assert settings.last_seen_privacy == "everyone"
      end
    end

    test "ignore les valeurs d'enum lastSeenPrivacy non reconnues" do
      with_mock Finch,
        build: fn :get, _url, _headers -> :req end,
        request: fn :req, WhisprMessaging.Finch, _opts ->
          ok_response(200, ~s({"readReceipts":true,"lastSeenPrivacy":"BOGUS"}))
        end do
        assert {:ok, settings} = HttpUserServiceClient.get_privacy_settings("u5")
        assert settings.last_seen_privacy == nil
      end
    end
  end

  describe "headers" do
    test "omits the x-internal-token header when token is empty" do
      Application.put_env(:whispr_messaging, :user_service_internal,
        url: "http://user-service.test/internal/v1",
        token: ""
      )

      with_mock Finch,
        build: fn :get, _url, headers ->
          refute Enum.any?(headers, fn {k, _v} -> k == "x-internal-token" end)
          :req
        end,
        request: fn :req, WhisprMessaging.Finch, _opts ->
          ok_response(200, ~s({"isContact":false,"isBlocked":false}))
        end do
        assert HttpUserServiceClient.check_user_exists("u1") == {:ok, true}
      end
    end
  end
end
