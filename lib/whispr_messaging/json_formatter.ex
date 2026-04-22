defmodule WhisprMessaging.JsonFormatter do
  @moduledoc """
  WHISPR-1068 — Elixir Logger formatter émettant une ligne JSON par log.

  Branché via `config :logger, :console, format: {WhisprMessaging.JsonFormatter, :format}`
  quand `LOG_FORMAT=json` est positionné (runtime.exs). En dev local, le
  format texte natif (`$time $metadata[$level] $message\\n`) est conservé.

  Champs émis :
    - timestamp : ISO 8601 (résolution microseconde quand disponible)
    - level : `info` | `warning` | `error` | `debug`
    - message : texte libre (iodata aplati)
    - service, pod : lus depuis Logger.metadata globale
    - request_id, conversation_id, user_id : injectés par Plug.RequestId et
      `WhisprMessagingWeb.Plugs.Authenticate`
    - *autres clés metadata* : fusionnées telles quelles (valeurs non
      sérialisables → `inspect/1`)
  """

  @spec format(Logger.level(), Logger.message(), Logger.Formatter.date_time_ms(), Keyword.t()) ::
          IO.chardata()
  def format(level, message, timestamp, metadata) do
    payload =
      metadata
      |> normalize_metadata()
      |> Map.put(:level, Atom.to_string(level))
      |> Map.put(:timestamp, format_timestamp(timestamp))
      |> Map.put(:message, safe_chardata_to_string(message))

    [Jason.encode_to_iodata!(payload), ?\n]
  rescue
    # Jamais faire crasher le logger — si l'encodage échoue, replie sur un
    # message texte qui ne perd pas d'information mais quitte le format JSON.
    err ->
      [
        "{",
        ~s|"level":"|,
        Atom.to_string(level),
        ~s|","message":"|,
        escape_string("formatter error: " <> Exception.message(err)),
        ~s|"}|,
        ?\n
      ]
  end

  defp normalize_metadata(metadata) do
    Enum.reduce(metadata, %{}, fn {key, value}, acc ->
      Map.put(acc, key, sanitize(value))
    end)
  end

  defp sanitize(value) when is_binary(value), do: value
  defp sanitize(value) when is_number(value), do: value
  defp sanitize(value) when is_boolean(value), do: value
  defp sanitize(nil), do: nil
  defp sanitize(value) when is_atom(value), do: Atom.to_string(value)
  defp sanitize(value) when is_list(value), do: Enum.map(value, &sanitize/1)

  defp sanitize(value) when is_map(value) do
    value
    |> Enum.map(fn {k, v} -> {sanitize_key(k), sanitize(v)} end)
    |> Map.new()
  end

  defp sanitize(value) when is_tuple(value) do
    value |> Tuple.to_list() |> Enum.map(&sanitize/1)
  end

  defp sanitize(value), do: inspect(value, limit: 50)

  defp sanitize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp sanitize_key(key) when is_binary(key), do: key
  defp sanitize_key(key), do: inspect(key)

  # Logger.Formatter timestamp: {{y, m, d}, {h, mi, s, ms}}
  defp format_timestamp({{year, month, day}, {hour, minute, second, millisecond}}) do
    :io_lib.format(
      "~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0B.~3..0BZ",
      [year, month, day, hour, minute, second, millisecond]
    )
    |> IO.iodata_to_binary()
  end

  defp format_timestamp(_), do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp safe_chardata_to_string(message) do
    try do
      IO.chardata_to_string(message)
    rescue
      _ -> inspect(message)
    end
  end

  defp escape_string(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
  end
end
