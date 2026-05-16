defmodule WhisprMessagingWeb.ParamHelpersTest do
  @moduledoc """
  Unit tests for the shared query-string parsing helpers used by controllers.
  """
  use ExUnit.Case, async: true

  alias WhisprMessagingWeb.ParamHelpers

  describe "parse_bounded_int/4" do
    test "nil → default" do
      assert ParamHelpers.parse_bounded_int(nil, 10, 0, 100) == 10
    end

    test "string in range → integer" do
      assert ParamHelpers.parse_bounded_int("42", 0, 0, 100) == 42
    end

    test "string below range → clamps to min" do
      assert ParamHelpers.parse_bounded_int("-5", 0, 0, 100) == 0
    end

    test "string above range → clamps to max" do
      assert ParamHelpers.parse_bounded_int("9999", 0, 0, 100) == 100
    end

    test "unparseable string → default" do
      assert ParamHelpers.parse_bounded_int("nope", 7, 0, 100) == 7
    end

    test "integer in range → integer" do
      assert ParamHelpers.parse_bounded_int(42, 0, 0, 100) == 42
    end

    test "integer below range → clamps to min" do
      assert ParamHelpers.parse_bounded_int(-1, 0, 5, 100) == 5
    end

    test "integer above range → clamps to max" do
      assert ParamHelpers.parse_bounded_int(999, 0, 0, 100) == 100
    end

    test "other type → default" do
      assert ParamHelpers.parse_bounded_int(:atom, 13, 0, 100) == 13
      assert ParamHelpers.parse_bounded_int(%{}, 13, 0, 100) == 13
    end
  end

  describe "parse_optional_int/1" do
    test "nil → nil" do
      assert ParamHelpers.parse_optional_int(nil) == nil
    end

    test "parseable string → integer" do
      assert ParamHelpers.parse_optional_int("17") == 17
    end

    test "unparseable string → nil" do
      assert ParamHelpers.parse_optional_int("nope") == nil
    end

    test "integer → integer" do
      assert ParamHelpers.parse_optional_int(42) == 42
    end

    test "other type → nil" do
      assert ParamHelpers.parse_optional_int(:atom) == nil
      assert ParamHelpers.parse_optional_int(%{}) == nil
    end
  end

  describe "maybe_add_opt/3" do
    test "nil value: opts unchanged" do
      assert ParamHelpers.maybe_add_opt([a: 1], :b, nil) == [a: 1]
    end

    test "concrete value: opts include the new pair" do
      assert ParamHelpers.maybe_add_opt([a: 1], :b, 2) == [b: 2, a: 1]
    end

    test "starts from empty opts" do
      assert ParamHelpers.maybe_add_opt([], :k, "v") == [k: "v"]
    end
  end

  describe "parse_int_value/1" do
    test "nil → :error" do
      assert ParamHelpers.parse_int_value(nil) == :error
    end

    test "integer → {:ok, n}" do
      assert ParamHelpers.parse_int_value(42) == {:ok, 42}
    end

    test "clean int string → {:ok, n}" do
      assert ParamHelpers.parse_int_value("17") == {:ok, 17}
    end

    test "trailing garbage → :error (strict)" do
      assert ParamHelpers.parse_int_value("17abc") == :error
    end

    test "non-int string → :error" do
      assert ParamHelpers.parse_int_value("abc") == :error
    end

    test "other types → :error" do
      assert ParamHelpers.parse_int_value(:atom) == :error
      assert ParamHelpers.parse_int_value(%{}) == :error
      assert ParamHelpers.parse_int_value([1, 2]) == :error
    end
  end

  describe "parse_int_with_opts/3" do
    test "uses defaults when opts is empty" do
      assert ParamHelpers.parse_int_with_opts("42", 0, []) == 42
    end

    test "respects :min option (out-of-range below → default)" do
      assert ParamHelpers.parse_int_with_opts("5", 100, min: 10) == 100
    end

    test "respects :max option (clamps from above)" do
      assert ParamHelpers.parse_int_with_opts("99", 0, max: 50) == 50
    end

    test "valid value within bounds passes through" do
      assert ParamHelpers.parse_int_with_opts("42", 0, min: 0, max: 100) == 42
    end

    test "non-parseable input → default" do
      assert ParamHelpers.parse_int_with_opts("abc", 7, min: 0, max: 100) == 7
    end

    test "nil → default" do
      assert ParamHelpers.parse_int_with_opts(nil, 7, []) == 7
    end

    test "integer input is also accepted" do
      assert ParamHelpers.parse_int_with_opts(42, 0, max: 100) == 42
    end
  end
end
