defmodule WhisprMessaging.Messages.MessageAttachment do
  @moduledoc """
  Ecto schema for message attachments (files, images, videos, etc.).

  Stores metadata about files attached to messages, with actual file storage
  handled by external services (S3, CDN, etc.). Content is encrypted.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias WhisprMessaging.Messages.Message

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @file_types ~w(image video audio document)
  @max_filename_length 255

  schema "message_attachments" do
    field :filename, :string
    field :file_type, :string
    field :file_size, :integer
    field :mime_type, :string
    field :storage_url, :string
    field :thumbnail_url, :string
    field :metadata, :map, default: %{}
    field :encryption_key, :binary
    field :is_deleted, :boolean, default: false

    belongs_to :message, Message, foreign_key: :message_id

    timestamps()
  end

  @doc """
  Creates a changeset for message attachments.
  """
  def changeset(attachment, attrs) do
    attachment
    |> cast(attrs, [
      :message_id,
      :filename,
      :file_type,
      :file_size,
      :mime_type,
      :storage_url,
      :thumbnail_url,
      :metadata,
      :encryption_key
    ])
    |> validate_required([
      :message_id,
      :filename,
      :file_type,
      :file_size,
      :mime_type,
      :storage_url
    ])
    |> validate_inclusion(:file_type, @file_types)
    |> validate_length(:filename, max: @max_filename_length)
    |> validate_number(:file_size, greater_than: 0)
    |> validate_file_size()
    |> validate_metadata()
  end

  @doc """
  Changeset for soft deleting an attachment.
  """
  def delete_changeset(attachment) do
    attachment
    |> cast(%{is_deleted: true}, [:is_deleted])
  end

  @doc """
  Query to get attachments for a message.
  """
  def by_message_query(message_id) do
    from a in __MODULE__,
      where: a.message_id == ^message_id and a.is_deleted == false,
      order_by: [asc: a.inserted_at]
  end

  @doc """
  Query to get attachments by file type.
  """
  def by_file_type_query(message_id, file_type) do
    from a in __MODULE__,
      where: a.message_id == ^message_id,
      where: a.file_type == ^file_type,
      where: a.is_deleted == false,
      order_by: [asc: a.inserted_at]
  end

  @doc """
  Query to get total attachment size for a conversation.
  """
  def conversation_storage_size_query(conversation_id) do
    from a in __MODULE__,
      join: m in Message,
      on: m.id == a.message_id,
      where: m.conversation_id == ^conversation_id,
      where: a.is_deleted == false,
      select: sum(a.file_size)
  end

  @doc """
  Query to get attachments older than specified date (for cleanup).
  """
  def older_than_query(date) do
    from a in __MODULE__,
      where: a.inserted_at < ^date,
      where: a.is_deleted == false
  end

  @doc """
  Creates a new attachment.
  """
  def create_attachment(message_id, attrs) do
    %__MODULE__{}
    |> changeset(Map.put(attrs, :message_id, message_id))
  end

  @doc """
  Validates file size against application limits.
  """
  defp validate_file_size(%Ecto.Changeset{} = changeset) do
    file_size = get_field(changeset, :file_size)
    file_type = get_field(changeset, :file_type)

    max_size = get_max_file_size(file_type)

    if file_size && file_size > max_size do
      add_error(
        changeset,
        :file_size,
        "exceeds maximum size of #{max_size} bytes for #{file_type} files"
      )
    else
      changeset
    end
  end

  @doc """
  Validates attachment metadata structure.
  """
  defp validate_metadata(%Ecto.Changeset{} = changeset) do
    metadata = get_field(changeset, :metadata) || %{}

    if is_map(metadata) do
      changeset
    else
      add_error(changeset, :metadata, "must be a map")
    end
  end

  defp get_max_file_size(file_type) do
    # 100MB default
    Application.get_env(:whispr_messaging, :attachments)[:max_file_sizes][file_type] ||
      Application.get_env(:whispr_messaging, :attachments)[:default_max_size] ||
      104_857_600
  end

  @doc """
  Checks if attachment is an image.
  """
  def image?(%__MODULE__{file_type: "image"}), do: true
  def image?(_), do: false

  @doc """
  Checks if attachment is a video.
  """
  def video?(%__MODULE__{file_type: "video"}), do: true
  def video?(_), do: false

  @doc """
  Checks if attachment is audio.
  """
  def audio?(%__MODULE__{file_type: "audio"}), do: true
  def audio?(_), do: false

  @doc """
  Checks if attachment is a document.
  """
  def document?(%__MODULE__{file_type: "document"}), do: true
  def document?(_), do: false

  @doc """
  Checks if attachment has a thumbnail.
  """
  def has_thumbnail?(%__MODULE__{thumbnail_url: nil}), do: false
  def has_thumbnail?(%__MODULE__{thumbnail_url: ""}), do: false
  def has_thumbnail?(%__MODULE__{thumbnail_url: _}), do: true

  @doc """
  Gets attachment display name (filename without extension for privacy).
  """
  def display_name(%__MODULE__{filename: filename}) do
    Path.rootname(filename)
  end

  @doc """
  Gets file extension.
  """
  def file_extension(%__MODULE__{filename: filename}) do
    Path.extname(filename)
  end

  @doc """
  Gets human-readable file size.
  """
  def human_file_size(%__MODULE__{file_size: size}) do
    human_file_size(size)
  end

  def human_file_size(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 1)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 1)} KB"
      true -> "#{bytes} B"
    end
  end

  @doc """
  Gets metadata value safely.
  """
  def get_metadata(%__MODULE__{metadata: metadata}, key, default \\ nil) do
    Map.get(metadata, key, default)
  end

  @doc """
  Updates attachment metadata.
  """
  def put_metadata(%__MODULE__{metadata: metadata} = attachment, key, value) do
    new_metadata = Map.put(metadata, key, value)
    %{attachment | metadata: new_metadata}
  end

  @doc """
  Checks if attachment is deleted.
  """
  def deleted?(%__MODULE__{is_deleted: is_deleted}), do: is_deleted

  @doc """
  Gets image dimensions from metadata.
  """
  def image_dimensions(%__MODULE__{file_type: "image", metadata: metadata}) do
    case {Map.get(metadata, "width"), Map.get(metadata, "height")} do
      {width, height} when is_integer(width) and is_integer(height) ->
        {width, height}

      _ ->
        nil
    end
  end

  def image_dimensions(_), do: nil

  @doc """
  Gets video duration from metadata.
  """
  def video_duration(%__MODULE__{file_type: "video", metadata: metadata}) do
    case Map.get(metadata, "duration") do
      duration when is_number(duration) -> duration
      _ -> nil
    end
  end

  def video_duration(_), do: nil

  @doc """
  Gets audio duration from metadata.
  """
  def audio_duration(%__MODULE__{file_type: "audio", metadata: metadata}) do
    case Map.get(metadata, "duration") do
      duration when is_number(duration) -> duration
      _ -> nil
    end
  end

  def audio_duration(_), do: nil

  @doc """
  Checks if attachment requires processing (thumbnails, transcoding, etc.).
  """
  def requires_processing?(%__MODULE__{file_type: file_type})
      when file_type in ["image", "video"] do
    true
  end

  def requires_processing?(_), do: false

  @doc """
  Gets attachment URL with proper access controls.
  """
  def get_secure_url(%__MODULE__{storage_url: storage_url, encryption_key: encryption_key}) do
    # In a real implementation, this would generate a signed URL
    # with proper access controls and encryption key handling
    %{
      url: storage_url,
      requires_encryption_key: !is_nil(encryption_key),
      # 1 hour
      expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
    }
  end
end
