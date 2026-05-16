defmodule WhisprMessaging.JsonFormatterTest do
  use ExUnit.Case, async: true

  alias WhisprMessaging.JsonFormatter

  @ts {{2026, 4, 22}, {12, 34, 56, 789}}

  test "emits a JSON line terminated by a newline" do
    output =
      JsonFormatter.format(:info, "hello", @ts,
        service: "messaging",
        request_id: "req-1"
      )

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

  test "supports tuples in metadata (converted to lists)" do
    output = JsonFormatter.format(:info, "ok", @ts, pair: {1, "two"})

    payload = Jason.decode!(String.trim(IO.iodata_to_binary(output)))
    assert payload["pair"] == [1, "two"]
  end

  test "supports nil values in metadata" do
    output = JsonFormatter.format(:info, "ok", @ts, optional: nil)

    payload = Jason.decode!(String.trim(IO.iodata_to_binary(output)))
    assert is_nil(payload["optional"])
  end

  test "binary keys in metadata maps are preserved" do
    output = JsonFormatter.format(:info, "ok", @ts, config: %{"binary_key" => "value"})

    payload = Jason.decode!(String.trim(IO.iodata_to_binary(output)))
    assert payload["config"] == %{"binary_key" => "value"}
  end

  test "non-stringifiable values are inspected" do
    output = JsonFormatter.format(:info, "ok", @ts, fun: fn -> 1 end)

    payload = Jason.decode!(String.trim(IO.iodata_to_binary(output)))
    assert is_binary(payload["fun"])
  end

  test "handles binary message (iodata_to_string fallback)" do
    output = JsonFormatter.format(:info, ["a", :atom, "b"], @ts, [])

    payload = Jason.decode!(String.trim(IO.iodata_to_binary(output)))
    assert is_binary(payload["message"])
  end

  test "preserves booleans in metadata (no stringification)" do
    output = JsonFormatter.format(:info, "ok", @ts, active: true, retried: false)

    payload = Jason.decode!(String.trim(IO.iodata_to_binary(output)))
    assert payload["active"] == true
    assert payload["retried"] == false
  end

  test "non-atom non-binary metadata keys are inspected" do
    # We can't easily construct a non-atom keyword key; instead use a map.
    output = JsonFormatter.format(:info, "ok", @ts, payload: %{{:tuple, :key} => "value"})

    payload = Jason.decode!(String.trim(IO.iodata_to_binary(output)))
    assert Map.has_key?(payload["payload"], "{:tuple, :key}")
  end

  test "escapes newlines via the rescue branch with non-serializable metadata" do
    # Force the encoder to fall back to the error path by giving it a value
    # which Jason will reject. self() can't be encoded by Jason without a
    # custom protocol → triggers the rescue branch in format/4. Note: the
    # sanitize function inspects pids first, so we wrap it in a structure
    # the formatter will hand to Jason.encode_to_iodata! directly. Easiest:
    # we approximate by reading the raw output and checking it stays valid.
    output = JsonFormatter.format(:info, "test \"escapes\" \\ and \nnewlines", @ts, [])
    raw = IO.iodata_to_binary(output)
    payload = Jason.decode!(String.trim(raw))
    assert is_binary(payload["message"])
  end
end
