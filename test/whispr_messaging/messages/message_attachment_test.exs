defmodule WhisprMessaging.Messages.MessageAttachmentTest do
  @moduledoc """
  Schema-level tests for MessageAttachment: changeset validations and
  the suite of helper predicates / accessors.
  """

  use ExUnit.Case, async: true

  alias WhisprMessaging.Messages.MessageAttachment

  defp valid_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        message_id: Ecto.UUID.generate(),
        filename: "doc.pdf",
        file_type: "document",
        mime_type: "application/pdf",
        file_size: 1024,
        storage_url: "/uploads/doc.pdf"
      },
      overrides
    )
  end

  describe "changeset/2" do
    test "is valid with the required fields" do
      changeset = MessageAttachment.changeset(%MessageAttachment{}, valid_attrs())
      assert changeset.valid?
    end

    test "is invalid when required fields are missing" do
      changeset = MessageAttachment.changeset(%MessageAttachment{}, %{})
      refute changeset.valid?

      missing_fields =
        for {field, _} <- changeset.errors, do: field

      assert :message_id in missing_fields
      assert :filename in missing_fields
      assert :file_type in missing_fields
      assert :mime_type in missing_fields
      assert :file_size in missing_fields
      assert :storage_url in missing_fields
    end

    test "rejects unknown file_type" do
      changeset =
        MessageAttachment.changeset(%MessageAttachment{}, valid_attrs(%{file_type: "weird"}))

      refute changeset.valid?
      assert {:file_type, _} = List.keyfind(changeset.errors, :file_type, 0)
    end

    test "rejects negative file size" do
      changeset =
        MessageAttachment.changeset(%MessageAttachment{}, valid_attrs(%{file_size: -1}))

      refute changeset.valid?
    end

    test "rejects file size beyond the maximum" do
      changeset =
        MessageAttachment.changeset(
          %MessageAttachment{},
          valid_attrs(%{file_type: "image", file_size: 999_999_999_999})
        )

      refute changeset.valid?
    end

    test "rejects non-map metadata" do
      changeset =
        MessageAttachment.changeset(%MessageAttachment{}, valid_attrs(%{metadata: "not a map"}))

      refute changeset.valid?
    end

    test "rejects filename longer than 255 characters" do
      long_name = String.duplicate("a", 300) <> ".txt"

      changeset =
        MessageAttachment.changeset(%MessageAttachment{}, valid_attrs(%{filename: long_name}))

      refute changeset.valid?
    end
  end

  describe "delete_changeset/1" do
    test "marks the attachment as deleted" do
      cs = MessageAttachment.delete_changeset(%MessageAttachment{is_deleted: false})
      assert cs.changes == %{is_deleted: true}
    end
  end

  describe "type predicates" do
    test "image? recognises images and rejects others" do
      assert MessageAttachment.image?(%MessageAttachment{file_type: "image"})
      refute MessageAttachment.image?(%MessageAttachment{file_type: "video"})
      refute MessageAttachment.image?(%{})
    end

    test "video? recognises videos" do
      assert MessageAttachment.video?(%MessageAttachment{file_type: "video"})
      refute MessageAttachment.video?(%MessageAttachment{file_type: "image"})
    end

    test "audio? recognises audio" do
      assert MessageAttachment.audio?(%MessageAttachment{file_type: "audio"})
      refute MessageAttachment.audio?(%MessageAttachment{file_type: "image"})
    end

    test "document? recognises documents" do
      assert MessageAttachment.document?(%MessageAttachment{file_type: "document"})
      refute MessageAttachment.document?(%MessageAttachment{file_type: "video"})
    end

    test "has_thumbnail? handles nil, empty, and present values" do
      refute MessageAttachment.has_thumbnail?(%MessageAttachment{thumbnail_url: nil})
      refute MessageAttachment.has_thumbnail?(%MessageAttachment{thumbnail_url: ""})
      assert MessageAttachment.has_thumbnail?(%MessageAttachment{thumbnail_url: "/t.jpg"})
    end

    test "deleted? reflects the is_deleted field" do
      assert MessageAttachment.deleted?(%MessageAttachment{is_deleted: true})
      refute MessageAttachment.deleted?(%MessageAttachment{is_deleted: false})
    end

    test "requires_processing? returns true for images and videos" do
      assert MessageAttachment.requires_processing?(%MessageAttachment{file_type: "image"})
      assert MessageAttachment.requires_processing?(%MessageAttachment{file_type: "video"})
      refute MessageAttachment.requires_processing?(%MessageAttachment{file_type: "document"})
      refute MessageAttachment.requires_processing?(%MessageAttachment{file_type: "audio"})
    end
  end

  describe "name and extension helpers" do
    test "display_name strips the file extension" do
      assert "report" ==
               MessageAttachment.display_name(%MessageAttachment{filename: "report.pdf"})

      assert "noext" == MessageAttachment.display_name(%MessageAttachment{filename: "noext"})
    end

    test "file_extension returns the dotted extension" do
      assert ".pdf" == MessageAttachment.file_extension(%MessageAttachment{filename: "x.pdf"})
      assert "" == MessageAttachment.file_extension(%MessageAttachment{filename: "noext"})
    end
  end

  describe "human_file_size/1" do
    test "formats sub-KB byte counts" do
      assert "512 B" == MessageAttachment.human_file_size(512)
    end

    test "formats KB" do
      assert "1.5 KB" == MessageAttachment.human_file_size(1536)
    end

    test "formats MB" do
      assert String.ends_with?(MessageAttachment.human_file_size(2 * 1_048_576), "MB")
    end

    test "formats GB" do
      assert String.ends_with?(MessageAttachment.human_file_size(3 * 1_073_741_824), "GB")
    end

    test "accepts a struct argument" do
      assert "1.0 KB" ==
               MessageAttachment.human_file_size(%MessageAttachment{file_size: 1024})
    end
  end

  describe "metadata helpers" do
    test "get_metadata returns value or default" do
      a = %MessageAttachment{metadata: %{"foo" => "bar"}}
      assert "bar" == MessageAttachment.get_metadata(a, "foo")
      assert "fallback" == MessageAttachment.get_metadata(a, "missing", "fallback")
      assert nil == MessageAttachment.get_metadata(a, "missing")
    end

    test "put_metadata adds a key without dropping existing ones" do
      a = %MessageAttachment{metadata: %{"a" => 1}}
      a2 = MessageAttachment.put_metadata(a, "b", 2)
      assert a2.metadata == %{"a" => 1, "b" => 2}
    end
  end

  describe "media-specific accessors" do
    test "image_dimensions returns {w, h} when both are integers" do
      a = %MessageAttachment{file_type: "image", metadata: %{"width" => 800, "height" => 600}}
      assert {800, 600} == MessageAttachment.image_dimensions(a)
    end

    test "image_dimensions returns nil for non-image attachments" do
      a = %MessageAttachment{file_type: "document", metadata: %{"width" => 800, "height" => 600}}
      assert nil == MessageAttachment.image_dimensions(a)
    end

    test "image_dimensions returns nil when dimensions are missing or invalid" do
      a = %MessageAttachment{file_type: "image", metadata: %{}}
      assert nil == MessageAttachment.image_dimensions(a)

      b = %MessageAttachment{file_type: "image", metadata: %{"width" => "x"}}
      assert nil == MessageAttachment.image_dimensions(b)
    end

    test "video_duration returns the duration for videos" do
      assert 12.5 ==
               MessageAttachment.video_duration(%MessageAttachment{
                 file_type: "video",
                 metadata: %{"duration" => 12.5}
               })

      assert nil ==
               MessageAttachment.video_duration(%MessageAttachment{
                 file_type: "video",
                 metadata: %{"duration" => "x"}
               })

      assert nil ==
               MessageAttachment.video_duration(%MessageAttachment{
                 file_type: "image",
                 metadata: %{"duration" => 12}
               })
    end

    test "audio_duration returns the duration for audio" do
      assert 7 ==
               MessageAttachment.audio_duration(%MessageAttachment{
                 file_type: "audio",
                 metadata: %{"duration" => 7}
               })

      assert nil ==
               MessageAttachment.audio_duration(%MessageAttachment{
                 file_type: "image",
                 metadata: %{"duration" => 7}
               })
    end
  end

  describe "get_secure_url/1" do
    test "returns the storage url and an expiration in the future" do
      now = DateTime.utc_now()

      result =
        MessageAttachment.get_secure_url(%MessageAttachment{
          storage_url: "/foo",
          encryption_key: <<1, 2, 3>>
        })

      assert result.url == "/foo"
      assert result.requires_encryption_key
      assert DateTime.compare(result.expires_at, now) == :gt
    end

    test "marks attachments without an encryption key as not requiring one" do
      result =
        MessageAttachment.get_secure_url(%MessageAttachment{
          storage_url: "/x",
          encryption_key: nil
        })

      refute result.requires_encryption_key
    end
  end

  describe "queries" do
    test "by_message_query/1 returns an Ecto.Query struct" do
      q = MessageAttachment.by_message_query(Ecto.UUID.generate())
      assert %Ecto.Query{} = q
    end

    test "by_file_type_query/2 returns an Ecto.Query struct" do
      q = MessageAttachment.by_file_type_query(Ecto.UUID.generate(), "image")
      assert %Ecto.Query{} = q
    end

    test "conversation_storage_size_query/1 returns an Ecto.Query struct" do
      q = MessageAttachment.conversation_storage_size_query(Ecto.UUID.generate())
      assert %Ecto.Query{} = q
    end

    test "older_than_query/1 returns an Ecto.Query struct" do
      q = MessageAttachment.older_than_query(DateTime.utc_now())
      assert %Ecto.Query{} = q
    end
  end
end
