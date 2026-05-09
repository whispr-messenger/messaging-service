defmodule WhisprMessaging.JwksUrlValidatorTest do
  use ExUnit.Case, async: true

  alias WhisprMessaging.JwksUrlValidator

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
