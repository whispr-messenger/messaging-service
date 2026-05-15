defmodule WhisprMessagingWeb.ErrorJSONTest do
  use ExUnit.Case, async: true

  alias WhisprMessagingWeb.ErrorJSON

  test "renders 400" do
    assert ErrorJSON.render("400.json", %{}) == %{errors: %{detail: "Bad Request"}}
  end

  test "renders 401" do
    assert ErrorJSON.render("401.json", %{}) == %{errors: %{detail: "Unauthorized"}}
  end

  test "renders 403" do
    assert ErrorJSON.render("403.json", %{}) == %{errors: %{detail: "Forbidden"}}
  end

  test "renders 404" do
    assert ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Not Found"}}
  end

  test "renders 500" do
    assert ErrorJSON.render("500.json", %{}) == %{errors: %{detail: "Internal Server Error"}}
  end

  test "renders any other status via fallback" do
    result = ErrorJSON.render("422.json", %{})
    assert is_map(result)
    assert result.errors.detail =~ "Unprocessable"
  end
end
