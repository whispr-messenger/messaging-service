defmodule WhisprMessagingWeb.AttachmentController do
  @moduledoc """
  Controller for file upload and download operations.
  Handles multipart uploads and streaming downloads.
  """

  use WhisprMessagingWeb, :controller
  use PhoenixSwagger

  alias WhisprMessaging.Messages
  alias WhisprMessagingWeb.AttachmentRendering
  alias WhisprMessagingWeb.AttachmentValidation

  import WhisprMessagingWeb.JsonHelpers, only: [camelize_keys: 1]

  require Logger

  @upload_dir "priv/static/uploads"
  # 50 MB
  @max_file_size 50 * 1024 * 1024
  @allowed_mime_types [
    "image/jpeg",
    "image/png",
    "image/gif",
    "image/webp",
    "application/pdf",
    "application/msword",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "application/vnd.ms-excel",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    "text/plain",
    "text/csv",
    "video/mp4",
    "video/quicktime",
    "audio/mpeg",
    "audio/wav"
  ]

  action_fallback WhisprMessagingWeb.FallbackController

  swagger_path :upload do
    post("/attachments/upload")
    summary("Upload a file attachment")

    description(
      "Uploads a file attachment to a message. Supports images, documents, audio, and video files up to 50MB"
    )

    consumes("multipart/form-data")
    produces("application/json")
    parameter(:file, :formData, :file, "The file to upload", required: true)
    parameter(:message_id, :formData, :string, "UUID of the message", required: true)
    security([%{Bearer: []}])
    response(201, "Created", Schema.ref(:AttachmentResponse))
    response(400, "Bad Request")
    response(403, "Forbidden - User cannot upload to this message")
    response(413, "File too large (max 50MB)")
    response(415, "Unsupported media type")
  end

  # Swagger Schema Definitions
  def swagger_definitions do
    %{
      Attachment:
        swagger_schema do
          title("Attachment")
          description("A file attachment object")

          properties do
            id(:string, "Attachment UUID")
            message_id(:string, "Message UUID")
            file_name(:string, "Original filename")
            file_url(:string, "URL to access the file")
            file_size(:integer, "File size in bytes")
            mime_type(:string, "MIME type of the file")
            uploaded_at(:string, "Upload timestamp")
          end
        end,
      AttachmentResponse:
        swagger_schema do
          title("Attachment Response")
          description("Response containing an attachment object")

          properties do
            data(Schema.ref(:Attachment), "Attachment object")
            message(:string, "Success message")
          end
        end,
      AttachmentDeleteResponse:
        swagger_schema do
          title("Attachment Delete Response")
          description("Response after deleting an attachment")

          property(
            :data,
            Schema.new do
              properties do
                id(:string, "Attachment UUID")
                deleted(:boolean, "Whether the attachment was deleted")
              end
            end,
            "Delete result"
          )
        end
    }
  end

  @doc """
  Upload a file attachment.
  POST /api/v1/attachments/upload

  Multipart form data:
  - file: the file to upload
  - message_id: UUID of the message
  """
  def upload(conn, %{"file" => upload, "message_id" => message_id}) do
    user_id = conn.assigns[:user_id]

    with :ok <- validate_file_size(upload),
         :ok <- validate_mime_type(upload.content_type),
         {:ok, message} <- Messages.get_message(message_id),
         :ok <- validate_user_permission(message, user_id),
         {:ok, file_path, file_url} <- save_file(upload),
         {:ok, attachment} <- create_attachment_record(message_id, upload, file_path, file_url) do
      Logger.info("File uploaded", attachment_id: attachment.id, domain: :attachment)

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
        Logger.error("Upload failed", reason: inspect(reason), domain: :attachment)

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
      required: ["file", "message_id"]
    })
  end

  swagger_path :download do
    get("/attachments/{id}/download")
    summary("Download a file attachment")
    description("Downloads a file attachment by ID")
    produces("application/octet-stream")
    parameter(:id, :path, :string, "Attachment UUID", required: true)
    security([%{Bearer: []}])
    response(200, "Success - File content")
    response(403, "Forbidden - User cannot access this file")
    response(404, "Not Found")
  end

  @doc """
  Download a file attachment.
  GET /api/v1/attachments/:id/download
  """
  def download(conn, %{"id" => attachment_id}) do
    user_id = conn.assigns[:user_id]

    with {:ok, attachment} <- Messages.get_attachment(attachment_id),
         {:ok, message} <- Messages.get_message(attachment.message_id),
         :ok <- validate_user_access(message, user_id),
         {:ok, file_content} <- read_file(attachment_local_path(attachment)) do
      Logger.info("File downloaded", attachment_id: attachment.id, domain: :attachment)

      conn
      |> put_resp_content_type(attachment.mime_type)
      |> put_resp_header(
        "content-disposition",
        "attachment; filename=\"#{attachment.filename}\""
      )
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
        Logger.error("Download failed", reason: inspect(reason), domain: :attachment)

        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Download failed"})
    end
  end

  def download(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Authentication required"})
  end

  swagger_path :show do
    get("/attachments/{id}")
    summary("Get attachment metadata")
    description("Retrieves metadata for a file attachment")
    produces("application/json")
    parameter(:id, :path, :string, "Attachment UUID", required: true)
    security([%{Bearer: []}])
    response(200, "Success", Schema.ref(:AttachmentResponse))
    response(404, "Not Found")
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

  swagger_path :delete do
    PhoenixSwagger.Path.delete("/attachments/{id}")
    summary("Delete an attachment")
    description("Deletes a file attachment and removes the file from storage")
    produces("application/json")
    parameter(:id, :path, :string, "Attachment UUID", required: true)
    security([%{Bearer: []}])
    response(200, "Success", Schema.ref(:AttachmentDeleteResponse))
    response(403, "Forbidden - User cannot delete this attachment")
    response(404, "Not Found")
  end

  @doc """
  Delete an attachment.
  DELETE /api/v1/attachments/:id
  """
  def delete(conn, %{"id" => attachment_id}) do
    user_id = conn.assigns[:user_id]

    with {:ok, attachment} <- Messages.get_attachment(attachment_id),
         {:ok, message} <- Messages.get_message(attachment.message_id),
         :ok <- validate_user_permission(message, user_id),
         :ok <- delete_file(attachment_local_path(attachment)),
         {:ok, _} <- Messages.delete_attachment(attachment_id) do
      Logger.info("Attachment deleted", attachment_id: attachment_id, domain: :attachment)

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
        Logger.error("Delete failed", reason: inspect(reason), domain: :attachment)

        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Delete failed"})
    end
  end

  ####################################################################################################
  ## Private functions
  ####################################################################################################

  # NOTE: AttachmentRendering / AttachmentValidation aliases are declared at
  # the top of the module so they're visible to all the wrappers below.

  # Validation helpers are factored out into AttachmentValidation for
  # testability. Local thin wrappers keep call sites unchanged.

  defp validate_file_size(upload), do: AttachmentValidation.validate_file_size(upload)
  defp validate_mime_type(mime_type), do: AttachmentValidation.validate_mime_type(mime_type)

  defp validate_user_permission(message, user_id),
    do: AttachmentValidation.validate_user_permission(message, user_id)

  defp validate_user_access(message, user_id),
    do: AttachmentValidation.validate_user_access(message, user_id)

  defp save_file(upload) do
    # Ensure upload directory exists
    File.mkdir_p!(@upload_dir)

    # Generate unique filename. The extension is taken from the client-supplied
    # filename, so we strip everything but alphanumerics to avoid path
    # traversal sequences (Sobelow Traversal.FileModule) — the file body itself
    # is identified by the random UUID, so the extension is purely cosmetic.
    file_extension = sanitize_extension(Path.extname(upload.filename))
    unique_filename = "#{Ecto.UUID.generate()}#{file_extension}"
    file_path = Path.join(@upload_dir, unique_filename)
    file_url = "/uploads/#{unique_filename}"

    # Defense-in-depth: ensure the resolved destination still lives under
    # @upload_dir even if the sanitizer ever lets something through.
    expanded_dest = Path.expand(file_path)
    expanded_root = Path.expand(@upload_dir)

    if String.starts_with?(expanded_dest, expanded_root <> "/") do
      case File.cp(upload.path, file_path) do
        :ok -> {:ok, file_path, file_url}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :invalid_path}
    end
  end

  defp sanitize_extension("." <> rest) do
    cleaned = String.replace(rest, ~r/[^A-Za-z0-9]/, "")

    case cleaned do
      "" -> ""
      ext -> "." <> ext
    end
  end

  defp sanitize_extension(_), do: ""

  defp create_attachment_record(message_id, upload, file_path, file_url) do
    {:ok, %{size: file_size}} = File.stat(file_path)

    Messages.create_attachment(%{
      message_id: message_id,
      filename: upload.filename,
      file_type:
        upload.content_type |> String.split("/") |> List.first() |> normalize_file_type(),
      storage_url: file_url,
      file_size: file_size,
      mime_type: upload.content_type
    })
  end

  defp read_file(file_path), do: AttachmentValidation.read_file(file_path)

  defp delete_file(file_path), do: AttachmentValidation.delete_file(file_path)

  # Reconstructs the local filesystem path from an attachment's `storage_url`
  # (which is the request-path form like "/uploads/<uuid>.png"). The schema
  # does not carry the local path separately so we derive it from the URL.
  defp attachment_local_path(%{storage_url: "/uploads/" <> rest}),
    do: Path.join(@upload_dir, rest)

  defp attachment_local_path(%{storage_url: url}), do: url

  defp normalize_file_type(type), do: AttachmentValidation.normalize_file_type(type)

  defp render_attachment(attachment), do: AttachmentRendering.render(attachment)

  @doc """
  Lists attachments for a specific message.
  GET /api/v1/messages/:id/attachments
  """
  def list_by_message(conn, %{"id" => message_id}) do
    with {:ok, _message} <- Messages.get_message(message_id) do
      attachments = Messages.list_message_attachments(message_id)

      json(conn, %{
        data: Enum.map(attachments, &render_attachment/1),
        meta:
          camelize_keys(%{
            message_id: message_id,
            count: length(attachments)
          })
      })
    end
  end

  @doc """
  Creates an attachment record from JSON metadata (file already uploaded to media-service).
  POST /api/messages/:message_id/attachments
  """
  def create_from_metadata(conn, %{"message_id" => message_id} = params) do
    params
    |> build_attachment_attrs(message_id)
    |> then(&save_attachment(conn, &1))
  end

  defp build_attachment_attrs(params, message_id),
    do: AttachmentRendering.build_attachment_attrs(params, message_id)

  defp save_attachment(conn, attrs) do
    case Messages.create_attachment(attrs) do
      {:ok, attachment} ->
        conn
        |> put_status(:created)
        |> json(%{data: render_attachment(attachment)})

      {:error, changeset} ->
        Logger.error("Create from metadata failed",
          errors: inspect(changeset.errors),
          domain: :attachment
        )

        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to create attachment"})
    end
  end
end
