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
