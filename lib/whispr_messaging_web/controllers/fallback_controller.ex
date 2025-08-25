defmodule WhisprMessagingWeb.FallbackController do
  @moduledoc """
  Contrôleur de fallback pour gérer les erreurs communes
  """
  use WhisprMessagingWeb, :controller

  # This clause handles errors returned by Ecto's insert/update/delete.
  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: WhisprMessagingWeb.ChangesetJSON)
    |> render(:error, changeset: changeset)
  end

  # This clause is an example of how to handle resources that cannot be found.
  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> put_view(json: WhisprMessagingWeb.ErrorJSON)
    |> render(:"404")
  end

  # This clause handles unauthorized access
  def call(conn, {:error, :unauthorized}) do
    conn
    |> put_status(:unauthorized)
    |> put_view(json: WhisprMessagingWeb.ErrorJSON)
    |> render(:"401")
  end

  # This clause handles forbidden access
  def call(conn, {:error, :forbidden}) do
    conn
    |> put_status(:forbidden)
    |> put_view(json: WhisprMessagingWeb.ErrorJSON)
    |> render(:"403")
  end
end
