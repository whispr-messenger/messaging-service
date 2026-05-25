defmodule WhisprMessaging.Conversations.E2eeConversationTest do
  @moduledoc """
  Tests unitaires pour e2ee_changeset sur Conversation.
  Couvre WHISPR-1481.
  """

  use ExUnit.Case, async: true

  alias WhisprMessaging.Conversations.Conversation

  describe "e2ee_changeset/2" do
    test "active E2EE sur une conv directe" do
      conv = %Conversation{type: "direct", e2ee_enabled: false}
      cs = Conversation.e2ee_changeset(conv, %{e2ee_enabled: true})
      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :e2ee_enabled) == true
    end

    test "desactive E2EE sur une conv directe" do
      conv = %Conversation{type: "direct", e2ee_enabled: true}
      cs = Conversation.e2ee_changeset(conv, %{e2ee_enabled: false})
      assert cs.valid?
    end

    test "rejette E2EE sur une conv de groupe" do
      conv = %Conversation{type: "group", e2ee_enabled: false}
      cs = Conversation.e2ee_changeset(conv, %{e2ee_enabled: true})
      refute cs.valid?

      errors =
        Ecto.Changeset.traverse_errors(cs, fn {msg, _opts} -> msg end)

      assert "E2EE is only supported on direct conversations" in errors.e2ee_enabled
    end

    test "e2ee_enabled doit etre un boolean (pas une string)" do
      conv = %Conversation{type: "direct", e2ee_enabled: false}
      cs = Conversation.e2ee_changeset(conv, %{e2ee_enabled: "not_a_bool"})
      # Ecto cast un boolean depuis string "true"/"false" mais pas n'importe quelle string
      # "not_a_bool" -> cast failure -> champ absent -> validate_required echoue
      refute cs.valid?
    end
  end
end
