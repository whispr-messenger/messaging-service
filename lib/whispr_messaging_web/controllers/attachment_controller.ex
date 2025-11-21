defmodule WhisprMessagingWeb.AttachmentController do
  @moduledoc """
  Controller for file upload and download operations.
  Handles multipart uploads and streaming downloads.
  """

  use WhisprMessagingWeb, :controller

  alias WhisprMessaging.Messages
  alias WhisprMessaging.Messages.MessageAttachment

  require Logger

  @upload_dir "priv/static/uploads"
  @max_file_size 50 * 1024 * 1024  # 50 MB
  @allowed_mime_types [
    "image/jpeg", "image/png", "image/gif", "image/webp",
    "application/pdf",
    "application/msword", "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "application/vnd.ms-excel", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    "text/plain", "text/csv",
    "video/mp4", "video/quicktime",
    "audio/mpeg", "audio/wav"
  ]

  action_fallback WhisprMessagingWeb.FallbackController

  @doc """
  Upload a file attachment.
  POST /api/v1/attachments/upload

  Multipart form data:
  - file: the file to upload
  - message_id: UUID of the message
  - user_id: UUID of the user uploading
  """
  def upload(conn, %{"file" => upload, "message_id" => message_id, "user_id" => user_id}) do
    with :ok <- validate_file_size(upload),
         :ok <- validate_mime_type(upload.content_type),
         {:ok, message} <- Messages.get_message(message_id),
         :ok <- validate_user_permission(message, user_id),
         {:ok, file_path, file_url} <- save_file(upload),
         {:ok, attachment} <- create_attachment_record(message_id, upload, file_path, file_url) do

      Logger.info("File uploaded successfully: #{attachment.id}")

      conn
      |> put_status(:created)
      |> json(%{
        data: render_attachment(attachment),
        message: "File uploaded successfully"
      })
    else
      {:error, :file_too_large} ->
        conn
        |> put_status(:request_entity_too_large)
        |> json(%{error: "File size exceeds maximum allowed (50MB)"})

      {:error, :invalid_mime_type} ->
        conn
        |> put_status(:unsupported_media_type)
        |> json(%{error: "File type not supported"})

      {:error, :unauthorized} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "You don't have permission to upload to this message"})

      {:error, reason} ->
        Logger.error("Upload failed: #{inspect(reason)}")
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Upload failed"})
    end
  end

  def upload(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{
      error: "Missing required parameters",
      required: ["file", "message_id", "user_id"]
    })
  end

  @doc """
  Download a file attachment.
  GET /api/v1/attachments/:id/download?user_id=uuid
  """
  def download(conn, %{"id" => attachment_id, "user_id" => user_id}) do
    with {:ok, attachment} <- Messages.get_attachment(attachment_id),
         {:ok, message} <- Messages.get_message(attachment.message_id),
         :ok <- validate_user_access(message, user_id),
         {:ok, file_content} <- read_file(attachment.file_path) do

      Logger.info("File downloaded: #{attachment.id} by user #{user_id}")

      conn
      |> put_resp_content_type(attachment.mime_type)
      |> put_resp_header("content-disposition", "attachment; filename=\"#{attachment.file_name}\"")
      |> put_resp_header("content-length", "#{attachment.file_size}")
      |> send_resp(200, file_content)
    else
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Attachment not found"})

      {:error, :unauthorized} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "You don't have access to this file"})

      {:error, :file_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "File not found on server"})

      {:error, reason} ->
        Logger.error("Download failed: #{inspect(reason)}")
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Download failed"})
    end
  end

  def download(conn, %{"id" => _attachment_id}) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing user_id parameter"})
  end

  @doc """
  Get attachment metadata.
  GET /api/v1/attachments/:id
  """
  def show(conn, %{"id" => attachment_id}) do
    with {:ok, attachment} <- Messages.get_attachment(attachment_id) do
      json(conn, %{
        data: render_attachment(attachment)
      })
    end
  end

  @doc """
  Delete an attachment.
  DELETE /api/v1/attachments/:id?user_id=uuid
  """
  def delete(conn, %{"id" => attachment_id, "user_id" => user_id}) do
    with {:ok, attachment} <- Messages.get_attachment(attachment_id),
         {:ok, message} <- Messages.get_message(attachment.message_id),
         :ok <- validate_user_permission(message, user_id),
         :ok <- delete_file(attachment.file_path),
         {:ok, _} <- Messages.delete_attachment(attachment_id) do

      Logger.info("Attachment deleted: #{attachment_id}")

      json(conn, %{
        data: %{
          id: attachment_id,
          deleted: true
        }
      })
    else
      {:error, :unauthorized} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "You don't have permission to delete this attachment"})

      {:error, reason} ->
        Logger.error("Delete failed: #{inspect(reason)}")
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Delete failed"})
    end
  end

  # Private functions

  defp validate_file_size(%{path: path}) do
    case File.stat(path) do
      {:ok, %{size: size}} when size <= @max_file_size -> :ok
      {:ok, %{size: _}} -> {:error, :file_too_large}
      {:error, _} -> {:error, :file_stat_failed}
    end
  end

  defp validate_mime_type(mime_type) when mime_type in @allowed_mime_types, do: :ok
  defp validate_mime_type(_), do: {:error, :invalid_mime_type}

  defp validate_user_permission(%{sender_id: sender_id}, user_id) when sender_id == user_id, do: :ok
  defp validate_user_permission(_, _), do: {:error, :unauthorized}

  defp validate_user_access(message, user_id) do
    # Check if user is member of the conversation
    case Messages.user_can_access_message?(message.conversation_id, user_id) do
      true -> :ok
      false -> {:error, :unauthorized}
    end
  end

  defp save_file(upload) do
    # Ensure upload directory exists
    File.mkdir_p!(@upload_dir)

    # Generate unique filename
    file_extension = Path.extname(upload.filename)
    unique_filename = "#{Ecto.UUID.generate()}#{file_extension}"
    file_path = Path.join(@upload_dir, unique_filename)
    file_url = "/uploads/#{unique_filename}"

    case File.cp(upload.path, file_path) do
      :ok -> {:ok, file_path, file_url}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_attachment_record(message_id, upload, file_path, file_url) do
    {:ok, %{size: file_size}} = File.stat(file_path)

    Messages.create_attachment(%{
      message_id: message_id,
      file_name: upload.filename,
      file_path: file_path,
      file_url: file_url,
      file_size: file_size,
      mime_type: upload.content_type
    })
  end

  defp read_file(file_path) do
    case File.read(file_path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:error, :file_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp delete_file(file_path) do
    case File.rm(file_path) do
      :ok -> :ok
      {:error, :enoent} -> :ok  # File already deleted
      {:error, reason} -> {:error, reason}
    end
  end

  defp render_attachment(attachment) do
    %{
      id: attachment.id,
      message_id: attachment.message_id,
      file_name: attachment.file_name,
      file_url: attachment.file_url,
      file_size: attachment.file_size,
      mime_type: attachment.mime_type,
      uploaded_at: attachment.inserted_at
    }
  end
end
