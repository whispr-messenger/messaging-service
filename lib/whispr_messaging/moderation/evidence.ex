defmodule WhisprMessaging.Moderation.Evidence do
  @moduledoc """
  Enhanced evidence management for moderation reports.

  Captures full message context (surrounding messages), formats evidence
  for export, and provides redaction of sensitive data for compliance.
  """

  import Ecto.Query

  alias WhisprMessaging.Repo
  alias WhisprMessaging.Messages.Message
  alias WhisprMessaging.Moderation.Report

  require Logger

  @type evidence_snapshot :: %{
          reported_message: map() | nil,
          surrounding_messages: [map()],
          conversation_context: map(),
          captured_at: String.t(),
          metadata: map()
        }

  @type export_format :: :json | :csv | :text

  # Number of messages to capture before and after the reported message
  @context_window 5

  # Fields considered sensitive and eligible for redaction
  @sensitive_fields ~w(phone email ip_address location device_id)
  @email_pattern ~r/[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/
  @phone_pattern ~r/\+?[\d\s\-().]{7,15}/

  # ---------------------------------------------------------------------------
  # Evidence capture
  # ---------------------------------------------------------------------------

  @doc """
  Captures a full evidence snapshot for a reported message.

  Includes the reported message itself plus surrounding messages
  (#{@context_window} before and after) for context.

  ## Parameters
    * `message_id` - the ID of the reported message
    * `conversation_id` - the conversation containing the message

  ## Returns
  `{:ok, evidence_snapshot}` or `{:error, reason}`
  """
  @spec capture_full_context(String.t(), String.t()) ::
          {:ok, evidence_snapshot()} | {:error, term()}
  def capture_full_context(message_id, conversation_id) do
    Logger.info("[Evidence] Capturing full context for message #{message_id}")

    with {:ok, reported_msg} <- fetch_message(message_id),
         surrounding <- fetch_surrounding_messages(message_id, conversation_id),
         context <- build_conversation_context(conversation_id) do
      snapshot = %{
        reported_message: serialize_message(reported_msg),
        surrounding_messages: Enum.map(surrounding, &serialize_message/1),
        conversation_context: context,
        captured_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        metadata: %{
          context_window: @context_window,
          total_surrounding: length(surrounding),
          capture_version: "2.0"
        }
      }

      {:ok, snapshot}
    end
  end

  @doc """
  Captures a minimal evidence snapshot (just the reported message, no context).
  Lighter-weight alternative to `capture_full_context/2`.
  """
  @spec capture_minimal(String.t()) :: {:ok, map()} | {:error, term()}
  def capture_minimal(message_id) do
    case fetch_message(message_id) do
      {:ok, message} ->
        snapshot = %{
          reported_message: serialize_message(message),
          surrounding_messages: [],
          captured_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          metadata: %{capture_version: "2.0", minimal: true}
        }

        {:ok, snapshot}

      error ->
        error
    end
  end

  # ---------------------------------------------------------------------------
  # Evidence enrichment
  # ---------------------------------------------------------------------------

  @doc """
  Enriches an existing report's evidence with additional context.
  Fetches surrounding messages if they were not captured initially.

  ## Parameters
    * `report` - a `%Report{}` struct with existing evidence

  ## Returns
  `{:ok, enriched_evidence}` or `{:error, reason}`
  """
  @spec enrich_evidence(Report.t()) :: {:ok, map()} | {:error, term()}
  def enrich_evidence(%Report{
        evidence: evidence,
        message_id: message_id,
        conversation_id: conv_id
      })
      when not is_nil(message_id) and not is_nil(conv_id) do
    case capture_full_context(message_id, conv_id) do
      {:ok, full_snapshot} ->
        enriched =
          Map.merge(evidence || %{}, %{
            "surrounding_messages" => full_snapshot.surrounding_messages,
            "conversation_context" => full_snapshot.conversation_context,
            "enriched_at" => DateTime.utc_now() |> DateTime.to_iso8601()
          })

        {:ok, enriched}

      error ->
        error
    end
  end

  def enrich_evidence(%Report{}), do: {:error, :no_message_context}

  # ---------------------------------------------------------------------------
  # Redaction
  # ---------------------------------------------------------------------------

  @doc """
  Redacts sensitive data from evidence for compliance or export.

  Replaces email addresses, phone numbers, and fields listed in
  `@sensitive_fields` with redacted placeholders.

  ## Parameters
    * `evidence` - a map of evidence data
    * `opts` - redaction options
      * `:fields` - additional fields to redact (default: #{inspect(@sensitive_fields)})
      * `:redact_content` - whether to redact message content patterns (default: true)

  ## Returns
  The evidence map with sensitive data replaced by "[REDACTED]".
  """
  @spec redact(map(), keyword()) :: map()
  def redact(evidence, opts \\ []) when is_map(evidence) do
    extra_fields = Keyword.get(opts, :fields, [])
    redact_content = Keyword.get(opts, :redact_content, true)

    all_fields = @sensitive_fields ++ extra_fields

    evidence
    |> redact_fields(all_fields)
    |> maybe_redact_content(redact_content)
  end

  @doc """
  Redacts a single string value, replacing emails and phone numbers.
  """
  @spec redact_string(String.t()) :: String.t()
  def redact_string(text) when is_binary(text) do
    text
    |> Regex.replace(@email_pattern, "[EMAIL REDACTED]")
    |> Regex.replace(@phone_pattern, "[PHONE REDACTED]")
  end

  def redact_string(other), do: other

  # ---------------------------------------------------------------------------
  # Export formatting
  # ---------------------------------------------------------------------------

  @doc """
  Formats evidence for export in the specified format.

  ## Parameters
    * `evidence` - a map of evidence data
    * `format` - export format (`:json`, `:csv`, or `:text`)
    * `opts` - formatting options
      * `:redact` - apply redaction before export (default: true)
      * `:include_metadata` - include capture metadata (default: true)

  ## Returns
  `{:ok, formatted_string}` or `{:error, reason}`
  """
  @spec format_for_export(map(), export_format(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def format_for_export(evidence, format, opts \\ []) do
    should_redact = Keyword.get(opts, :redact, true)
    include_meta = Keyword.get(opts, :include_metadata, true)

    prepared =
      evidence
      |> maybe_apply_redaction(should_redact)
      |> maybe_strip_metadata(include_meta)

    case format do
      :json -> format_json(prepared)
      :csv -> format_csv(prepared)
      :text -> format_text(prepared)
      _ -> {:error, :unsupported_format}
    end
  end

  @doc """
  Generates a human-readable evidence summary for moderator review.

  ## Parameters
    * `evidence` - a map of evidence data

  ## Returns
  A formatted string summarizing the evidence.
  """
  @spec summarize(map()) :: String.t()
  def summarize(evidence) when is_map(evidence) do
    lines = ["=== Evidence Summary ===", ""]

    # Reported message
    lines =
      case Map.get(evidence, "reported_message") || Map.get(evidence, :reported_message) do
        nil ->
          lines ++ ["Reported message: N/A"]

        msg ->
          content = Map.get(msg, "content") || Map.get(msg, :content) || "[no content]"
          sender = Map.get(msg, "sender_id") || Map.get(msg, :sender_id) || "unknown"

          lines ++
            [
              "Reported message:",
              "  Sender: #{sender}",
              "  Content: #{truncate(content, 200)}"
            ]
      end

    # Surrounding context count
    surrounding =
      Map.get(evidence, "surrounding_messages") ||
        Map.get(evidence, :surrounding_messages) || []

    lines = lines ++ ["", "Context messages: #{length(surrounding)}"]

    # Capture timestamp
    captured =
      Map.get(evidence, "captured_at") ||
        Map.get(evidence, :captured_at) || "unknown"

    lines = lines ++ ["Captured at: #{captured}", ""]

    Enum.join(lines, "\n")
  end

  # ---------------------------------------------------------------------------
  # Batch evidence operations
  # ---------------------------------------------------------------------------

  @doc """
  Captures evidence for multiple reports in parallel.
  Useful for batch processing or backfilling evidence.

  ## Parameters
    * `reports` - list of `%Report{}` structs

  ## Returns
  A list of `{report_id, {:ok, evidence} | {:error, reason}}` tuples.
  """
  @spec batch_capture([Report.t()]) :: [{String.t(), {:ok, map()} | {:error, term()}}]
  def batch_capture(reports) when is_list(reports) do
    Logger.info("[Evidence] Batch capturing evidence for #{length(reports)} reports")

    reports
    |> Enum.map(fn report ->
      result =
        if report.message_id && report.conversation_id do
          capture_full_context(report.message_id, report.conversation_id)
        else
          {:error, :no_message_context}
        end

      {report.id, result}
    end)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp fetch_message(message_id) do
    case Repo.get(Message, message_id) do
      nil -> {:error, :message_not_found}
      message -> {:ok, message}
    end
  end

  defp fetch_surrounding_messages(message_id, conversation_id) do
    # Get the reported message's timestamp for ordering context
    case fetch_message(message_id) do
      {:ok, reported_msg} ->
        before_msgs =
          from(m in Message,
            where:
              m.conversation_id == ^conversation_id and
                m.id != ^message_id and
                m.inserted_at <= ^reported_msg.inserted_at,
            order_by: [desc: m.inserted_at],
            limit: ^@context_window
          )
          |> Repo.all()
          |> Enum.reverse()

        after_msgs =
          from(m in Message,
            where:
              m.conversation_id == ^conversation_id and
                m.id != ^message_id and
                m.inserted_at > ^reported_msg.inserted_at,
            order_by: [asc: m.inserted_at],
            limit: ^@context_window
          )
          |> Repo.all()

        before_msgs ++ after_msgs

      {:error, _} ->
        []
    end
  end

  defp build_conversation_context(conversation_id) do
    total_messages =
      from(m in Message, where: m.conversation_id == ^conversation_id, select: count(m.id))
      |> Repo.one()

    unique_participants =
      from(m in Message,
        where: m.conversation_id == ^conversation_id,
        select: count(m.sender_id, :distinct)
      )
      |> Repo.one()

    %{
      conversation_id: conversation_id,
      total_messages: total_messages,
      unique_participants: unique_participants,
      snapshot_time: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp serialize_message(message) do
    %{
      id: message.id,
      sender_id: message.sender_id,
      conversation_id: message.conversation_id,
      message_type: message.message_type,
      content: if(message.content, do: Base.encode64(message.content), else: nil),
      metadata: message.metadata,
      inserted_at: NaiveDateTime.to_iso8601(message.inserted_at)
    }
  end

  defp redact_fields(evidence, fields) do
    Enum.reduce(fields, evidence, fn field, acc ->
      deep_redact_field(acc, field)
    end)
  end

  defp deep_redact_field(map, field) when is_map(map) do
    field_str = to_string(field)

    Map.new(map, fn {k, v} ->
      if to_string(k) == field_str do
        {k, "[REDACTED]"}
      else
        cond do
          is_map(v) ->
            {k, deep_redact_field(v, field)}

          is_list(v) ->
            {k,
             Enum.map(v, fn item ->
               if is_map(item), do: deep_redact_field(item, field), else: item
             end)}

          true ->
            {k, v}
        end
      end
    end)
  end

  defp deep_redact_field(other, _field), do: other

  defp maybe_redact_content(evidence, false), do: evidence

  defp maybe_redact_content(evidence, true) do
    deep_redact_strings(evidence)
  end

  defp deep_redact_strings(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(v) and k in ["content", :content, "description", :description] ->
        {k, redact_string(v)}

      {k, v} when is_map(v) ->
        {k, deep_redact_strings(v)}

      {k, v} when is_list(v) ->
        {k,
         Enum.map(v, fn item -> if is_map(item), do: deep_redact_strings(item), else: item end)}

      other ->
        other
    end)
  end

  defp deep_redact_strings(other), do: other

  defp maybe_apply_redaction(evidence, true), do: redact(evidence)
  defp maybe_apply_redaction(evidence, false), do: evidence

  defp maybe_strip_metadata(evidence, true), do: evidence

  defp maybe_strip_metadata(evidence, false) do
    evidence
    |> Map.delete("metadata")
    |> Map.delete(:metadata)
  end

  defp format_json(evidence) do
    case Jason.encode(evidence, pretty: true) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, {:json_encode_error, reason}}
    end
  end

  defp format_csv(evidence) do
    # Flatten evidence into rows for CSV export
    reported =
      Map.get(evidence, "reported_message") || Map.get(evidence, :reported_message) || %{}

    surrounding =
      Map.get(evidence, "surrounding_messages") || Map.get(evidence, :surrounding_messages) || []

    headers = "type,sender_id,content,timestamp\n"

    reported_row =
      "reported,#{Map.get(reported, :sender_id, "")},#{csv_escape(Map.get(reported, :content, ""))},#{Map.get(reported, :inserted_at, "")}\n"

    context_rows =
      surrounding
      |> Enum.map(fn msg ->
        "context,#{Map.get(msg, :sender_id, "")},#{csv_escape(Map.get(msg, :content, ""))},#{Map.get(msg, :inserted_at, "")}\n"
      end)
      |> Enum.join()

    {:ok, headers <> reported_row <> context_rows}
  end

  defp format_text(evidence) do
    {:ok, summarize(evidence)}
  end

  defp csv_escape(nil), do: ""

  defp csv_escape(value) when is_binary(value) do
    "\"#{String.replace(value, "\"", "\"\"")}\""
  end

  defp csv_escape(value), do: inspect(value)

  defp truncate(text, max) when is_binary(text) and byte_size(text) > max do
    String.slice(text, 0, max) <> "..."
  end

  defp truncate(text, _max), do: text
end
