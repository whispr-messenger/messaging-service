defmodule WhisprMessaging.Accounts.User do
  @moduledoc """
  Projection locale des utilisateurs inscrits.

  Alimenté par le consumer Redis Stream `stream:user.registered`.
  Permet aux requetes internes (check_user_exists, conversations) de ne pas
  faire de RPC vers user-service pour chaque operation.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: false}
  @timestamps_opts [type: :utc_datetime]

  schema "users" do
    field :phone_number, :string

    timestamps()
  end

  @required [:id, :phone_number]

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(user, attrs) do
    user
    |> cast(attrs, @required)
    |> validate_required(@required)
    |> unique_constraint(:phone_number)
  end
end
