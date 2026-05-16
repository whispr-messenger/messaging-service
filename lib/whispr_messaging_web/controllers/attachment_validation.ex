defmodule WhisprMessagingWeb.AttachmentValidation do
  @moduledoc """
  Validation and normalization helpers extracted from `AttachmentController`
  so the small pure functions can be unit-tested in isolation. External REST
  contract is unchanged.
  """

  alias WhisprMessaging.Messages

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

  @doc "Returns :ok when the file at `upload.path` is at most 50MB."
  @spec validate_file_size(%{path: String.t()}) :: :ok | {:error, atom()}
  def validate_file_size(%{path: path}) do
    case File.stat(path) do
      {:ok, %{size: size}} when size <= @max_file_size -> :ok
      {:ok, %{size: _}} -> {:error, :file_too_large}
      {:error, _} -> {:error, :file_stat_failed}
    end
  end

  @doc "Returns :ok when the MIME type is in the allowlist."
  @spec validate_mime_type(String.t() | nil) :: :ok | {:error, :invalid_mime_type}
  def validate_mime_type(mime_type) when mime_type in @allowed_mime_types, do: :ok
  def validate_mime_type(_), do: {:error, :invalid_mime_type}

  @doc "The message can be uploaded against if the caller is the sender."
  @spec validate_user_permission(map(), String.t() | nil) :: :ok | {:error, :unauthorized}
  def validate_user_permission(%{sender_id: sender_id}, user_id) when sender_id == user_id,
    do: :ok

  def validate_user_permission(_, _), do: {:error, :unauthorized}

  @doc """
  The message can be downloaded by any member of the conversation it belongs
  to.
  """
  @spec validate_user_access(map(), String.t() | nil) :: :ok | {:error, :unauthorized}
  def validate_user_access(message, user_id) do
    case Messages.user_can_access_message?(message.conversation_id, user_id) do
      true -> :ok
      false -> {:error, :unauthorized}
    end
  end

  @doc """
  Normalizes the leading segment of a MIME type into the file_type enum used
  in the attachments table.
  """
  @spec normalize_file_type(String.t() | nil) :: String.t()
  def normalize_file_type(type) when type in ["image", "video", "audio"], do: type
  def normalize_file_type("application"), do: "document"
  def normalize_file_type("text"), do: "document"
  def normalize_file_type(_), do: "document"

  @doc "Public accessor for the allowlist (tests + introspection)."
  @spec allowed_mime_types() :: [String.t()]
  def allowed_mime_types, do: @allowed_mime_types

  @doc "Public accessor for the max upload size."
  @spec max_file_size() :: pos_integer()
  def max_file_size, do: @max_file_size

  @doc """
  Reads a file's content. Maps `{:error, :enoent}` to `:file_not_found`
  for a stable error API; other errors pass through.
  """
  @spec read_file(String.t()) :: {:ok, binary()} | {:error, atom()}
  def read_file(file_path) do
    case File.read(file_path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:error, :file_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Deletes a file. Treats `:enoent` as a no-op success (file already gone),
  otherwise returns the underlying error.
  """
  @spec delete_file(String.t()) :: :ok | {:error, atom()}
  def delete_file(file_path) do
    case File.rm(file_path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
