defmodule WhisprMessaging.Moderation.EvidenceTest do
  use WhisprMessaging.DataCase, async: true

  alias WhisprMessaging.Moderation.{Evidence, Reports}

  setup do
    reporter_id = create_test_user_id()
    reported_user_id = create_test_user_id()
    conversation = create_test_conversation()

    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)
    message = create_test_message(conversation.id, reported_user_id)

    # Create some surrounding messages for context
    for i <- 1..3 do
      create_test_message(conversation.id, reporter_id, %{
        content: "context message #{i}",
        client_random: System.unique_integer([:positive])
      })
    end

    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    %{
      reporter_id: reporter_id,
      reported_user_id: reported_user_id,
      conversation: conversation,
      message: message
    }
  end

  describe "capture_full_context/2" do
    test "captures the reported message and surrounding context", ctx do
      {:ok, snapshot} = Evidence.capture_full_context(ctx.message.id, ctx.conversation.id)

      assert snapshot.reported_message != nil
      assert snapshot.reported_message.id == ctx.message.id
      assert snapshot.reported_message.sender_id == ctx.reported_user_id
      assert is_list(snapshot.surrounding_messages)
      assert snapshot.surrounding_messages != []
      assert snapshot.conversation_context.conversation_id == ctx.conversation.id
      assert snapshot.conversation_context.total_messages >= 1
      assert is_binary(snapshot.captured_at)
      assert snapshot.metadata.capture_version == "2.0"
    end

    test "returns error for non-existent message", ctx do
      fake_id = Ecto.UUID.generate()

      assert {:error, :message_not_found} =
               Evidence.capture_full_context(fake_id, ctx.conversation.id)
    end
  end

  describe "capture_minimal/1" do
    test "captures just the reported message without context", ctx do
      {:ok, snapshot} = Evidence.capture_minimal(ctx.message.id)

      assert snapshot.reported_message != nil
      assert snapshot.reported_message.id == ctx.message.id
      assert snapshot.surrounding_messages == []
      assert snapshot.metadata.minimal == true
    end

    test "returns error for non-existent message" do
      assert {:error, :message_not_found} = Evidence.capture_minimal(Ecto.UUID.generate())
    end
  end

  describe "enrich_evidence/1" do
    test "enriches a report's evidence with full context", ctx do
      {:ok, report} =
        Reports.create_report(%{
          reporter_id: ctx.reporter_id,
          reported_user_id: ctx.reported_user_id,
          conversation_id: ctx.conversation.id,
          message_id: ctx.message.id,
          category: "spam"
        })

      {:ok, enriched} = Evidence.enrich_evidence(report)

      assert Map.has_key?(enriched, "surrounding_messages")
      assert Map.has_key?(enriched, "conversation_context")
      assert Map.has_key?(enriched, "enriched_at")
    end

    test "returns error when report has no message context" do
      {:ok, report} =
        Reports.create_report(%{
          reporter_id: create_test_user_id(),
          reported_user_id: create_test_user_id(),
          category: "spam"
        })

      assert {:error, :no_message_context} = Evidence.enrich_evidence(report)
    end
  end

  describe "redact/2" do
    test "redacts sensitive fields" do
      evidence = %{
        "content" => "test content",
        "email" => "user@example.com",
        "phone" => "+1234567890",
        "ip_address" => "192.168.1.1"
      }

      redacted = Evidence.redact(evidence)
      assert redacted["email"] == "[REDACTED]"
      assert redacted["phone"] == "[REDACTED]"
      assert redacted["ip_address"] == "[REDACTED]"
    end

    test "redacts emails and phones in content strings" do
      evidence = %{
        "content" => "Contact me at user@example.com or +1-555-123-4567"
      }

      redacted = Evidence.redact(evidence)
      refute String.contains?(redacted["content"], "user@example.com")
      assert String.contains?(redacted["content"], "[EMAIL REDACTED]")
    end

    test "handles nested maps" do
      evidence = %{
        "reported_message" => %{
          "content" => "my email is test@test.com",
          "email" => "nested@email.com"
        }
      }

      redacted = Evidence.redact(evidence)
      assert redacted["reported_message"]["email"] == "[REDACTED]"
    end

    test "handles additional custom fields" do
      evidence = %{"custom_field" => "secret"}

      redacted = Evidence.redact(evidence, fields: ["custom_field"])
      assert redacted["custom_field"] == "[REDACTED]"
    end
  end

  describe "redact_string/1" do
    test "redacts email addresses" do
      assert Evidence.redact_string("email: user@example.com") =~
               "[EMAIL REDACTED]"
    end

    test "redacts phone numbers" do
      assert Evidence.redact_string("call +1-555-123-4567") =~
               "[PHONE REDACTED]"
    end

    test "passes through non-string values" do
      assert Evidence.redact_string(42) == 42
      assert Evidence.redact_string(nil) == nil
    end
  end

  describe "format_for_export/3" do
    test "exports as JSON", ctx do
      {:ok, snapshot} = Evidence.capture_minimal(ctx.message.id)
      {:ok, json} = Evidence.format_for_export(snapshot, :json)

      assert is_binary(json)
      assert {:ok, _} = Jason.decode(json)
    end

    test "exports as CSV", ctx do
      {:ok, snapshot} = Evidence.capture_minimal(ctx.message.id)
      {:ok, csv} = Evidence.format_for_export(snapshot, :csv, redact: false)

      assert is_binary(csv)
      assert String.contains?(csv, "type,sender_id,content,timestamp")
      assert String.contains?(csv, "reported")
    end

    test "exports as text", ctx do
      {:ok, snapshot} = Evidence.capture_minimal(ctx.message.id)
      {:ok, text} = Evidence.format_for_export(snapshot, :text)

      assert is_binary(text)
      assert String.contains?(text, "Evidence Summary")
    end

    test "returns error for unsupported format", ctx do
      {:ok, snapshot} = Evidence.capture_minimal(ctx.message.id)
      assert {:error, :unsupported_format} = Evidence.format_for_export(snapshot, :xml)
    end

    test "applies redaction by default", ctx do
      {:ok, snapshot} = Evidence.capture_minimal(ctx.message.id)
      {:ok, _json} = Evidence.format_for_export(snapshot, :json)
      # Should not error
    end

    test "skips redaction when disabled", ctx do
      {:ok, snapshot} = Evidence.capture_minimal(ctx.message.id)
      {:ok, json} = Evidence.format_for_export(snapshot, :json, redact: false)
      assert is_binary(json)
    end

    test "strips metadata when include_metadata is false", ctx do
      {:ok, snapshot} = Evidence.capture_minimal(ctx.message.id)

      {:ok, json} =
        Evidence.format_for_export(snapshot, :json,
          redact: false,
          include_metadata: false
        )

      decoded = Jason.decode!(json)
      refute Map.has_key?(decoded, "metadata")
    end

    test "includes metadata by default", ctx do
      {:ok, snapshot} = Evidence.capture_minimal(ctx.message.id)
      {:ok, json} = Evidence.format_for_export(snapshot, :json, redact: false)
      decoded = Jason.decode!(json)
      assert Map.has_key?(decoded, "metadata")
    end
  end

  describe "summarize/1" do
    test "produces a readable summary", ctx do
      {:ok, snapshot} = Evidence.capture_minimal(ctx.message.id)
      summary = Evidence.summarize(snapshot)

      assert is_binary(summary)
      assert String.contains?(summary, "Evidence Summary")
      assert String.contains?(summary, "Sender:")
      assert String.contains?(summary, "Context messages:")
    end

    test "handles empty evidence" do
      summary = Evidence.summarize(%{})
      assert String.contains?(summary, "Evidence Summary")
      assert String.contains?(summary, "N/A")
    end
  end

  describe "batch_capture/1" do
    test "captures evidence for multiple reports", ctx do
      {:ok, report} =
        Reports.create_report(%{
          reporter_id: ctx.reporter_id,
          reported_user_id: ctx.reported_user_id,
          conversation_id: ctx.conversation.id,
          message_id: ctx.message.id,
          category: "spam"
        })

      {:ok, report_no_msg} =
        Reports.create_report(%{
          reporter_id: create_test_user_id(),
          reported_user_id: create_test_user_id(),
          category: "harassment"
        })

      results = Evidence.batch_capture([report, report_no_msg])

      assert Enum.count(results) == 2

      {_id1, result1} = Enum.find(results, fn {id, _} -> id == report.id end)
      assert match?({:ok, _}, result1)

      {_id2, result2} = Enum.find(results, fn {id, _} -> id == report_no_msg.id end)
      assert result2 == {:error, :no_message_context}
    end
  end
end
