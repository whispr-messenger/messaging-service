defmodule WhisprMessaging.JwksUrlValidator do
  @moduledoc """
  Validation runtime du `JWT_JWKS_URL` selon l'environnement Mix.

  Empeche un demarrage en `:prod` si l'URL JWKS n'est pas servie via
  HTTPS — un mis-deploiement (par exemple un Helm values pointant sur
  l'URL interne `http://auth-service/...`) doit echouer rapidement plutot
  que de laisser circuler des cles publiques sur un canal en clair.

  Les environnements `:dev` et `:test` ne sont pas verifies: le cluster
  k8s interne et les boucles locales utilisent legitimement HTTP.

  Override explicite `WHISPR_ALLOW_HTTP_JWKS=true` : permet d'autoriser
  HTTP en `:prod` quand l'auth-service est joint via un service k8s
  cluster-internal (cas preprod). A ne PAS activer en prod publique.
  """

  @doc """
  Valide l'URL JWKS pour l'environnement donne.

  Renvoie `:ok` si l'URL est acceptable, sinon leve une `RuntimeError`
  avec un message indiquant la variable d'env a corriger.
  """
  @spec validate!(String.t(), atom()) :: :ok | no_return()
  def validate!(url, env)

  def validate!(url, :prod) when is_binary(url) do
    cond do
      String.starts_with?(url, "https://") ->
        :ok

      System.get_env("WHISPR_ALLOW_HTTP_JWKS") == "true" ->
        :ok

      true ->
        raise """
        JWT_JWKS_URL doit utiliser HTTPS en production.
        Valeur actuelle: #{inspect(url)}
        Corrigez la variable d'environnement JWT_JWKS_URL pour pointer
        sur une URL https:// (ex: https://auth.example.com/auth/.well-known/jwks.json).
        Pour autoriser HTTP en cluster-internal (preprod), definissez
        WHISPR_ALLOW_HTTP_JWKS=true.
        """
    end
  end

  def validate!(_url, env) when env in [:dev, :test] do
    :ok
  end
end
