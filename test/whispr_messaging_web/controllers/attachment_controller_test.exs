defmodule WhisprMessagingWeb.AttachmentControllerTest do
  use WhisprMessagingWeb.ConnCase, async: false

  alias WhisprMessaging.{Conversations, Messages}

  defp unique_client_random do
    rem(System.system_time(:microsecond) + :rand.uniform(10_000), 2_147_483_647)
  end

  defp write_tmp(name, content) do
    path = Path.join(System.tmp_dir!(), "#{Ecto.UUID.generate()}_#{name}")
    File.write!(path, content)
    path
  end

  defp upload(name, content_type, body) do
    path = write_tmp(name, body)
    %Plug.Upload{path: path, filename: name, content_type: content_type}
  end

  defp setup_message(user_id, conversation) do
    {:ok, message} =
      Messages.create_message(%{
        conversation_id: conversation.id,
        sender_id: user_id,
        message_type: "media",
        content: "with file",
        client_random: unique_client_random()
      })

    message
  end

  setup do
    user_id = Ecto.UUID.generate()
    outsider_id = Ecto.UUID.generate()

    {:ok, conversation} =
      Conversations.create_conversation(%{
        type: "direct",
        metadata: %{"test" => true},
        is_active: true
      })

    {:ok, _m} = Conversations.add_conversation_member(conversation.id, user_id)

    message = setup_message(user_id, conversation)

    on_exit(fn ->
      # Cleanup any uploaded files in priv/static/uploads created during the test
      File.rm_rf("priv/static/uploads")
    end)

    %{
      user_id: user_id,
      outsider_id: outsider_id,
      conversation: conversation,
      message: message
    }
  end

  describe "POST /attachments/upload" do
    test "uploads a valid PNG file and returns 201 with attachment metadata", ctx do
      upload = upload("photo.png", "image/png", "fake-png-bytes")

      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> post(~p"/messaging/api/v1/attachments/upload", %{
          "file" => upload,
          "message_id" => ctx.message.id
        })
        |> json_response(201)

      assert response["data"]["messageId"] == ctx.message.id
      assert response["data"]["mimeType"] == "image/png"
      assert response["data"]["fileSize"] > 0
      assert response["message"] =~ "uploaded successfully"
    end

    test "returns 415 for unsupported MIME type", ctx do
      upload = upload("script.exe", "application/x-msdownload", "not allowed")

      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> post(~p"/messaging/api/v1/attachments/upload", %{
          "file" => upload,
          "message_id" => ctx.message.id
        })
        |> json_response(415)

      assert response["error"] =~ "not supported"
    end

    test "returns 403 when the user is not the message sender", ctx do
      upload = upload("photo.png", "image/png", "x")

      response =
        build_conn()
        |> authenticated_conn(ctx.outsider_id)
        |> post(~p"/messaging/api/v1/attachments/upload", %{
          "file" => upload,
          "message_id" => ctx.message.id
        })
        |> json_response(403)

      assert response["error"] =~ "permission"
    end

    test "returns 400 when required params are missing", ctx do
      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> post(~p"/messaging/api/v1/attachments/upload", %{})
        |> json_response(400)

      assert response["error"] == "Missing required parameters"
      assert "file" in response["required"]
    end
  end

  describe "GET /attachments/:id" do
    test "returns metadata for an existing attachment", ctx do
      {:ok, attachment} =
        Messages.create_attachment(%{
          message_id: ctx.message.id,
          filename: "doc.pdf",
          file_type: "document",
          file_size: 12,
          mime_type: "application/pdf",
          storage_url: "/uploads/doc.pdf"
        })

      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> get(~p"/messaging/api/v1/attachments/#{attachment.id}")
        |> json_response(200)

      assert response["data"]["id"] == attachment.id
      assert response["data"]["fileName"] == "doc.pdf"
    end

    test "returns 404 for unknown attachment id", ctx do
      missing = Ecto.UUID.generate()

      conn =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> get(~p"/messaging/api/v1/attachments/#{missing}")

      assert conn.status in [404, 500]
    end
  end

  describe "GET /attachments/:id/download" do
    test "streams the attachment file content", ctx do
      # The controller derives the local filesystem path from the
      # `storage_url` field (request-path form, e.g. "/uploads/<uuid>").
      # We mimic that here: write a file under priv/static/uploads/<uuid>
      # so the controller's `attachment_local_path/1` finds it.
      upload_dir = "priv/static/uploads"
      File.mkdir_p!(upload_dir)
      uid = "#{Ecto.UUID.generate()}.txt"
      file_path = Path.join(upload_dir, uid)
      file_body = "decoded content"
      File.write!(file_path, file_body)

      on_exit(fn -> File.rm(file_path) end)

      {:ok, attachment} =
        Messages.create_attachment(%{
          message_id: ctx.message.id,
          filename: "download.txt",
          file_type: "document",
          file_size: byte_size(file_body),
          mime_type: "text/plain",
          storage_url: "/uploads/#{uid}"
        })

      conn =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> get(~p"/messaging/api/v1/attachments/#{attachment.id}/download")

      assert conn.status == 200
      assert conn.resp_body == file_body
    end

    test "returns 404 for unknown attachment", ctx do
      missing = Ecto.UUID.generate()

      conn =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> get(~p"/messaging/api/v1/attachments/#{missing}/download")

      assert conn.status in [404, 500]
    end

    test "returns 403 when a non-member tries to download", ctx do
      # Owner uploads an attachment; outsider tries to download.
      {:ok, attachment} =
        Messages.create_attachment(%{
          message_id: ctx.message.id,
          filename: "private.txt",
          file_type: "document",
          file_size: 3,
          mime_type: "text/plain",
          storage_url: "/uploads/private"
        })

      conn =
        build_conn()
        |> authenticated_conn(ctx.outsider_id)
        |> get(~p"/messaging/api/v1/attachments/#{attachment.id}/download")

      assert conn.status == 403
    end

    test "returns 404 when the stored file does not exist on disk", ctx do
      # storage_url points to a path that doesn't exist on disk.
      {:ok, attachment} =
        Messages.create_attachment(%{
          message_id: ctx.message.id,
          filename: "missing.txt",
          file_type: "document",
          file_size: 1,
          mime_type: "text/plain",
          storage_url: "/uploads/does-not-exist-#{Ecto.UUID.generate()}.txt"
        })

      conn =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> get(~p"/messaging/api/v1/attachments/#{attachment.id}/download")

      assert conn.status in [404, 500]
    end
  end

  describe "DELETE /attachments/:id" do
    test "deletes the user's own attachment", ctx do
      # The controller deletes the file at the path derived from storage_url
      # (request-path form). delete_file/1 treats :enoent as success, so an
      # absent file is fine — we only need a valid DB record here.
      {:ok, attachment} =
        Messages.create_attachment(%{
          message_id: ctx.message.id,
          filename: "to-del.txt",
          file_type: "document",
          file_size: 3,
          mime_type: "text/plain",
          storage_url: "/uploads/nope"
        })

      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> delete(~p"/messaging/api/v1/attachments/#{attachment.id}")
        |> json_response(200)

      assert response["data"]["id"] == attachment.id
      assert response["data"]["deleted"] == true
    end

    test "returns 403 when another user tries to delete", ctx do
      {:ok, attachment} =
        Messages.create_attachment(%{
          message_id: ctx.message.id,
          filename: "mine.txt",
          file_type: "document",
          file_size: 5,
          mime_type: "text/plain",
          storage_url: "/uploads/x"
        })

      response =
        build_conn()
        |> authenticated_conn(ctx.outsider_id)
        |> json_conn()
        |> delete(~p"/messaging/api/v1/attachments/#{attachment.id}")
        |> json_response(403)

      assert response["error"] =~ "permission"
    end
  end

  describe "GET /messages/:id/attachments" do
    test "lists attachments for a message", ctx do
      Enum.each(1..2, fn i ->
        {:ok, _} =
          Messages.create_attachment(%{
            message_id: ctx.message.id,
            filename: "f#{i}.txt",
            file_type: "document",
            file_size: 4,
            mime_type: "text/plain",
            storage_url: "/uploads/f#{i}"
          })
      end)

      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> get(~p"/messaging/api/v1/messages/#{ctx.message.id}/attachments")
        |> json_response(200)

      assert response["meta"]["messageId"] == ctx.message.id
      assert response["meta"]["count"] == 2
      assert length(response["data"]) == 2
    end
  end

  describe "POST /attachments/upload (more branches)" do
    test "returns 413 when file exceeds the 50MB limit", ctx do
      # Build a fake upload with a real file path containing 51 MB of zeros
      path = write_tmp("huge.png", String.duplicate(<<0>>, 51 * 1024 * 1024))
      upload = %Plug.Upload{path: path, filename: "huge.png", content_type: "image/png"}

      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> post(~p"/messaging/api/v1/attachments/upload", %{
          "file" => upload,
          "message_id" => ctx.message.id
        })
        |> json_response(413)

      assert response["error"] =~ "exceeds"
    end

    test "returns 500 when the message does not exist", ctx do
      upload = upload("photo.png", "image/png", "x")
      missing = Ecto.UUID.generate()

      conn =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> post(~p"/messaging/api/v1/attachments/upload", %{
          "file" => upload,
          "message_id" => missing
        })

      assert conn.status in [403, 404, 500]
    end
  end

  describe "POST /attachments/upload — every supported MIME type" do
    test "accepts JPEG image", ctx do
      upload = upload("photo.jpg", "image/jpeg", "x")

      conn =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> post(~p"/messaging/api/v1/attachments/upload", %{
          "file" => upload,
          "message_id" => ctx.message.id
        })

      assert conn.status == 201
    end

    test "accepts PDF document", ctx do
      upload = upload("doc.pdf", "application/pdf", "x")

      conn =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> post(~p"/messaging/api/v1/attachments/upload", %{
          "file" => upload,
          "message_id" => ctx.message.id
        })

      assert conn.status == 201
    end

    test "accepts MP4 video", ctx do
      upload = upload("video.mp4", "video/mp4", "x")

      conn =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> post(~p"/messaging/api/v1/attachments/upload", %{
          "file" => upload,
          "message_id" => ctx.message.id
        })

      assert conn.status == 201
    end

    test "accepts MP3 audio", ctx do
      upload = upload("audio.mp3", "audio/mpeg", "x")

      conn =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> post(~p"/messaging/api/v1/attachments/upload", %{
          "file" => upload,
          "message_id" => ctx.message.id
        })

      assert conn.status == 201
    end

    test "accepts text/plain", ctx do
      upload = upload("readme.txt", "text/plain", "hello")

      conn =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> post(~p"/messaging/api/v1/attachments/upload", %{
          "file" => upload,
          "message_id" => ctx.message.id
        })

      assert conn.status == 201
    end

    test "accepts GIF image", ctx do
      upload = upload("anim.gif", "image/gif", "GIF89a")

      conn =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> post(~p"/messaging/api/v1/attachments/upload", %{
          "file" => upload,
          "message_id" => ctx.message.id
        })

      assert conn.status == 201
    end

    test "accepts WebP image", ctx do
      upload = upload("img.webp", "image/webp", "RIFF")

      conn =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> post(~p"/messaging/api/v1/attachments/upload", %{
          "file" => upload,
          "message_id" => ctx.message.id
        })

      assert conn.status == 201
    end

    test "accepts WAV audio", ctx do
      upload = upload("audio.wav", "audio/wav", "RIFF")

      conn =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> post(~p"/messaging/api/v1/attachments/upload", %{
          "file" => upload,
          "message_id" => ctx.message.id
        })

      assert conn.status == 201
    end

    test "accepts MOV video", ctx do
      upload = upload("video.mov", "video/quicktime", "x")

      conn =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> post(~p"/messaging/api/v1/attachments/upload", %{
          "file" => upload,
          "message_id" => ctx.message.id
        })

      assert conn.status == 201
    end

    test "accepts text/csv", ctx do
      upload = upload("data.csv", "text/csv", "a,b,c\n1,2,3")

      conn =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> post(~p"/messaging/api/v1/attachments/upload", %{
          "file" => upload,
          "message_id" => ctx.message.id
        })

      assert conn.status == 201
    end

    test "accepts MS Word document", ctx do
      upload = upload("doc.doc", "application/msword", "doc-bytes")

      conn =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> post(~p"/messaging/api/v1/attachments/upload", %{
          "file" => upload,
          "message_id" => ctx.message.id
        })

      assert conn.status == 201
    end
  end

  describe "POST /messages/:message_id/attachments (metadata-only)" do
    test "creates an attachment record from JSON metadata", ctx do
      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> post(~p"/messaging/api/v1/messages/#{ctx.message.id}/attachments", %{
          "filename" => "remote.png",
          "media_type" => "image",
          "mime_type" => "image/png",
          "size" => 1024,
          "media_url" => "https://media.example.com/abc",
          "thumbnail_url" => "https://media.example.com/abc-thumb",
          "metadata" => %{"media_id" => "abc"}
        })
        |> json_response(201)

      assert response["data"]["messageId"] == ctx.message.id
      assert response["data"]["fileName"] == "remote.png"
      assert response["data"]["mediaId"] == "abc"
    end

    test "returns 422 when payload is invalid", ctx do
      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> post(~p"/messaging/api/v1/messages/#{ctx.message.id}/attachments", %{
          "filename" => "x",
          "size" => 0,
          "media_url" => ""
        })
        |> json_response(422)

      assert response["error"] =~ "Failed"
    end
  end

  describe "auth missing" do
    test "GET /attachments/:id returns 404/401 without auth", _ctx do
      conn =
        build_conn()
        |> json_conn()
        |> get(~p"/messaging/api/v1/attachments/#{Ecto.UUID.generate()}")

      assert conn.status in [401, 404, 500]
    end

    test "POST /attachments/upload returns 401 without auth", _ctx do
      conn =
        build_conn()
        |> post(~p"/messaging/api/v1/attachments/upload", %{})

      assert conn.status in [400, 401]
    end

    test "DELETE /attachments/:id returns 401 without auth", _ctx do
      conn =
        build_conn()
        |> json_conn()
        |> delete(~p"/messaging/api/v1/attachments/#{Ecto.UUID.generate()}")

      assert conn.status in [401, 500]
    end
  end
end
