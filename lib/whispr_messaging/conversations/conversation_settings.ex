defmodule WhisprMessaging.Conversations.ConversationSettings do
  @moduledoc """
  Ecto schema for conversation-level settings.

  Stores configuration and preferences that apply to the entire conversation,
  such as encryption settings, retention policies, and moderation rules.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias WhisprMessaging.Conversations.Conversation

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "conversation_settings" do
    field :settings, :map, default: %{}

    belongs_to :conversation, Conversation, foreign_key: :conversation_id

    timestamps()
  end

  @doc """
  Creates a changeset for conversation settings.
  """
  def changeset(settings, attrs) do
    settings
    |> cast(attrs, [:conversation_id, :settings])
    |> validate_required([:conversation_id, :settings])
    |> validate_settings()
    |> unique_constraint(:conversation_id)
  end

  @doc """
  Changeset for updating settings.
  """
  def update_settings_changeset(settings, new_settings) do
    settings
    |> cast(%{settings: new_settings}, [:settings])
    |> validate_settings()
  end

  @doc """
  Query to get settings by conversation ID.
  """
  def by_conversation_query(conversation_id) do
    from s in __MODULE__,
      where: s.conversation_id == ^conversation_id
  end

  @doc """
  Creates conversation settings.
  """
  def create_settings(conversation_id, settings \\ %{}) do
    %__MODULE__{}
    |> changeset(%{
      conversation_id: conversation_id,
      settings: Map.merge(default_settings(), settings)
    })
  end

  @doc """
  Default settings for a conversation.
  """
  def default_settings do
    %{
      # Message settings
      "allow_editing" => true,
      # 24 hours in seconds
      "edit_time_limit" => 86400,
      "allow_deletion" => true,
      # 48 hours in seconds
      "delete_time_limit" => 172_800,
      "delete_for_everyone_enabled" => true,

      # Media settings
      "allow_media" => true,
      # 100MB in bytes
      "max_file_size" => 104_857_600,
      "allowed_file_types" => ["image", "video", "audio", "document"],

      # Reaction settings
      "allow_reactions" => true,
      "custom_reactions" => false,

      # Privacy settings
      "encryption_enabled" => true,
      "forward_secrecy" => true,
      "disappearing_messages" => false,
      # 7 days in seconds
      "disappearing_timer" => 604_800,

      # Moderation settings
      "spam_protection" => true,
      "rate_limit_enabled" => true,
      "max_messages_per_minute" => 30,
      "profanity_filter" => false,

      # Notification settings
      "push_notifications" => true,
      "mention_notifications" => true,
      "typing_indicators" => true,
      "read_receipts" => true,

      # Retention settings
      # 0 = infinite, otherwise days
      "message_retention" => 0,
      # days
      "media_retention" => 365,
      "auto_cleanup" => false,

      # Group settings (for group conversations)
      "admin_only_invite" => false,
      "admin_only_settings" => true,
      "member_can_add_others" => true,
      "member_can_remove_others" => false,

      # Integration settings
      "bot_interactions" => true,
      "external_integrations" => false,
      "webhook_enabled" => false
    }
  end

  @doc """
  Validates settings structure and values.
  """
  defp validate_settings(%Ecto.Changeset{} = changeset) do
    settings = get_field(changeset, :settings) || %{}

    changeset
    |> validate_settings_map(settings)
    |> validate_time_limits(settings)
    |> validate_file_settings(settings)
    |> validate_rate_limits(settings)
  end

  defp validate_settings_map(changeset, settings) do
    if is_map(settings) do
      changeset
    else
      add_error(changeset, :settings, "must be a map")
    end
  end

  defp validate_time_limits(changeset, settings) do
    changeset
    |> validate_positive_integer(settings, "edit_time_limit")
    |> validate_positive_integer(settings, "delete_time_limit")
    |> validate_positive_integer(settings, "disappearing_timer")
    |> validate_positive_integer(settings, "message_retention")
    |> validate_positive_integer(settings, "media_retention")
  end

  defp validate_file_settings(changeset, settings) do
    changeset
    |> validate_positive_integer(settings, "max_file_size")
    |> validate_file_types(settings)
  end

  defp validate_rate_limits(changeset, settings) do
    changeset
    |> validate_positive_integer(settings, "max_messages_per_minute")
  end

  defp validate_positive_integer(changeset, settings, key) do
    case Map.get(settings, key) do
      value when is_integer(value) and value >= 0 ->
        changeset

      value when not is_nil(value) ->
        add_error(changeset, :settings, "#{key} must be a non-negative integer")

      _ ->
        changeset
    end
  end

  defp validate_file_types(changeset, settings) do
    case Map.get(settings, "allowed_file_types") do
      types when is_list(types) ->
        valid_types = ["image", "video", "audio", "document", "text"]

        if Enum.all?(types, &(&1 in valid_types)) do
          changeset
        else
          add_error(changeset, :settings, "allowed_file_types contains invalid file types")
        end

      nil ->
        changeset

      _ ->
        add_error(changeset, :settings, "allowed_file_types must be a list")
    end
  end

  @doc """
  Gets a setting value safely.
  """
  def get_setting(%__MODULE__{settings: settings}, key, default \\ nil) do
    Map.get(settings, key, Map.get(default_settings(), key, default))
  end

  @doc """
  Updates a specific setting.
  """
  def put_setting(%__MODULE__{settings: settings} = conv_settings, key, value) do
    new_settings = Map.put(settings, key, value)
    %{conv_settings | settings: new_settings}
  end

  @doc """
  Checks if editing is allowed based on settings and message age.
  """
  def editing_allowed?(%__MODULE__{} = conv_settings, message_age_seconds) do
    if get_setting(conv_settings, "allow_editing", true) do
      time_limit = get_setting(conv_settings, "edit_time_limit", 86400)
      message_age_seconds <= time_limit
    else
      false
    end
  end

  @doc """
  Checks if deletion is allowed based on settings and message age.
  """
  def deletion_allowed?(%__MODULE__{} = conv_settings, message_age_seconds) do
    if get_setting(conv_settings, "allow_deletion", true) do
      time_limit = get_setting(conv_settings, "delete_time_limit", 172_800)
      message_age_seconds <= time_limit
    else
      false
    end
  end

  @doc """
  Checks if delete for everyone is enabled.
  """
  def delete_for_everyone_enabled?(%__MODULE__{} = conv_settings) do
    get_setting(conv_settings, "delete_for_everyone_enabled", true)
  end

  @doc """
  Checks if media uploads are allowed.
  """
  def media_allowed?(%__MODULE__{} = conv_settings) do
    get_setting(conv_settings, "allow_media", true)
  end

  @doc """
  Gets the maximum allowed file size.
  """
  def max_file_size(%__MODULE__{} = conv_settings) do
    get_setting(conv_settings, "max_file_size", 104_857_600)
  end

  @doc """
  Checks if a file type is allowed.
  """
  def file_type_allowed?(%__MODULE__{} = conv_settings, file_type) do
    allowed_types =
      get_setting(conv_settings, "allowed_file_types", ["image", "video", "audio", "document"])

    file_type in allowed_types
  end

  @doc """
  Gets rate limiting settings.
  """
  def get_rate_limit(%__MODULE__{} = conv_settings) do
    %{
      enabled: get_setting(conv_settings, "rate_limit_enabled", true),
      max_messages_per_minute: get_setting(conv_settings, "max_messages_per_minute", 30)
    }
  end

  @doc """
  Checks if disappearing messages are enabled.
  """
  def disappearing_messages_enabled?(%__MODULE__{} = conv_settings) do
    get_setting(conv_settings, "disappearing_messages", false)
  end

  @doc """
  Gets the disappearing message timer in seconds.
  """
  def disappearing_timer(%__MODULE__{} = conv_settings) do
    get_setting(conv_settings, "disappearing_timer", 604_800)
  end
end
