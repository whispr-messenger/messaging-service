defmodule WhisprMessagingWeb.MessageJSON do
  @moduledoc """
  Vue JSON pour les messages
  """

  alias WhisprMessaging.Messages.{Message, PinnedMessage}

  @doc """
  Renders a list of messages.
  """
  def index(%{messages: messages}) do
    %{data: for(message <- messages, do: data(message))}
  end

  @doc """
  Renders a single message.
  """
  def show(%{message: message}) do
    %{data: data(message)}
  end

  @doc """
  Renders pinned messages.
  """
  def pinned_messages(%{pinned_messages: pinned_messages}) do
    %{
      data: for(pinned <- pinned_messages, do: pinned_message_data(pinned))
    }
  end

  @doc """
  Renders error responses.
  """
  def error(%{errors: errors}) do
    %{errors: errors}
  end

  def error(%{changeset: changeset}) do
    %{
      errors: Ecto.Changeset.traverse_errors(changeset, &translate_error/1)
    }
  end

  defp data(%Message{} = message) do
    %{
      id: message.id,
      conversation_id: message.conversation_id,
      sender_id: message.sender_id,
      reply_to_id: message.reply_to_id,
      message_type: message.message_type,
      content: encode_content_for_client(message.content),
      metadata: message.metadata,
      client_random: message.client_random,
      sent_at: message.sent_at,
      edited_at: message.edited_at,
      is_deleted: message.is_deleted,
      delete_for_everyone: message.delete_for_everyone,
      delivery_statuses: render_delivery_statuses(message),
      reactions: render_reactions(message),
      attachments: render_attachments(message),
      created_at: message.inserted_at,
      updated_at: message.updated_at
    }
  end

  defp pinned_message_data(%PinnedMessage{} = pinned) do
    %{
      id: pinned.id,
      conversation_id: pinned.conversation_id,
      message_id: pinned.message_id,
      pinned_by: pinned.pinned_by,
      pinned_at: pinned.pinned_at,
      message: if(pinned.message, do: data(pinned.message), else: nil)
    }
  end

  defp render_delivery_statuses(%Message{delivery_statuses: statuses}) when is_list(statuses) do
    Enum.map(statuses, fn status ->
      %{
        id: status.id,
        user_id: status.user_id,
        delivered_at: status.delivered_at,
        read_at: status.read_at
      }
    end)
  end
  defp render_delivery_statuses(_), do: []

  defp render_reactions(%Message{reactions: reactions}) when is_list(reactions) do
    Enum.map(reactions, fn reaction ->
      %{
        id: reaction.id,
        user_id: reaction.user_id,
        reaction: reaction.reaction,
        created_at: reaction.created_at
      }
    end)
  end
  defp render_reactions(_), do: []

  defp render_attachments(%Message{attachments: attachments}) when is_list(attachments) do
    Enum.map(attachments, fn attachment ->
      %{
        id: attachment.id,
        media_id: attachment.media_id,
        media_type: attachment.media_type,
        metadata: attachment.metadata,
        created_at: attachment.created_at
      }
    end)
  end
  defp render_attachments(_), do: []

  # Dans la vraie implémentation, le contenu reste chiffré
  # Ici on le convertit en string pour les tests
  defp encode_content_for_client(content) when is_binary(content) do
    # Pour l'instant, on retourne le contenu tel quel
    # Dans la vraie implémentation, on pourrait encoder en base64 si nécessaire
    Base.encode64(content)
  end

  defp translate_error({msg, opts}) do
    # You can make use of gettext to translate error messages by
    # uncommenting and adjusting the following code:

    # if count = opts[:count] do
    #   Gettext.dngettext(WhisprMessagingWeb.Gettext, "errors", msg, msg, count, opts)
    # else
    #   Gettext.dgettext(WhisprMessagingWeb.Gettext, "errors", msg, opts)
    # end

    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end
end
