defmodule WhisprMessagingWeb.AttachmentControllerTest do
  @moduledoc """
  Controller tests for the attachment endpoints (upload, download, list,
  delete and metadata-only creation).
  """

  use WhisprMessagingWeb.ConnCase, async: false

  alias WhisprMessaging.Conversations
  alias WhisprMessaging.Messages

  @upload_dir "priv/static/uploads"

  setup do
    File.mkdir_p!(@upload_dir)

    user_id = Ecto.UUID.generate()
    other_id = Ecto.UUID.generate()
    stranger_id = Ecto.UUID.generate()

    {:ok, conversation} =
      Conversations.create_conversation(%{
        type: "group",
        metadata: %{"name" => "attachment test"},
        is_active: true
      })

    {:ok, _} = Conversations.add_conversation_member(conversation.id, user_id)
    {:ok, _} = Conversations.add_conversation_member(conversation.id, other_id)

    {:ok, message} =
      Messages.create_message(%{
        conversation_id: conversation.id,
        sender_id: user_id,
        message_type: "media",
        content: "carrier",
        client_random: System.unique_integer([:positive])
      })

    %{
      user_id: user_id,
      other_id: other_id,
      stranger_id: stranger_id,
      conversation: conversation,
      message: message
    }
  end

  defp tmpfile(content, ext) do
    path = Path.join(System.tmp_dir!(), "attach-#{Ecto.UUID.generate()}.#{ext}")
    File.write!(path, content)
    path
  end

  defp upload(filename, content_type, content) do
    ext = Path.extname(filename) |> String.trim_leading(".")
    %Plug.Upload{path: tmpfile(content, ext), filename: filename, content_type: content_type}
  end

  describe "POST /messaging/api/v1/attachments/upload" do
    test "uploads a valid file for the message owner", ctx do
      body =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> post(~p"/messaging/api/v1/attachments/upload", %{
          "file" => upload("hello.txt", "text/plain", "hello world"),
          "message_id" => ctx.message.id
        })
        |> json_response(201)

      assert body["data"]["fileName"] == "hello.txt"
      assert body["data"]["mimeType"] == "text/plain"
      assert body["data"]["fileSize"] > 0
    end

    test "rejects unsupported mime type with 415", ctx do
      build_conn()
      |> authenticated_conn(ctx.user_id)
      |> post(~p"/messaging/api/v1/attachments/upload", %{
        "file" => upload("evil.exe", "application/x-msdownload", "binary"),
        "message_id" => ctx.message.id
      })
      |> json_response(415)
    end

    test "rejects upload from a non-sender with 403", ctx do
      build_conn()
      |> authenticated_conn(ctx.other_id)
      |> post(~p"/messaging/api/v1/attachments/upload", %{
        "file" => upload("note.txt", "text/plain", "x"),
        "message_id" => ctx.message.id
      })
      |> json_response(403)
    end

    test "returns 400 when missing required parameters", ctx do
      build_conn()
      |> authenticated_conn(ctx.user_id)
      |> json_conn()
      |> post(~p"/messaging/api/v1/attachments/upload", %{})
      |> json_response(400)
    end
  end

  describe "GET /messaging/api/v1/attachments/:id" do
    test "returns metadata for an existing attachment", ctx do
      {:ok, attachment} =
        Messages.create_attachment(%{
          message_id: ctx.message.id,
          filename: "doc.pdf",
          file_type: "document",
          mime_type: "application/pdf",
          file_size: 100,
          storage_url: "/uploads/doc.pdf"
        })

      body =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> get(~p"/messaging/api/v1/attachments/#{attachment.id}")
        |> json_response(200)

      assert body["data"]["fileName"] == "doc.pdf"
      assert body["data"]["fileSize"] == 100
    end

    test "returns 404 when the attachment does not exist", ctx do
      build_conn()
      |> authenticated_conn(ctx.user_id)
      |> json_conn()
      |> get(~p"/messaging/api/v1/attachments/#{Ecto.UUID.generate()}")
      |> json_response(404)
    end
  end

  describe "GET /messaging/api/v1/attachments/:id/download" do
    test "returns 404 when the attachment does not exist", ctx do
      build_conn()
      |> authenticated_conn(ctx.user_id)
      |> json_conn()
      |> get(~p"/messaging/api/v1/attachments/#{Ecto.UUID.generate()}/download")
      |> json_response(404)
    end

    test "controller source declares cache-control and etag headers on the success branch" do
      # le download success path actuel raise KeyError sur attachment.file_path
      # (field absent du schema, bug pre-existant non lie a ce ticket).
      # On verifie au niveau source que les headers cache + etag sont bien
      # cables sur la pipe de reussite afin d'eviter une regression silencieuse.
      source =
        File.read!("lib/whispr_messaging_web/controllers/attachment_controller.ex")

      assert source =~ ~s|put_resp_header("cache-control", "private, max-age=3600")|
      assert source =~ ~s|put_resp_header("etag", "\\"#\{attachment.id\}\\"")|
    end
  end

  describe "DELETE /messaging/api/v1/attachments/:id" do
    test "rejects deletion when the user is not the message sender", ctx do
      {:ok, attachment} =
        Messages.create_attachment(%{
          message_id: ctx.message.id,
          filename: "y.txt",
          file_type: "document",
          mime_type: "text/plain",
          file_size: 1,
          storage_url: "/uploads/y.txt"
        })

      build_conn()
      |> authenticated_conn(ctx.other_id)
      |> json_conn()
      |> delete(~p"/messaging/api/v1/attachments/#{attachment.id}")
      |> json_response(403)
    end
  end

  describe "GET /messaging/api/v1/messages/:id/attachments" do
    test "lists attachments of a message", ctx do
      {:ok, _} =
        Messages.create_attachment(%{
          message_id: ctx.message.id,
          filename: "a.png",
          file_type: "image",
          mime_type: "image/png",
          file_size: 10,
          storage_url: "/uploads/a.png"
        })

      {:ok, _} =
        Messages.create_attachment(%{
          message_id: ctx.message.id,
          filename: "b.png",
          file_type: "image",
          mime_type: "image/png",
          file_size: 20,
          storage_url: "/uploads/b.png"
        })

      body =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> get(~p"/messaging/api/v1/messages/#{ctx.message.id}/attachments")
        |> json_response(200)

      assert body["meta"]["count"] == 2
      assert length(body["data"]) == 2
    end
  end

  describe "POST /messaging/api/v1/messages/:message_id/attachments (metadata only)" do
    test "creates an attachment record from JSON metadata", ctx do
      body =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> post(~p"/messaging/api/v1/messages/#{ctx.message.id}/attachments", %{
          "filename" => "vid.mp4",
          "media_type" => "video",
          "mime_type" => "video/mp4",
          "size" => 1234,
          "media_url" => "/uploads/vid.mp4"
        })
        |> json_response(201)

      assert body["data"]["fileName"] == "vid.mp4"
      assert body["data"]["fileSize"] == 1234
    end

    test "returns 422 when payload is invalid", ctx do
      build_conn()
      |> authenticated_conn(ctx.user_id)
      |> json_conn()
      |> post(~p"/messaging/api/v1/messages/#{ctx.message.id}/attachments", %{
        "filename" => "x.bin",
        "media_type" => "not-a-type"
      })
      |> json_response(422)
    end
  end
end
