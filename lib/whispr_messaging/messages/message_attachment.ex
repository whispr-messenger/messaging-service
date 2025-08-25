defmodule WhisprMessaging.Messages.MessageAttachment do
  @moduledoc """
  Schéma pour les pièces jointes des messages selon la documentation database_design.md
  """
  use Ecto.Schema
  import Ecto.Changeset
  
  alias WhisprMessaging.Messages.Message

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "message_attachments" do
    field :media_id, :binary_id
    field :media_type, :string
    field :metadata, :map, default: %{}
    field :created_at, :utc_datetime

    belongs_to :message, Message
  end

  @valid_media_types [
    "image/jpeg", "image/png", "image/gif", "image/webp",
    "video/mp4", "video/webm", "video/quicktime",
    "audio/mp3", "audio/wav", "audio/ogg", "audio/aac",
    "application/pdf", "application/msword", 
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "text/plain"
  ]

  @doc """
  Changeset pour créer ou modifier une pièce jointe
  """
  def changeset(attachment, attrs) do
    attachment
    |> cast(attrs, [:message_id, :media_id, :media_type, :metadata])
    |> validate_required([:message_id, :media_id, :media_type])
    |> validate_inclusion(:media_type, @valid_media_types)
    |> validate_metadata_for_media_type()
    |> put_created_at_if_new()
  end

  @doc """
  Changeset pour créer une nouvelle pièce jointe
  """
  def create_changeset(message_id, media_id, media_type, metadata \\ %{}) do
    %__MODULE__{}
    |> changeset(%{
      message_id: message_id,
      media_id: media_id,
      media_type: media_type,
      metadata: metadata
    })
    |> put_change(:created_at, DateTime.utc_now())
  end

  @doc """
  Liste des types de médias valides
  """
  def valid_media_types, do: @valid_media_types

  @doc """
  Détermine si un type de média est une image
  """
  def is_image?(media_type), do: String.starts_with?(media_type, "image/")

  @doc """
  Détermine si un type de média est une vidéo
  """
  def is_video?(media_type), do: String.starts_with?(media_type, "video/")

  @doc """
  Détermine si un type de média est un audio
  """
  def is_audio?(media_type), do: String.starts_with?(media_type, "audio/")

  @doc """
  Détermine si un type de média est un document
  """
  def is_document?(media_type) do
    String.starts_with?(media_type, "application/") or 
    String.starts_with?(media_type, "text/")
  end

  defp put_created_at_if_new(changeset) do
    case get_field(changeset, :created_at) do
      nil -> put_change(changeset, :created_at, DateTime.utc_now())
      _ -> changeset
    end
  end

  defp validate_metadata_for_media_type(changeset) do
    media_type = get_field(changeset, :media_type)
    metadata = get_field(changeset, :metadata)
    
    case {media_type, metadata} do
      {nil, _} -> changeset
      {_, metadata} when not is_map(metadata) ->
        add_error(changeset, :metadata, "must be a valid map")
      
      {media_type, metadata} when is_binary(media_type) ->
        validate_specific_metadata(changeset, media_type, metadata)
    end
  end

  defp validate_specific_metadata(changeset, media_type, metadata) do
    cond do
      is_image?(media_type) ->
        validate_image_metadata(changeset, metadata)
      
      is_video?(media_type) ->
        validate_video_metadata(changeset, metadata)
      
      is_audio?(media_type) ->
        validate_audio_metadata(changeset, metadata)
      
      true ->
        changeset
    end
  end

  defp validate_image_metadata(changeset, metadata) do
    required_fields = ["width", "height", "file_size"]
    validate_metadata_fields(changeset, metadata, required_fields)
  end

  defp validate_video_metadata(changeset, metadata) do
    required_fields = ["width", "height", "duration", "file_size"]
    validate_metadata_fields(changeset, metadata, required_fields)
  end

  defp validate_audio_metadata(changeset, metadata) do
    required_fields = ["duration", "file_size"]
    validate_metadata_fields(changeset, metadata, required_fields)
  end

  defp validate_metadata_fields(changeset, metadata, required_fields) do
    missing_fields = Enum.filter(required_fields, fn field ->
      not Map.has_key?(metadata, field)
    end)
    
    if Enum.empty?(missing_fields) do
      changeset
    else
      add_error(changeset, :metadata, "missing required fields: #{Enum.join(missing_fields, ", ")}")
    end
  end
end
