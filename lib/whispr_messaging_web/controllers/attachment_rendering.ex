defmodule WhisprMessagingWeb.AttachmentRendering do
  @moduledoc """
  Rendering helpers extracted from `AttachmentController` so the pure
  attribute-shaping functions can be unit-tested in isolation. External REST
  contract is unchanged.
  """

  alias WhisprMessagingWeb.JsonHelpers

  @doc """
  Renders an `Attachment` (or attachment-shaped map) into the public
  camelCase JSON representation.
  """
  @spec render(map()) :: map()
  def render(attachment) do
    meta = attachment.metadata || %{}

    JsonHelpers.camelize_keys(%{
      id: attachment.id,
      message_id: attachment.message_id,
      media_id: meta["media_id"],
      file_name: attachment.filename,
      file_type: attachment.file_type,
      file_url: attachment.storage_url,
      file_size: attachment.file_size,
      mime_type: attachment.mime_type,
      thumbnail_url: attachment.thumbnail_url,
      metadata: meta,
      uploaded_at: attachment.inserted_at
    })
  end

  @doc """
  Builds the `Messages.create_attachment/1` attrs from a JSON metadata
  payload. Merges `params["metadata"]` over `params` and applies defaults so
  required fields are always present.
  """
  @spec build_attachment_attrs(map(), String.t()) :: map()
  def build_attachment_attrs(params, message_id) do
    meta = params["metadata"] || %{}
    merged = Map.merge(meta, params)

    %{
      message_id: message_id,
      filename: merged["filename"] || "file",
      file_type: merged["media_type"] || "image",
      mime_type: merged["mime_type"] || "application/octet-stream",
      file_size: merged["size"] || 0,
      storage_url: merged["media_url"] || "",
      thumbnail_url: merged["thumbnail_url"],
      metadata: meta
    }
  end
end
