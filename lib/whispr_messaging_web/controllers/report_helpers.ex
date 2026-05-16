defmodule WhisprMessagingWeb.ReportHelpers do
  @moduledoc """
  Pure helpers extracted from `ReportController` so they can be unit-tested
  in isolation. External REST contract is unchanged — `ReportController`
  delegates to these via thin wrappers.
  """

  @doc """
  Serializes a `WhisprMessaging.Moderation.Report` (or a map shaped like one)
  into the public REST representation.
  """
  @spec serialize_report(map()) :: map()
  def serialize_report(report) do
    %{
      id: report.id,
      reporter_id: report.reporter_id,
      reported_user_id: report.reported_user_id,
      conversation_id: report.conversation_id,
      message_id: report.message_id,
      category: report.category,
      description: report.description,
      evidence: report.evidence,
      status: report.status,
      resolution: report.resolution,
      auto_escalated: report.auto_escalated,
      created_at: report.inserted_at && NaiveDateTime.to_iso8601(report.inserted_at),
      updated_at: report.updated_at && NaiveDateTime.to_iso8601(report.updated_at)
    }
  end

  @doc """
  Renders Ecto changeset error messages by interpolating each placeholder
  (e.g. `%{count}`) with its option value.
  """
  @spec format_changeset_errors(Ecto.Changeset.t() | term()) :: map() | String.t()
  def format_changeset_errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  def format_changeset_errors(error), do: inspect(error)

  @doc """
  Returns `true` when `user_id` appears in the comma-separated `ADMIN_USER_IDS`
  env variable. Otherwise (env absent, empty, or no match) returns `false`.
  """
  @spec fallback_admin_check(String.t() | nil) :: boolean()
  def fallback_admin_check(user_id) do
    case System.get_env("ADMIN_USER_IDS") do
      nil -> false
      ids -> user_id in (ids |> String.split(",") |> Enum.map(&String.trim/1))
    end
  end

  @doc """
  Parses an integer from a query-string param. Returns `default` when the
  input is nil, a non-integer string, or anything else.
  """
  @spec parse_int(any(), integer()) :: integer()
  def parse_int(nil, default), do: default

  def parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {int, _} -> int
      :error -> default
    end
  end

  def parse_int(val, _default) when is_integer(val), do: val

  @doc """
  Returns `true` when the provided role is admin or moderator. Used by
  `admin_or_moderator?` after a plug pre-resolution.
  """
  @spec admin_role?(any()) :: boolean()
  def admin_role?(role) when role in ["admin", "moderator"], do: true
  def admin_role?(_), do: false

  @doc """
  Interprets a cache hit shape for the admin role. Cache may store either
  a plain role string ("admin", "moderator", anything else) or a JSON map
  `%{"role" => role}` (TTL-tagged variant).
  """
  @spec role_from_cache(any()) :: :admin | :other | :miss
  def role_from_cache({:ok, %{"role" => role}}) when role in ["admin", "moderator"], do: :admin
  def role_from_cache({:ok, role}) when role in ["admin", "moderator"], do: :admin
  def role_from_cache({:ok, _}), do: :other
  def role_from_cache(_), do: :miss
end
