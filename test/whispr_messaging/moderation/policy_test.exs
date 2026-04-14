defmodule WhisprMessaging.Moderation.PolicyTest do
  use WhisprMessaging.DataCase, async: true

  alias WhisprMessaging.Moderation.{Policy, Reports}

  setup do
    reporter_id = create_test_user_id()
    reported_user_id = create_test_user_id()

    %{
      reporter_id: reporter_id,
      reported_user_id: reported_user_id
    }
  end

  defp create_report(reporter_id, reported_user_id, attrs \\ %{}) do
    default = %{
      reporter_id: reporter_id,
      reported_user_id: reported_user_id,
      category: "spam"
    }

    {:ok, report} = Reports.create_report(Map.merge(default, attrs))
    report
  end

  describe "evaluate/1" do
    test "evaluates a spam report as low severity", ctx do
      report = create_report(ctx.reporter_id, ctx.reported_user_id, %{category: "spam"})
      {:ok, result} = Policy.evaluate(report)

      assert result.severity == :low
      assert result.priority_score >= 0
      assert result.priority_score <= 100
      assert is_atom(result.recommended_action)
      assert is_list(result.matched_rules)
      assert is_boolean(result.auto_escalate)
      assert is_list(result.flags)
    end

    test "evaluates violence report as critical severity", ctx do
      report = create_report(ctx.reporter_id, ctx.reported_user_id, %{category: "violence"})
      {:ok, result} = Policy.evaluate(report)

      assert result.severity == :critical
      assert result.priority_score >= 70
      assert result.auto_escalate == true
      assert "high_severity_category" in result.flags
    end

    test "evaluates harassment report as high severity", ctx do
      report =
        create_report(ctx.reporter_id, ctx.reported_user_id, %{category: "harassment"})

      {:ok, result} = Policy.evaluate(report)

      assert result.severity in [:high, :medium]
      assert "high_severity_category" in result.flags
    end

    test "flags repeat offenders", ctx do
      # Create 3 reports from unique reporters against the same user
      for _ <- 1..3 do
        reporter = create_test_user_id()
        create_report(reporter, ctx.reported_user_id, %{category: "spam"})
      end

      report = create_report(create_test_user_id(), ctx.reported_user_id, %{category: "spam"})
      {:ok, result} = Policy.evaluate(report)

      assert "repeat_offender" in result.flags
    end

    test "flags reports with evidence", ctx do
      conversation = create_test_conversation()

      Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)
      message = create_test_message(conversation.id, ctx.reported_user_id)
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      report =
        create_report(ctx.reporter_id, ctx.reported_user_id, %{
          category: "spam",
          conversation_id: conversation.id,
          message_id: message.id
        })

      {:ok, result} = Policy.evaluate(report)
      assert "has_evidence" in result.flags
    end
  end

  describe "auto_categorize/1" do
    test "categorizes violence-related text" do
      assert Policy.auto_categorize("I will kill you and attack your family") == "violence"
    end

    test "categorizes harassment-related text" do
      assert Policy.auto_categorize("stop stalking me, this is bullying") == "harassment"
    end

    test "categorizes nudity-related text" do
      assert Policy.auto_categorize("sending explicit nude photos") == "nudity"
    end

    test "categorizes spam-related text" do
      assert Policy.auto_categorize("buy now! free discount click this link") == "spam"
    end

    test "returns nil for unrecognizable text" do
      assert Policy.auto_categorize("hello how are you today") == nil
    end

    test "returns nil for nil input" do
      assert Policy.auto_categorize(nil) == nil
    end

    test "returns nil for empty string" do
      assert Policy.auto_categorize("") == nil
    end

    test "is case insensitive" do
      assert Policy.auto_categorize("I WILL KILL YOU") == "violence"
    end
  end

  describe "compute_priority/1" do
    test "violence reports have higher priority than spam", ctx do
      violence = create_report(ctx.reporter_id, ctx.reported_user_id, %{category: "violence"})
      spam_reporter = create_test_user_id()
      spam = create_report(spam_reporter, create_test_user_id(), %{category: "spam"})

      violence_score = Policy.compute_priority(violence)
      spam_score = Policy.compute_priority(spam)

      assert violence_score > spam_score
    end

    test "scores are capped at 100", ctx do
      report = create_report(ctx.reporter_id, ctx.reported_user_id, %{
        category: "violence",
        description: "kill murder threat weapon attack stab shoot"
      })

      score = Policy.compute_priority(report)
      assert score <= 100
    end

    test "description with violence keywords adds bonus", ctx do
      plain = create_report(ctx.reporter_id, ctx.reported_user_id, %{
        category: "other",
        description: "something happened"
      })

      violent = create_report(create_test_user_id(), create_test_user_id(), %{
        category: "other",
        description: "threat to kill someone"
      })

      assert Policy.compute_priority(violent) > Policy.compute_priority(plain)
    end
  end

  describe "current_rules/0" do
    test "returns a non-empty list of rules" do
      rules = Policy.current_rules()
      assert is_list(rules)
      assert length(rules) > 0

      Enum.each(rules, fn rule ->
        assert Map.has_key?(rule, :name)
        assert Map.has_key?(rule, :action)
      end)
    end
  end

  describe "validate_rules/1" do
    test "validates well-formed rules" do
      rules = [
        %{name: "test_rule", category: "spam", action: :dismiss},
        %{name: "test_rule_2", type: :repeat_offender, action: :mute}
      ]

      assert :ok = Policy.validate_rules(rules)
    end

    test "rejects rules missing name" do
      rules = [%{category: "spam", action: :dismiss}]
      assert {:error, errors} = Policy.validate_rules(rules)
      assert Enum.any?(errors, &String.contains?(&1, "missing :name"))
    end

    test "rejects rules missing action" do
      rules = [%{name: "test", category: "spam"}]
      assert {:error, errors} = Policy.validate_rules(rules)
      assert Enum.any?(errors, &String.contains?(&1, "missing :action"))
    end

    test "rejects rules missing both category and type" do
      rules = [%{name: "test", action: :dismiss}]
      assert {:error, errors} = Policy.validate_rules(rules)
      assert Enum.any?(errors, &String.contains?(&1, ":category or :type"))
    end
  end

  describe "severity_for_category/1" do
    test "returns correct severities" do
      assert Policy.severity_for_category("violence") == :critical
      assert Policy.severity_for_category("harassment") == :high
      assert Policy.severity_for_category("nudity") == :medium
      assert Policy.severity_for_category("spam") == :low
      assert Policy.severity_for_category("other") == :low
      assert Policy.severity_for_category("unknown") == :low
    end
  end

  describe "score_for_severity/1" do
    test "returns correct scores" do
      assert Policy.score_for_severity(:critical) == 90
      assert Policy.score_for_severity(:high) == 70
      assert Policy.score_for_severity(:medium) == 40
      assert Policy.score_for_severity(:low) == 20
    end
  end

  describe "evaluate/1 with custom config rules" do
    test "custom rules from application config override defaults", ctx do
      # Temporarily set custom rules in application config
      original = Application.get_env(:whispr_messaging, :moderation_policies, [])

      custom_rules = [
        rules: [
          %{
            name: "custom_spam_rule",
            category: "spam",
            action: :warn,
            min_severity: :high,
            description: "Custom spam handling"
          }
        ]
      ]

      Application.put_env(:whispr_messaging, :moderation_policies, custom_rules)

      report = create_report(ctx.reporter_id, ctx.reported_user_id, %{category: "spam"})
      {:ok, result} = Policy.evaluate(report)

      assert "custom_spam_rule" in result.matched_rules
      assert result.recommended_action == :warn

      # Restore original config
      Application.put_env(:whispr_messaging, :moderation_policies, original)
    end
  end

  describe "get_keyword_patterns/0" do
    test "returns a map of category => keywords" do
      patterns = Policy.get_keyword_patterns()
      assert is_map(patterns)
      assert Map.has_key?(patterns, "violence")
      assert Map.has_key?(patterns, "harassment")
      assert Map.has_key?(patterns, "nudity")
      assert Map.has_key?(patterns, "spam")

      Enum.each(patterns, fn {_cat, keywords} ->
        assert is_list(keywords)
        assert length(keywords) > 0
      end)
    end
  end
end
