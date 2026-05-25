defmodule WhisprMessaging.Messages.Serializer do
  @moduledoc """
  Serialisation canonique d'un message vers une map.

  Centralise la logique partagee entre la voie HTTP (`MessageController`)
  et la voie WebSocket (`ConversationServer`) pour garantir une shape
  identique quel que soit le transport.

  Pour les messages E2EE (content_format = "olm_v1") :
  - `content` est nil
  - `ciphertext` contient le blob Olm encode en Base64
  - `format` indique "olm_v1"

  Pour les messages plaintext :
  - `content` contient le binaire encode en Base64 si non-UTF8
  - `ciphertext` est nil
  - `format` est "plaintext"
  """

  alias WhisprMessaging.Messages.{DeliveryStatus, Message}

  import WhisprMessagingWeb.JsonHelpers, only: [camelize_keys: 1]

  @doc """
  Serialise un message en map camelCase.
  """
  def serialize(%Message{} = message) do
    base = %{
      id: message.id,
      conversation_id: message.conversation_id,
      sender_id: message.sender_id,
      reply_to_id: Map.get(message, :reply_to_id),
      forwarded_from_id: Map.get(message, :forwarded_from_id),
      message_type: message.message_type,
      content:
        if(message.content_format != "olm_v1", do: safe_binary(message.content), else: nil),
      ciphertext:
        if(message.content_format == "olm_v1", do: safe_binary(message.ciphertext), else: nil),
      format: message.content_format || "plaintext",
      metadata: message.metadata,
      client_random: message.client_random,
      is_edited: message.edited_at != nil,
      edited_at: message.edited_at,
      is_deleted: message.is_deleted,
      delete_for_everyone: Map.get(message, :delete_for_everyone, false),
      is_ephemeral: not is_nil(message.expires_at),
      expires_at: message.expires_at,
      sent_at: message.sent_at
    }

    result =
      case message do
        %{delivery_statuses: statuses} when is_list(statuses) ->
          Map.put(base, :delivery_status, DeliveryStatus.compute_aggregate_status(statuses))

        _ ->
          Map.put(base, :delivery_status, "sent")
      end

    result =
      case message do
        %{reply_to: %Message{} = parent} ->
          Map.put(result, :reply_to, serialize_reply_context(parent))

        _ ->
          result
      end

    camelize_keys(result)
  end

  defp serialize_reply_context(%Message{} = parent) do
    %{
      id: parent.id,
      sender_id: parent.sender_id,
      content: if(parent.content_format != "olm_v1", do: safe_binary(parent.content), else: nil),
      ciphertext:
        if(parent.content_format == "olm_v1", do: safe_binary(parent.ciphertext), else: nil),
      format: parent.content_format || "plaintext",
      message_type: parent.message_type,
      is_deleted: parent.is_deleted
    }
  end

  defp safe_binary(nil), do: nil

  defp safe_binary(content) when is_binary(content) do
    if String.valid?(content), do: content, else: Base.encode64(content)
  end

  defp safe_binary(content), do: to_string(content)
end
