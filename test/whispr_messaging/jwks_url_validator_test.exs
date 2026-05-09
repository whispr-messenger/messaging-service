defmodule WhisprMessaging.JwksUrlValidatorTest do
  # async: false car les tests touchent System.get_env / put_env
  use ExUnit.Case, async: false

  alias WhisprMessaging.JwksUrlValidator

  setup do
    # Sauvegarde l'etat initial pour ne pas polluer les autres tests
    initial = System.get_env("WHISPR_ALLOW_HTTP_JWKS")
    System.delete_env("WHISPR_ALLOW_HTTP_JWKS")

    on_exit(fn ->
      case initial do
        nil -> System.delete_env("WHISPR_ALLOW_HTTP_JWKS")
        val -> System.put_env("WHISPR_ALLOW_HTTP_JWKS", val)
      end
    end)

    :ok
  end

  describe "validate!/2 in :prod" do
    test "accepte une URL https://" do
      assert :ok =
               JwksUrlValidator.validate!(
                 "https://auth.example.com/auth/.well-known/jwks.json",
                 :prod
               )
    end

    test "leve si l'URL est en http://" do
      assert_raise RuntimeError, ~r/JWT_JWKS_URL/, fn ->
        JwksUrlValidator.validate!(
          "http://auth-service/auth/.well-known/jwks.json",
          :prod
        )
      end
    end

    test "leve si l'URL n'a pas de scheme" do
      assert_raise RuntimeError, ~r/JWT_JWKS_URL/, fn ->
        JwksUrlValidator.validate!("auth-service/jwks.json", :prod)
      end
    end

    test "le message d'erreur mentionne explicitement la variable d'env et https" do
      err =
        assert_raise RuntimeError, fn ->
          JwksUrlValidator.validate!("http://auth-service/jwks.json", :prod)
        end

      assert err.message =~ "JWT_JWKS_URL"
      assert err.message =~ "https://"
    end

    test "accepte une URL http:// si WHISPR_ALLOW_HTTP_JWKS=true (cluster-internal)" do
      System.put_env("WHISPR_ALLOW_HTTP_JWKS", "true")

      assert :ok =
               JwksUrlValidator.validate!(
                 "http://auth-service:3010/auth/.well-known/jwks.json",
                 :prod
               )
    end

    test "leve sur http:// si WHISPR_ALLOW_HTTP_JWKS=false (default strict)" do
      System.put_env("WHISPR_ALLOW_HTTP_JWKS", "false")

      assert_raise RuntimeError, ~r/JWT_JWKS_URL/, fn ->
        JwksUrlValidator.validate!(
          "http://auth-service/auth/.well-known/jwks.json",
          :prod
        )
      end
    end

    test "leve sur http:// si WHISPR_ALLOW_HTTP_JWKS est unset (default strict)" do
      assert_raise RuntimeError, ~r/JWT_JWKS_URL/, fn ->
        JwksUrlValidator.validate!(
          "http://auth-service/auth/.well-known/jwks.json",
          :prod
        )
      end
    end

    test "accepte une URL https:// meme avec WHISPR_ALLOW_HTTP_JWKS=true" do
      System.put_env("WHISPR_ALLOW_HTTP_JWKS", "true")

      assert :ok =
               JwksUrlValidator.validate!(
                 "https://auth.example.com/jwks.json",
                 :prod
               )
    end
  end

  describe "validate!/2 in :dev" do
    test "accepte une URL http:// (k8s interne ou local)" do
      assert :ok =
               JwksUrlValidator.validate!(
                 "http://auth-service/auth/.well-known/jwks.json",
                 :dev
               )
    end

    test "accepte une URL https://" do
      assert :ok =
               JwksUrlValidator.validate!(
                 "https://auth.example.com/jwks.json",
                 :dev
               )
    end
  end

  describe "validate!/2 in :test" do
    test "accepte une URL http://" do
      assert :ok =
               JwksUrlValidator.validate!(
                 "http://auth-service/auth/.well-known/jwks.json",
                 :test
               )
    end
  end
end
