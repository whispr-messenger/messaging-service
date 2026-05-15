defmodule WhisprMessaging.Services.UserServiceTest do
  use ExUnit.Case, async: false

  alias WhisprMessaging.Services.UserService

  describe "internal_base_url/0" do
    setup do
      previous_app = Application.get_env(:whispr_messaging, :user_service_internal)
      previous_env = System.get_env("USER_SERVICE_INTERNAL_URL")

      on_exit(fn ->
        if previous_app do
          Application.put_env(:whispr_messaging, :user_service_internal, previous_app)
        else
          Application.delete_env(:whispr_messaging, :user_service_internal)
        end

        case previous_env do
          nil -> System.delete_env("USER_SERVICE_INTERNAL_URL")
          value -> System.put_env("USER_SERVICE_INTERNAL_URL", value)
        end
      end)

      Application.delete_env(:whispr_messaging, :user_service_internal)
      System.delete_env("USER_SERVICE_INTERNAL_URL")

      :ok
    end

    test "falls back to the in-cluster default when nothing is configured" do
      assert UserService.internal_base_url() == "http://user-service:3011/internal/v1"
    end

    test "respects the application config when set" do
      Application.put_env(:whispr_messaging, :user_service_internal,
        url: "http://custom-user:4200/internal/v1"
      )

      assert UserService.internal_base_url() == "http://custom-user:4200/internal/v1"
    end

    test "falls back to the env var when application config is missing" do
      System.put_env("USER_SERVICE_INTERNAL_URL", "http://env-user:1234/internal/v1")

      assert UserService.internal_base_url() == "http://env-user:1234/internal/v1"
    end
  end

  describe "client/0 dispatcher" do
    setup do
      previous = Application.get_env(:whispr_messaging, :user_service_client)

      on_exit(fn ->
        if previous do
          Application.put_env(:whispr_messaging, :user_service_client, previous)
        else
          Application.delete_env(:whispr_messaging, :user_service_client)
        end
      end)

      :ok
    end

    test "returns the configured client module" do
      Application.put_env(
        :whispr_messaging,
        :user_service_client,
        WhisprMessaging.Services.MockUserServiceClient
      )

      assert UserService.client() == WhisprMessaging.Services.MockUserServiceClient
    end

    test "falls back to the HTTP client when nothing is configured" do
      Application.delete_env(:whispr_messaging, :user_service_client)

      assert UserService.client() == WhisprMessaging.Services.HttpUserServiceClient
    end

    test "delegates check_user_exists/1 to the configured client" do
      Application.put_env(
        :whispr_messaging,
        :user_service_client,
        WhisprMessaging.Services.MockUserServiceClient
      )

      Process.put(:mock_user_service_client, %{
        check_user_exists: fn "missing" -> {:ok, false} end
      })

      assert UserService.check_user_exists("missing") == {:ok, false}
    end

    test "delegates check_user_blocked/2 to the configured client" do
      Application.put_env(
        :whispr_messaging,
        :user_service_client,
        WhisprMessaging.Services.MockUserServiceClient
      )

      Process.put(:mock_user_service_client, %{
        check_user_blocked: fn "a", "b" -> {:ok, true} end
      })

      assert UserService.check_user_blocked("a", "b") == {:ok, true}
    end
  end

  describe "internal_token/0" do
    setup do
      prev_app = Application.get_env(:whispr_messaging, :user_service_internal)
      prev_env = System.get_env("INTERNAL_API_TOKEN")

      on_exit(fn ->
        if prev_app do
          Application.put_env(:whispr_messaging, :user_service_internal, prev_app)
        else
          Application.delete_env(:whispr_messaging, :user_service_internal)
        end

        case prev_env do
          nil -> System.delete_env("INTERNAL_API_TOKEN")
          value -> System.put_env("INTERNAL_API_TOKEN", value)
        end
      end)

      Application.delete_env(:whispr_messaging, :user_service_internal)
      System.delete_env("INTERNAL_API_TOKEN")
      :ok
    end

    test "returns nil when nothing is configured" do
      assert UserService.internal_token() == nil
    end

    test "honours application config token" do
      Application.put_env(:whispr_messaging, :user_service_internal, token: "from-config")
      assert UserService.internal_token() == "from-config"
    end

    test "falls back to env var when application config is missing" do
      System.put_env("INTERNAL_API_TOKEN", "from-env")
      assert UserService.internal_token() == "from-env"
    end
  end

  describe "check_users_are_contacts/3" do
    import Mock

    test "returns {:ok, true} on 200 with isContact: true, isBlocked: false" do
      body = Jason.encode!(%{"isContact" => true, "isBlocked" => false})

      with_mock Finch, [:passthrough],
        request: fn _req, _name ->
          {:ok, %Finch.Response{status: 200, body: body, headers: []}}
        end do
        assert {:ok, true} = UserService.check_users_are_contacts("a", "b")
      end
    end

    test "returns {:ok, false} when blocked" do
      body = Jason.encode!(%{"isContact" => true, "isBlocked" => true})

      with_mock Finch, [:passthrough],
        request: fn _req, _name ->
          {:ok, %Finch.Response{status: 200, body: body, headers: []}}
        end do
        assert {:ok, false} = UserService.check_users_are_contacts("a", "b")
      end
    end

    test "returns {:ok, false} when not a contact" do
      body = Jason.encode!(%{"isContact" => false, "isBlocked" => false})

      with_mock Finch, [:passthrough],
        request: fn _req, _name ->
          {:ok, %Finch.Response{status: 200, body: body, headers: []}}
        end do
        assert {:ok, false} = UserService.check_users_are_contacts("a", "b")
      end
    end

    test "returns {:error, :unauthorized} on 401/403" do
      with_mock Finch, [:passthrough],
        request: fn _req, _name -> {:ok, %Finch.Response{status: 401, body: "", headers: []}} end do
        assert {:error, :unauthorized} = UserService.check_users_are_contacts("a", "b")
      end

      with_mock Finch, [:passthrough],
        request: fn _req, _name -> {:ok, %Finch.Response{status: 403, body: "", headers: []}} end do
        assert {:error, :unauthorized} = UserService.check_users_are_contacts("a", "b")
      end
    end

    test "returns {:error, :request_failed} on 500" do
      with_mock Finch, [:passthrough],
        request: fn _req, _name -> {:ok, %Finch.Response{status: 500, body: "", headers: []}} end do
        assert {:error, :request_failed} = UserService.check_users_are_contacts("a", "b")
      end
    end

    test "returns {:error, :request_failed} on transport error" do
      with_mock Finch, [:passthrough],
        request: fn _req, _name ->
          {:error, %Mint.TransportError{reason: :econnrefused}}
        end do
        assert {:error, :request_failed} = UserService.check_users_are_contacts("a", "b")
      end
    end

    test "returns {:error, :invalid_response} on malformed body" do
      with_mock Finch, [:passthrough],
        request: fn _req, _name ->
          {:ok, %Finch.Response{status: 200, body: "not json", headers: []}}
        end do
        assert {:error, :invalid_response} = UserService.check_users_are_contacts("a", "b")
      end
    end
  end
end
