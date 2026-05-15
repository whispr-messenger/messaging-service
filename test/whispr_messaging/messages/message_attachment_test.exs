defmodule WhisprMessaging.Messages.MessageAttachmentTest do
  use ExUnit.Case, async: true

  alias WhisprMessaging.Messages.MessageAttachment

  defp build(attrs \\ %{}) do
    base = %MessageAttachment{
      id: Ecto.UUID.generate(),
      message_id: Ecto.UUID.generate(),
      filename: "photo.png",
      file_type: "image",
      file_size: 2048,
      mime_type: "image/png",
      storage_url: "https://cdn/photo.png",
      thumbnail_url: nil,
      metadata: %{},
      is_deleted: false
    }

    struct(base, attrs)
  end

  describe "changeset/2" do
    test "requires the mandatory fields" do
      cs = MessageAttachment.changeset(%MessageAttachment{}, %{})
      refute cs.valid?

      errors = errors_on(cs)
      assert "can't be blank" in errors.message_id
      assert "can't be blank" in errors.filename
      assert "can't be blank" in errors.file_type
      assert "can't be blank" in errors.file_size
      assert "can't be blank" in errors.mime_type
      assert "can't be blank" in errors.storage_url
    end

    test "rejects an invalid file_type" do
      cs =
        MessageAttachment.changeset(%MessageAttachment{}, %{
          message_id: Ecto.UUID.generate(),
          filename: "a.bin",
          file_type: "totally-unknown",
          file_size: 1,
          mime_type: "application/octet-stream",
          storage_url: "/x"
        })

      refute cs.valid?
      assert errors_on(cs).file_type |> Enum.any?(&(&1 =~ "is invalid"))
    end

    test "rejects negative file_size" do
      cs =
        MessageAttachment.changeset(%MessageAttachment{}, %{
          message_id: Ecto.UUID.generate(),
          filename: "a.bin",
          file_type: "document",
          file_size: 0,
          mime_type: "text/plain",
          storage_url: "/x"
        })

      refute cs.valid?
      assert "must be greater than 0" in errors_on(cs).file_size
    end

    test "rejects a filename longer than 255 chars" do
      long = String.duplicate("a", 256) <> ".txt"

      cs =
        MessageAttachment.changeset(%MessageAttachment{}, %{
          message_id: Ecto.UUID.generate(),
          filename: long,
          file_type: "document",
          file_size: 5,
          mime_type: "text/plain",
          storage_url: "/x"
        })

      refute cs.valid?
      assert errors_on(cs).filename |> Enum.any?(&(&1 =~ "should be at most"))
    end

    test "accepts valid input and is valid?" do
      cs =
        MessageAttachment.changeset(%MessageAttachment{}, %{
          message_id: Ecto.UUID.generate(),
          filename: "doc.pdf",
          file_type: "document",
          file_size: 1024,
          mime_type: "application/pdf",
          storage_url: "/uploads/doc.pdf"
        })

      assert cs.valid?
    end
  end

  describe "type predicates" do
    test "image?/1" do
      assert MessageAttachment.image?(build(file_type: "image"))
      refute MessageAttachment.image?(build(file_type: "video"))
      refute MessageAttachment.image?("not a struct")
    end

    test "video?/1" do
      assert MessageAttachment.video?(build(file_type: "video"))
      refute MessageAttachment.video?(build(file_type: "image"))
    end

    test "audio?/1" do
      assert MessageAttachment.audio?(build(file_type: "audio"))
      refute MessageAttachment.audio?(build(file_type: "image"))
    end

    test "document?/1" do
      assert MessageAttachment.document?(build(file_type: "document"))
      refute MessageAttachment.document?(build(file_type: "image"))
    end
  end

  describe "thumbnail and display helpers" do
    test "has_thumbnail? is false for nil and empty string" do
      refute MessageAttachment.has_thumbnail?(build(thumbnail_url: nil))
      refute MessageAttachment.has_thumbnail?(build(thumbnail_url: ""))
    end

    test "has_thumbnail? is true for any non-empty value" do
      assert MessageAttachment.has_thumbnail?(build(thumbnail_url: "/thumb.png"))
    end

    test "display_name strips extension" do
      assert MessageAttachment.display_name(build(filename: "photo.heic")) == "photo"
    end

    test "file_extension extracts extension" do
      assert MessageAttachment.file_extension(build(filename: "photo.heic")) == ".heic"
      assert MessageAttachment.file_extension(build(filename: "no_ext")) == ""
    end
  end

  describe "human_file_size/1" do
    test "formats in B / KB / MB / GB" do
      assert MessageAttachment.human_file_size(512) == "512 B"
      assert MessageAttachment.human_file_size(1024) == "1.0 KB"
      assert MessageAttachment.human_file_size(1_048_576) == "1.0 MB"
      assert MessageAttachment.human_file_size(1_073_741_824) == "1.0 GB"
    end

    test "accepts a struct via human_file_size/1" do
      assert MessageAttachment.human_file_size(build(file_size: 2048)) == "2.0 KB"
    end
  end

  describe "metadata helpers" do
    test "get_metadata returns the value or default" do
      a = build(metadata: %{"key" => "value"})
      assert MessageAttachment.get_metadata(a, "key") == "value"
      assert MessageAttachment.get_metadata(a, "missing", :default) == :default
    end

    test "put_metadata stores a new key" do
      a = build(metadata: %{})
      updated = MessageAttachment.put_metadata(a, "key", "value")
      assert updated.metadata == %{"key" => "value"}
    end
  end

  describe "deleted?/1" do
    test "matches the is_deleted field" do
      refute MessageAttachment.deleted?(build(is_deleted: false))
      assert MessageAttachment.deleted?(build(is_deleted: true))
    end
  end

  describe "dimensions and durations" do
    test "image_dimensions returns {w, h} when both are integers" do
      a = build(file_type: "image", metadata: %{"width" => 100, "height" => 200})
      assert MessageAttachment.image_dimensions(a) == {100, 200}
    end

    test "image_dimensions returns nil when missing or wrong type" do
      assert MessageAttachment.image_dimensions(build(file_type: "image", metadata: %{})) == nil
      assert MessageAttachment.image_dimensions(build(file_type: "video", metadata: %{})) == nil
    end

    test "video_duration returns the numeric value" do
      assert MessageAttachment.video_duration(
               build(file_type: "video", metadata: %{"duration" => 12.5})
             ) == 12.5

      assert MessageAttachment.video_duration(build(file_type: "video", metadata: %{})) == nil
      assert MessageAttachment.video_duration(build(file_type: "image", metadata: %{})) == nil
    end

    test "audio_duration returns the numeric value" do
      assert MessageAttachment.audio_duration(
               build(file_type: "audio", metadata: %{"duration" => 3})
             ) == 3

      assert MessageAttachment.audio_duration(build(file_type: "audio", metadata: %{})) == nil
    end
  end

  describe "requires_processing?/1" do
    test "true for image and video" do
      assert MessageAttachment.requires_processing?(build(file_type: "image"))
      assert MessageAttachment.requires_processing?(build(file_type: "video"))
    end

    test "false for audio and document" do
      refute MessageAttachment.requires_processing?(build(file_type: "audio"))
      refute MessageAttachment.requires_processing?(build(file_type: "document"))
    end
  end

  describe "get_secure_url/1" do
    test "returns a map describing the storage URL and a 1h-from-now expiry" do
      result = MessageAttachment.get_secure_url(build(storage_url: "/x"))
      assert result.url == "/x"
      assert result.requires_encryption_key == false
      assert %DateTime{} = result.expires_at
    end

    test "marks requires_encryption_key when an encryption_key is set" do
      result = MessageAttachment.get_secure_url(build(encryption_key: <<1, 2, 3>>))
      assert result.requires_encryption_key == true
    end
  end

  # Convert changeset errors into a map of lists (mimics DataCase.errors_on/1)
  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
