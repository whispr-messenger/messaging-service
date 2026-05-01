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
end
