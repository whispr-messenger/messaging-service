defmodule WhisprMessagingWeb.FallbackControllerTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias WhisprMessaging.Messages.Message
  alias WhisprMessagingWeb.FallbackController

  defp run(error) do
    conn = conn(:get, "/anything")
    FallbackController.call(conn, error)
  end

  defp body(conn) do
    Jason.decode!(conn.resp_body)
  end

  test ":not_found returns 404" do
    conn = run({:error, :not_found})
    assert conn.status == 404
    assert body(conn)["error"] =~ "not found"
  end

  test ":unauthorized returns 401" do
    conn = run({:error, :unauthorized})
    assert conn.status == 401
    assert body(conn)["error"] =~ "Unauthorized"
  end

  test ":forbidden returns 403" do
    conn = run({:error, :forbidden})
    assert conn.status == 403
    assert body(conn)["error"] == "Forbidden"
  end

  test "Ecto changeset returns 422 with details" do
    {:error, changeset} =
      %Message{}
      |> Message.changeset(%{})
      |> Ecto.Changeset.apply_action(:insert)

    conn = run({:error, changeset})
    assert conn.status == 422
    assert body(conn)["error"] == "Validation failed"
    assert is_map(body(conn)["details"])
  end

  test "atom error returns 400 with stringified reason" do
    conn = run({:error, :rate_limited})
    assert conn.status == 400
    assert body(conn)["error"] == "rate limited"
  end

  test "binary error returns 400 with the message" do
    conn = run({:error, "missing kid"})
    assert conn.status == 400
    assert body(conn)["error"] == "missing kid"
  end

  test "anything else returns 500" do
    conn = run({:error, %RuntimeError{message: "ouch"}})
    assert conn.status == 500
    assert body(conn)["error"] =~ "Internal"
  end
end
