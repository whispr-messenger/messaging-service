defmodule WhisprMessaging.Services.UserServiceTest do
  use ExUnit.Case, async: false

  alias WhisprMessaging.Services.UserService

  describe "user_service_base_url/0" do
    setup do
      previous = System.get_env("USER_SERVICE_HTTP_URL")

      on_exit(fn ->
        case previous do
          nil -> System.delete_env("USER_SERVICE_HTTP_URL")
          value -> System.put_env("USER_SERVICE_HTTP_URL", value)
        end
      end)

      :ok
    end

    test "falls back to the k8s cluster port 3011 when the env var is unset" do
      System.delete_env("USER_SERVICE_HTTP_URL")

      assert UserService.user_service_base_url() == "http://user-service:3011/user/v1"
    end

    test "respects the USER_SERVICE_HTTP_URL override when set" do
      System.put_env("USER_SERVICE_HTTP_URL", "http://custom-user:4200/user/v1")

      assert UserService.user_service_base_url() == "http://custom-user:4200/user/v1"
    end
  end
end
