defmodule WhisprMessaging.JsonFormatterTest do
  use ExUnit.Case, async: true

  alias WhisprMessaging.JsonFormatter

  @ts {{2026, 4, 22}, {12, 34, 56, 789}}

  test "emits a JSON line terminated by a newline" do
    output =
      JsonFormatter.format(:info, "hello", @ts, [
        service: "messaging",
        request_id: "req-1"
      ])

    raw = IO.iodata_to_binary(output)
    assert String.ends_with?(raw, "\n")

    payload = Jason.decode!(String.trim(raw))

    assert payload["level"] == "info"
    assert payload["message"] == "hello"
    assert payload["timestamp"] == "2026-04-22T12:34:56.789Z"
    assert payload["service"] == "messaging"
    assert payload["request_id"] == "req-1"
  end

  test "stringifies atoms and inspects unknown terms in metadata" do
    output =
      JsonFormatter.format(:warning, "oops", @ts,
        user_id: :guest,
        ref: make_ref()
      )

    payload = Jason.decode!(String.trim(IO.iodata_to_binary(output)))

    assert payload["level"] == "warning"
    assert payload["user_id"] == "guest"
    assert is_binary(payload["ref"])
    assert String.starts_with?(payload["ref"], "#Reference")
  end

  test "flattens chardata messages (Elixir Logger may pass iolists)" do
    output = JsonFormatter.format(:error, ["boom ", ["nested ", "details"]], @ts, [])

    payload = Jason.decode!(String.trim(IO.iodata_to_binary(output)))

    assert payload["message"] == "boom nested details"
  end

  test "uses DateTime.utc_now/0 as fallback when timestamp is unexpected" do
    output = JsonFormatter.format(:debug, "msg", :bogus, [])

    payload = Jason.decode!(String.trim(IO.iodata_to_binary(output)))

    assert Regex.match?(~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/, payload["timestamp"])
  end

  test "serializes nested maps and lists" do
    output =
      JsonFormatter.format(:info, "ok", @ts,
        params: %{"query" => "hello", "limit" => 10},
        tags: [:a, :b]
      )

    payload = Jason.decode!(String.trim(IO.iodata_to_binary(output)))

    assert payload["params"] == %{"query" => "hello", "limit" => 10}
    assert payload["tags"] == ["a", "b"]
  end
end
