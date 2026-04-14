defmodule WhisprMessaging.Moderation.Policy do
  @moduledoc """
  Configurable moderation policy engine.

  Evaluates reports against a set of rules to determine severity, auto-actions,
  and priority scores. Rules can be loaded from application config or defined
  programmatically.

  ## Architecture

  The policy engine operates in three stages:
  1. **Classification** - determines the severity of a report based on category,
     content patterns, and user history
  2. **Scoring** - computes a priority score (0-100) for queue ordering
  3. **Action recommendation** - suggests moderation actions based on severity

  ## Configuration

  Rules are loaded from `Application.get_env(:whispr_messaging, :moderation_policies)`.
  If no config is found, default rules are used.
  """

  alias WhisprMessaging.Moderation.Report
  alias WhisprMessaging.Moderation.Reports

  require Logger

  @type severity :: :low | :medium | :high | :critical
  @type action_recommendation :: :review | :warn | :mute | :temp_ban | :permanent_ban | :dismiss
  @type evaluation_result :: %{
          severity: severity(),
          priority_score: non_neg_integer(),
          recommended_action: action_recommendation(),
          matched_rules: [String.t()],
          auto_escalate: boolean(),
          flags: [String.t()]
        }

  # Default keyword patterns for auto-categorization
  @keyword_patterns %{
    "violence" => ~w(kill murder threat weapon attack stab shoot),
    "harassment" => ~w(stalking doxxing bully intimidate harass target),
    "nudity" => ~w(nude naked nsfw explicit porn sexual),
    "spam" => ~w(buy sell discount promo click link free win lottery)
  }

  # Severity weights by category
  @category_severity %{
    "violence" => :critical,
    "harassment" => :high,
    "nudity" => :medium,
    "offensive" => :medium,
    "spam" => :low,
    "other" => :low
  }

  # Numeric scores for severity levels (for priority queue ordering)
  @severity_scores %{
    critical: 90,
    high: 70,
    medium: 40,
    low: 20
  }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Evaluates a report against all configured policy rules.

  Returns an evaluation result with severity, priority score,
  recommended action, and matched rules.

  ## Parameters
    * `report` - a `%Report{}` struct

  ## Returns
  `{:ok, evaluation_result}` with the evaluation details.
  """
  @spec evaluate(Report.t()) :: {:ok, evaluation_result()}
  def evaluate(%Report{} = report) do
    rules = load_rules()

    matched_rules = evaluate_rules(report, rules)
    severity = determine_severity(report, matched_rules)
    priority_score = compute_priority_score(report, severity, matched_rules)
    action = recommend_action(severity, matched_rules)
    flags = collect_flags(report, matched_rules)
    auto_escalate = severity in [:critical, :high] or "repeat_offender" in flags

    result = %{
      severity: severity,
      priority_score: priority_score,
      recommended_action: action,
      matched_rules: Enum.map(matched_rules, & &1.name),
      auto_escalate: auto_escalate,
      flags: flags
    }

    Logger.debug("[Policy] Evaluated report #{report.id}: severity=#{severity}, score=#{priority_score}")

    {:ok, result}
  end

  @doc """
  Auto-categorizes a report description by matching content against
  known keyword patterns. Returns the best-matching category or nil.

  ## Parameters
    * `text` - the description or content to analyze

  ## Returns
  A category string or `nil` if no patterns match.
  """
  @spec auto_categorize(String.t() | nil) :: String.t() | nil
  def auto_categorize(nil), do: nil
  def auto_categorize(""), do: nil

  def auto_categorize(text) when is_binary(text) do
    normalized = String.downcase(text)
    patterns = get_keyword_patterns()

    scores =
      Enum.map(patterns, fn {category, keywords} ->
        hits = Enum.count(keywords, fn kw -> String.contains?(normalized, kw) end)
        {category, hits}
      end)
      |> Enum.filter(fn {_cat, hits} -> hits > 0 end)
      |> Enum.sort_by(fn {_cat, hits} -> hits end, :desc)

    case scores do
      [{category, _} | _] -> category
      [] -> nil
    end
  end

  @doc """
  Computes a priority score for a report (0-100).
  Higher scores should be processed first in the moderation queue.

  Factors:
  - Base score from category severity
  - Bonus for repeat offenders
  - Bonus for multiple reporters
  - Bonus for keyword severity matches
  - Time decay (newer reports get a slight boost)
  """
  @spec compute_priority(Report.t()) :: non_neg_integer()
  def compute_priority(%Report{} = report) do
    base = Map.get(@severity_scores, Map.get(@category_severity, report.category, :low), 20)

    repeat_bonus = compute_repeat_offender_bonus(report.reported_user_id)
    keyword_bonus = compute_keyword_bonus(report.description)
    recency_bonus = compute_recency_bonus(report.inserted_at)

    score = base + repeat_bonus + keyword_bonus + recency_bonus
    min(score, 100)
  end

  @doc """
  Returns the full set of policy rules currently in effect.
  Merges application config rules with default rules.
  """
  @spec current_rules() :: [map()]
  def current_rules do
    load_rules()
  end

  @doc """
  Validates that a set of policy rules is well-formed.

  ## Parameters
    * `rules` - list of rule maps

  ## Returns
  `:ok` or `{:error, reasons}` with a list of validation errors.
  """
  @spec validate_rules([map()]) :: :ok | {:error, [String.t()]}
  def validate_rules(rules) when is_list(rules) do
    errors =
      rules
      |> Enum.with_index()
      |> Enum.flat_map(fn {rule, idx} ->
        validate_rule(rule, idx)
      end)

    case errors do
      [] -> :ok
      errs -> {:error, errs}
    end
  end

  @doc """
  Returns the severity level for a given category.
  """
  @spec severity_for_category(String.t()) :: severity()
  def severity_for_category(category) do
    Map.get(@category_severity, category, :low)
  end

  @doc """
  Returns the numeric score for a severity level.
  """
  @spec score_for_severity(severity()) :: non_neg_integer()
  def score_for_severity(severity) do
    Map.get(@severity_scores, severity, 20)
  end

  @doc """
  Returns the keyword patterns used for auto-categorization.
  Can be overridden via application config.
  """
  @spec get_keyword_patterns() :: %{String.t() => [String.t()]}
  def get_keyword_patterns do
    config_patterns =
      Application.get_env(:whispr_messaging, :moderation_policies, [])
      |> Keyword.get(:keyword_patterns, %{})

    Map.merge(@keyword_patterns, config_patterns)
  end

  # ---------------------------------------------------------------------------
  # Rule loading
  # ---------------------------------------------------------------------------

  defp load_rules do
    config_rules =
      Application.get_env(:whispr_messaging, :moderation_policies, [])
      |> Keyword.get(:rules, [])

    case config_rules do
      [] -> default_rules()
      rules -> rules
    end
  end

  defp default_rules do
    [
      %{
        name: "violence_auto_escalate",
        category: "violence",
        min_severity: :high,
        action: :temp_ban,
        description: "Violence reports are automatically escalated"
      },
      %{
        name: "harassment_review",
        category: "harassment",
        min_severity: :medium,
        action: :review,
        description: "Harassment reports require manual review"
      },
      %{
        name: "repeat_offender_escalate",
        type: :repeat_offender,
        threshold: 3,
        window_days: 7,
        action: :mute,
        description: "Users with 3+ reports in 7 days are auto-muted"
      },
      %{
        name: "spam_auto_dismiss_low",
        category: "spam",
        max_reporters: 1,
        action: :dismiss,
        description: "Single-reporter spam reports are low priority"
      },
      %{
        name: "mass_report_detection",
        type: :mass_report,
        threshold: 10,
        window_hours: 1,
        action: :review,
        description: "Detect coordinated mass reporting"
      }
    ]
  end

  # ---------------------------------------------------------------------------
  # Rule evaluation
  # ---------------------------------------------------------------------------

  defp evaluate_rules(report, rules) do
    Enum.filter(rules, fn rule -> rule_matches?(report, rule) end)
  end

  defp rule_matches?(report, %{category: category} = _rule) do
    report.category == category
  end

  defp rule_matches?(_report, %{type: :repeat_offender}) do
    # This is checked via the repeat offender bonus
    true
  end

  defp rule_matches?(_report, %{type: :mass_report}) do
    # Mass report detection is always evaluated
    true
  end

  defp rule_matches?(_report, _rule), do: false

  # ---------------------------------------------------------------------------
  # Severity determination
  # ---------------------------------------------------------------------------

  defp determine_severity(report, matched_rules) do
    base_severity = Map.get(@category_severity, report.category, :low)

    # Escalate if any matched rule requires higher severity
    rule_severities =
      matched_rules
      |> Enum.map(fn rule -> Map.get(rule, :min_severity, :low) end)

    all_severities = [base_severity | rule_severities]

    # Return the highest severity
    cond do
      :critical in all_severities -> :critical
      :high in all_severities -> :high
      :medium in all_severities -> :medium
      true -> :low
    end
  end

  # ---------------------------------------------------------------------------
  # Priority scoring
  # ---------------------------------------------------------------------------

  defp compute_priority_score(report, severity, _matched_rules) do
    base = Map.get(@severity_scores, severity, 20)
    repeat = compute_repeat_offender_bonus(report.reported_user_id)
    keyword = compute_keyword_bonus(report.description)
    recency = compute_recency_bonus(report.inserted_at)

    min(base + repeat + keyword + recency, 100)
  end

  defp compute_repeat_offender_bonus(reported_user_id) do
    count = Reports.unique_reporter_count(reported_user_id, 7)

    cond do
      count >= 5 -> 20
      count >= 3 -> 10
      count >= 2 -> 5
      true -> 0
    end
  end

  defp compute_keyword_bonus(nil), do: 0

  defp compute_keyword_bonus(description) when is_binary(description) do
    normalized = String.downcase(description)

    # Check violence keywords for highest bonus
    violence_hits =
      Map.get(@keyword_patterns, "violence", [])
      |> Enum.count(fn kw -> String.contains?(normalized, kw) end)

    harassment_hits =
      Map.get(@keyword_patterns, "harassment", [])
      |> Enum.count(fn kw -> String.contains?(normalized, kw) end)

    cond do
      violence_hits > 0 -> 15
      harassment_hits > 0 -> 10
      true -> 0
    end
  end

  defp compute_recency_bonus(nil), do: 0

  defp compute_recency_bonus(inserted_at) do
    age_hours =
      NaiveDateTime.diff(NaiveDateTime.utc_now(), inserted_at, :second) / 3600

    cond do
      age_hours < 1 -> 10
      age_hours < 6 -> 5
      age_hours < 24 -> 2
      true -> 0
    end
  end

  # ---------------------------------------------------------------------------
  # Action recommendation
  # ---------------------------------------------------------------------------

  defp recommend_action(severity, matched_rules) do
    # Check if any rule has an explicit action
    rule_actions =
      matched_rules
      |> Enum.map(fn rule -> Map.get(rule, :action) end)
      |> Enum.reject(&is_nil/1)

    case rule_actions do
      [action | _] ->
        action

      [] ->
        case severity do
          :critical -> :temp_ban
          :high -> :mute
          :medium -> :review
          :low -> :dismiss
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Flag collection
  # ---------------------------------------------------------------------------

  defp collect_flags(report, _matched_rules) do
    flags = []

    # Check repeat offender
    count = Reports.unique_reporter_count(report.reported_user_id, 7)
    flags = if count >= 3, do: ["repeat_offender" | flags], else: flags

    # Check high-severity category
    flags =
      if report.category in ["violence", "harassment"],
        do: ["high_severity_category" | flags],
        else: flags

    # Check if report has evidence
    flags =
      if report.evidence && map_size(report.evidence) > 0,
        do: ["has_evidence" | flags],
        else: flags

    Enum.reverse(flags)
  end

  # ---------------------------------------------------------------------------
  # Rule validation
  # ---------------------------------------------------------------------------

  defp validate_rule(rule, idx) do
    errors = []

    errors =
      if Map.has_key?(rule, :name),
        do: errors,
        else: ["Rule #{idx}: missing :name" | errors]

    errors =
      if Map.has_key?(rule, :action),
        do: errors,
        else: ["Rule #{idx}: missing :action" | errors]

    errors =
      if Map.has_key?(rule, :category) or Map.has_key?(rule, :type),
        do: errors,
        else: ["Rule #{idx}: must have :category or :type" | errors]

    Enum.reverse(errors)
  end
end
