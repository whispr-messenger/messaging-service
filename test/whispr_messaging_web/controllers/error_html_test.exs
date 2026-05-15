defmodule WhisprMessagingWeb.ErrorHTMLTest do
  use ExUnit.Case, async: true

  alias WhisprMessagingWeb.ErrorHTML

  test "renders 404 as plain text" do
    assert ErrorHTML.render("404.html", %{}) == "Error: Not Found"
  end

  test "renders 500 as plain text" do
    assert ErrorHTML.render("500.html", %{}) == "Error: Internal Server Error"
  end

  test "renders arbitrary templates" do
    assert ErrorHTML.render("403.html", %{}) == "Error: Forbidden"
  end
end
