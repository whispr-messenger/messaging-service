defmodule WhisprMessaging.Moderation.Report do
  @moduledoc """
  Ecto schema for moderation reports.

  A report is created when a user flags a message or another user
  for violating community guidelines.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias WhisprMessaging.Conversations.Conversation
  alias WhisprMessaging.Messages.Message

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_categories ~w(offensive spam nudity violence harassment other)
  @valid_statuses ~w(pending under_review resolved_action resolved_dismissed)

  schema "reports" do
    field :reporter_id, :binary_id
    field :reported_user_id, :binary_id
    field :category, :string
    field :description, :string
    field :evidence, :map, default: %{}
    field :status, :string, default: "pending"
    field :resolution, :map
    field :auto_escalated, :boolean, default: false

    belongs_to :conversation, Conversation
    belongs_to :message, Message

    timestamps()
  end

  @required_fields ~w(reporter_id reported_user_id category)a
  @optional_fields ~w(conversation_id message_id description evidence)a

  def changeset(report, attrs) do
    report
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:category, @valid_categories)
    |> validate_no_self_report()
    |> foreign_key_constraint(:conversation_id)
    |> foreign_key_constraint(:message_id)
  end

  def resolve_changeset(report, attrs) do
    report
    |> cast(attrs, [:status, :resolution])
    |> validate_required([:status, :resolution])
    |> validate_inclusion(:status, ~w(resolved_action resolved_dismissed))
  end

  def status_changeset(report, status) do
    report
    |> change(%{status: status})
    |> validate_inclusion(:status, @valid_statuses)
  end

  # Queries

  def by_reporter(query \\ __MODULE__, reporter_id) do
    from r in query, where: r.reporter_id == ^reporter_id, order_by: [desc: r.inserted_at]
  end

  def by_reported_user(query \\ __MODULE__, reported_user_id) do
    from r in query, where: r.reported_user_id == ^reported_user_id
  end

  def by_status(query \\ __MODULE__, status) do
    from r in query, where: r.status == ^status
  end

  def pending(query \\ __MODULE__) do
    by_status(query, "pending")
  end

  def recent_for_user(query \\ __MODULE__, reported_user_id, days) do
    cutoff = DateTime.utc_now() |> DateTime.add(-days * 86_400, :second)

    from r in query,
      where: r.reported_user_id == ^reported_user_id and r.inserted_at >= ^cutoff,
      select: r
  end

  def unique_reporters_count(reported_user_id, days) do
    cutoff = DateTime.utc_now() |> DateTime.add(-days * 86_400, :second)

    from r in __MODULE__,
      where: r.reported_user_id == ^reported_user_id and r.inserted_at >= ^cutoff,
      select: count(r.reporter_id, :distinct)
  end

  def valid_categories, do: @valid_categories
  def valid_statuses, do: @valid_statuses

  # Private

  defp validate_no_self_report(changeset) do
    reporter = get_field(changeset, :reporter_id)
    reported = get_field(changeset, :reported_user_id)

    if reporter && reported && reporter == reported do
      add_error(changeset, :reported_user_id, "cannot report yourself")
    else
      changeset
    end
  end
end
