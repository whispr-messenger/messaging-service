defmodule WhisprMessagingWeb.ParamHelpers do
  @moduledoc """
  Shared parsing helpers for query-string params (controllers).
  Pure functions; each branch is unit-tested in isolation.
  """

  @doc """
  Parses an integer that must be within `[min_val, max_val]`. Out-of-range
  values are clamped to the boundary. Non-integers fall back to `default`.
  """
  @spec parse_bounded_int(any(), integer(), integer(), integer()) :: integer()
  def parse_bounded_int(nil, default, _min, _max), do: default

  def parse_bounded_int(val, default, min_val, max_val) when is_binary(val) do
    case Integer.parse(val) do
      {int, _} -> max(min_val, min(int, max_val))
      :error -> default
    end
  end

  def parse_bounded_int(val, _default, min_val, max_val) when is_integer(val) do
    max(min_val, min(val, max_val))
  end

  def parse_bounded_int(_val, default, _min, _max), do: default

  @doc """
  Parses an optional integer. Returns `nil` for nil / unparseable input,
  passes integers through unchanged.
  """
  @spec parse_optional_int(any()) :: integer() | nil
  def parse_optional_int(nil), do: nil

  def parse_optional_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {int, _} -> int
      :error -> nil
    end
  end

  def parse_optional_int(val) when is_integer(val), do: val
  def parse_optional_int(_), do: nil

  @doc """
  Inserts `{key, value}` into `opts` only when `value` is not `nil`.
  Used to lazily build keyword options without pre-filtering.
  """
  @spec maybe_add_opt(keyword(), atom(), any()) :: keyword()
  def maybe_add_opt(opts, _key, nil), do: opts
  def maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)

  @doc """
  Parses a query-string int that must be `>= opts[:min]` (default 0) and
  is clamped from above to `opts[:max]` (default 1_000_000). Falls back
  to `default` on missing / malformed / out-of-range input.
  """
  @spec parse_int_with_opts(any(), integer(), keyword()) :: integer()
  def parse_int_with_opts(value, default, opts) do
    min_v = Keyword.get(opts, :min, 0)
    max_v = Keyword.get(opts, :max, 1_000_000)

    case parse_int_value(value) do
      {:ok, n} when n >= min_v -> min(n, max_v)
      _ -> default
    end
  end

  @doc """
  Strict integer parser: only accepts an integer or a binary that parses
  cleanly with no trailing characters. Returns `{:ok, n}` or `:error`.
  """
  @spec parse_int_value(any()) :: {:ok, integer()} | :error
  def parse_int_value(nil), do: :error
  def parse_int_value(n) when is_integer(n), do: {:ok, n}

  def parse_int_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  def parse_int_value(_), do: :error
end
