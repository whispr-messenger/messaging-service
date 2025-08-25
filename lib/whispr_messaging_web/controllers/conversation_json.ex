defmodule WhisprMessagingWeb.ConversationJSON do
  @moduledoc """
  Vue JSON pour les conversations
  """

  alias WhisprMessaging.Conversations.Conversation

  @doc """
  Renders a list of conversations.
  """
  def index(%{conversations: conversations}) do
    %{data: for(conversation <- conversations, do: data(conversation))}
  end

  @doc """
  Renders a single conversation.
  """
  def show(%{conversation: conversation}) do
    %{data: data(conversation)}
  end

  @doc """
  Renders unread statistics.
  """
  def unread_stats(%{unread_conversations: unread_conversations}) do
    %{
      data: %{
        total_unread_conversations: length(unread_conversations),
        conversations: unread_conversations
      }
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

  defp data(%Conversation{} = conversation) do
    %{
      id: conversation.id,
      type: conversation.type,
      external_group_id: conversation.external_group_id,
      metadata: conversation.metadata,
      is_active: conversation.is_active,
      created_at: conversation.inserted_at,
      updated_at: conversation.updated_at,
      members: render_members(conversation),
      settings: render_settings(conversation)
    }
  end

  defp render_members(%Conversation{members: members}) when is_list(members) do
    Enum.map(members, fn member ->
      %{
        id: member.id,
        user_id: member.user_id,
        settings: member.settings,
        joined_at: member.joined_at,
        last_read_at: member.last_read_at,
        is_active: member.is_active
      }
    end)
  end
  defp render_members(_), do: []

  defp render_settings(%Conversation{settings: %{settings: settings}}) when is_map(settings) do
    settings
  end
  defp render_settings(%Conversation{settings: settings}) when not is_nil(settings) do
    settings.settings || %{}
  end
  defp render_settings(_), do: %{}

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
