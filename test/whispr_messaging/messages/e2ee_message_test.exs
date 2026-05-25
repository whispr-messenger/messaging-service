defmodule WhisprMessaging.Messages.E2eeMessageTest do
  @moduledoc """
  Tests unitaires pour les changements E2EE sur le schema Message.
  Couvre WHISPR-1480, WHISPR-1482, WHISPR-1486.
  """

  use ExUnit.Case, async: true

  alias WhisprMessaging.Messages.Message

  defp base_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        conversation_id: Ecto.UUID.generate(),
        sender_id: Ecto.UUID.generate(),
        message_type: "text",
        client_random: System.unique_integer([:positive])
      },
      overrides
    )
  end

  describe "changeset/2 - plaintext (comportement existant preserve)" do
    test "message plaintext valide avec content" do
      cs = Message.changeset(%Message{}, base_attrs(%{content: "hello"}))
      assert cs.valid?
      assert get_field(cs, :content_format) == "plaintext"
    end

    test "message plaintext sans content est invalide" do
      cs = Message.changeset(%Message{}, base_attrs())
      refute cs.valid?
      assert "can't be blank" in errors_on(cs).content
    end

    test "content_format vaut plaintext par defaut" do
      cs = Message.changeset(%Message{}, base_attrs(%{content: "hi"}))
      assert cs.valid?
      assert get_field(cs, :content_format) == "plaintext"
    end
  end

  describe "changeset/2 - olm_v1 (E2EE)" do
    test "message olm_v1 valide avec ciphertext seulement" do
      cs =
        Message.changeset(
          %Message{},
          base_attrs(%{
            content_format: "olm_v1",
            ciphertext: <<1, 2, 3, 4, 5>>
          })
        )

      assert cs.valid?
      assert get_field(cs, :ciphertext) == <<1, 2, 3, 4, 5>>
      assert get_field(cs, :content) == nil
    end

    test "message olm_v1 sans ciphertext est invalide" do
      cs =
        Message.changeset(
          %Message{},
          base_attrs(%{content_format: "olm_v1"})
        )

      refute cs.valid?
      assert "can't be blank" in errors_on(cs).ciphertext
    end

    test "message olm_v1 avec content fourni — content ignore, ciphertext requis" do
      cs =
        Message.changeset(
          %Message{},
          base_attrs(%{
            content_format: "olm_v1",
            content: "should be ignored"
          })
        )

      refute cs.valid?
      assert "can't be blank" in errors_on(cs).ciphertext
    end

    test "content_format invalide est rejete" do
      cs =
        Message.changeset(
          %Message{},
          base_attrs(%{content: "x", content_format: "unknown_format"})
        )

      refute cs.valid?
    end

    test "ciphertext trop grand est rejete" do
      # max = 65_536 + 128 = 65_664 bytes
      huge = :binary.copy(<<0>>, 70_000)

      cs =
        Message.changeset(
          %Message{},
          base_attrs(%{content_format: "olm_v1", ciphertext: huge})
        )

      refute cs.valid?
      assert Enum.any?(errors_on(cs).ciphertext, &String.contains?(&1, "exceeds"))
    end
  end

  describe "edit_changeset/3 - garde E2EE" do
    test "edition d'un message plaintext est autorisee" do
      msg = %Message{content_format: "plaintext", metadata: %{}}
      cs = Message.edit_changeset(msg, "nouveau contenu")
      assert cs.valid?
    end

    test "edition d'un message olm_v1 est interdite" do
      msg = %Message{content_format: "olm_v1", metadata: %{}}
      cs = Message.edit_changeset(msg, "tentative")
      refute cs.valid?
      assert "cannot edit an E2EE message" in errors_on(cs).content
    end
  end

  describe "schema fields" do
    test "content est nullable dans le schema" do
      # Verifie qu'on peut construire un message sans content
      msg = %Message{content: nil, content_format: "olm_v1", ciphertext: <<1, 2, 3>>}
      assert msg.content == nil
      assert msg.ciphertext == <<1, 2, 3>>
    end
  end

  # Helper extrait du module DataCase pour les tests unitaires
  defp get_field(changeset, field) do
    Ecto.Changeset.get_field(changeset, field)
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc ->
        String.replace(acc, "%{#{k}}", to_string(v))
      end)
    end)
  end
end
