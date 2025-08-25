defmodule WhisprMessaging.Conversations.ConversationSettings do
  @moduledoc """
  Schéma pour les paramètres de conversation selon la documentation database_design.md
  """
  use Ecto.Schema
  import Ecto.Changeset
  
  alias WhisprMessaging.Conversations.Conversation

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "conversation_settings" do
    field :settings, :map, default: %{}
    field :updated_at, :utc_datetime

    belongs_to :conversation, Conversation
  end

  @default_settings %{
    "notifications" => true,
    "retention_days" => nil,
    "auto_delete_media" => false,
    "allow_reactions" => true,
    "allow_replies" => true,
    "read_receipts" => true,
    "typing_indicators" => true
  }

  @doc """
  Changeset pour créer ou modifier les paramètres de conversation
  """
  def changeset(settings, attrs) do
    settings
    |> cast(attrs, [:conversation_id, :settings])
    |> validate_required([:conversation_id])
    |> unique_constraint(:conversation_id)
    |> put_default_settings_if_empty()
    |> put_updated_at()
    |> validate_settings_structure()
  end

  @doc """
  Changeset pour créer les paramètres par défaut d'une conversation
  """
  def default_changeset(conversation_id) do
    %__MODULE__{}
    |> changeset(%{
      conversation_id: conversation_id,
      settings: @default_settings
    })
  end

  @doc """
  Changeset pour mettre à jour un paramètre spécifique
  """
  def update_setting_changeset(conversation_settings, key, value) do
    current_settings = conversation_settings.settings || %{}
    new_settings = Map.put(current_settings, key, value)
    
    conversation_settings
    |> changeset(%{settings: new_settings})
  end

  @doc """
  Changeset pour mettre à jour plusieurs paramètres
  """
  def update_settings_changeset(conversation_settings, new_settings) do
    current_settings = conversation_settings.settings || %{}
    merged_settings = Map.merge(current_settings, new_settings)
    
    conversation_settings
    |> changeset(%{settings: merged_settings})
  end

  @doc """
  Récupère la valeur d'un paramètre ou la valeur par défaut
  """
  def get_setting(conversation_settings, key, default \\ nil) do
    settings = conversation_settings.settings || %{}
    Map.get(settings, key, Map.get(@default_settings, key, default))
  end

  @doc """
  Paramètres par défaut
  """
  def default_settings, do: @default_settings

  defp put_default_settings_if_empty(changeset) do
    case get_field(changeset, :settings) do
      settings when is_map(settings) and map_size(settings) > 0 ->
        changeset
      _ ->
        put_change(changeset, :settings, @default_settings)
    end
  end

  defp put_updated_at(changeset) do
    put_change(changeset, :updated_at, DateTime.utc_now())
  end

  defp validate_settings_structure(changeset) do
    case get_field(changeset, :settings) do
      settings when is_map(settings) ->
        validate_individual_settings(changeset, settings)
      _ ->
        add_error(changeset, :settings, "must be a valid map")
    end
  end

  defp validate_individual_settings(changeset, settings) do
    Enum.reduce(settings, changeset, fn {key, value}, acc ->
      validate_setting_value(acc, key, value)
    end)
  end

  defp validate_setting_value(changeset, key, value) do
    case key do
      "notifications" when is_boolean(value) -> changeset
      "retention_days" when is_nil(value) or is_integer(value) -> changeset
      "auto_delete_media" when is_boolean(value) -> changeset
      "allow_reactions" when is_boolean(value) -> changeset
      "allow_replies" when is_boolean(value) -> changeset
      "read_receipts" when is_boolean(value) -> changeset
      "typing_indicators" when is_boolean(value) -> changeset
      
      # Paramètres personnalisés autorisés mais non validés spécifiquement
      custom_key when is_binary(custom_key) -> changeset
      
      _ ->
        add_error(changeset, :settings, "invalid setting: #{key} with value #{inspect(value)}")
    end
  end
end
