defmodule WhisprMessagingWeb.GettextTest do
  use ExUnit.Case, async: true

  test "default_locale/0 returns 'en'" do
    assert WhisprMessagingWeb.Gettext.default_locale() == "en"
  end
end
