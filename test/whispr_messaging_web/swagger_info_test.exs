defmodule WhisprMessagingWeb.SwaggerInfoTest do
  use ExUnit.Case, async: true

  alias WhisprMessagingWeb.SwaggerInfo

  test "swagger_info returns a 2.0 document with the messaging-service metadata" do
    info = SwaggerInfo.swagger_info()

    assert info.swagger == "2.0"
    assert info.basePath == "/messaging/api/v1"
    assert info.info.title =~ "Messaging"
    assert info.info.version == "1.0.0"
    assert "http" in info.schemes
    assert "https" in info.schemes
    assert info.securityDefinitions[:Bearer].type == "apiKey"
  end
end
