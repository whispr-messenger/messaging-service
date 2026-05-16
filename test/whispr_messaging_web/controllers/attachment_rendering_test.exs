defmodule WhisprMessagingWeb.AttachmentRenderingTest do
  @moduledoc """
  Unit tests for the pure rendering helpers extracted from
  `AttachmentController`.
  """
  use ExUnit.Case, async: true

  alias WhisprMessagingWeb.AttachmentRendering

  describe "render/1" do
    test "shapes an attachment record into the camelCase REST payload" do
      attachment = %{
        id: "att-1",
        message_id: "msg-1",
        filename: "image.png",
        file_type: "image",
        storage_url: "https://media/abc",
        file_size: 1234,
        mime_type: "image/png",
        thumbnail_url: "https://media/abc/thumb",
        metadata: %{"media_id" => "media-42"},
        inserted_at: ~N[2026-05-01 09:00:00]
      }

      out = AttachmentRendering.render(attachment)

      assert out["id"] == "att-1"
      assert out["messageId"] == "msg-1"
      assert out["mediaId"] == "media-42"
      assert out["fileName"] == "image.png"
      assert out["fileType"] == "image"
      assert out["fileUrl"] == "https://media/abc"
      assert out["fileSize"] == 1234
      assert out["mimeType"] == "image/png"
      assert out["thumbnailUrl"] == "https://media/abc/thumb"
      assert out["uploadedAt"] == ~N[2026-05-01 09:00:00]
    end

    test "treats nil metadata as an empty map" do
      attachment = %{
        id: "att-2",
        message_id: "msg-2",
        filename: "doc.pdf",
        file_type: "document",
        storage_url: "https://x",
        file_size: 0,
        mime_type: "application/pdf",
        thumbnail_url: nil,
        metadata: nil,
        inserted_at: nil
      }

      out = AttachmentRendering.render(attachment)
      assert out["mediaId"] == nil
      assert out["metadata"] == %{}
    end
  end

  describe "build_attachment_attrs/2" do
    test "applies defaults when all optional fields are missing" do
      attrs = AttachmentRendering.build_attachment_attrs(%{}, "msg-99")

      assert attrs.message_id == "msg-99"
      assert attrs.filename == "file"
      assert attrs.file_type == "image"
      assert attrs.mime_type == "application/octet-stream"
      assert attrs.file_size == 0
      assert attrs.storage_url == ""
      assert attrs.thumbnail_url == nil
      assert attrs.metadata == %{}
    end

    test "picks values from top-level params" do
      params = %{
        "filename" => "video.mp4",
        "media_type" => "video",
        "mime_type" => "video/mp4",
        "size" => 99_999,
        "media_url" => "https://media/v",
        "thumbnail_url" => "https://media/v.jpg"
      }

      attrs = AttachmentRendering.build_attachment_attrs(params, "msg-1")
      assert attrs.filename == "video.mp4"
      assert attrs.file_type == "video"
      assert attrs.mime_type == "video/mp4"
      assert attrs.file_size == 99_999
      assert attrs.storage_url == "https://media/v"
      assert attrs.thumbnail_url == "https://media/v.jpg"
    end

    test "params override the metadata bag for shared keys" do
      params = %{
        "metadata" => %{"filename" => "old.png", "media_id" => "m-1"},
        "filename" => "new.png"
      }

      attrs = AttachmentRendering.build_attachment_attrs(params, "msg-1")
      assert attrs.filename == "new.png"
      assert attrs.metadata == %{"filename" => "old.png", "media_id" => "m-1"}
    end

    test "missing 'metadata' key results in {} metadata in attrs" do
      attrs = AttachmentRendering.build_attachment_attrs(%{"filename" => "x"}, "msg-1")
      assert attrs.metadata == %{}
    end
  end
end
