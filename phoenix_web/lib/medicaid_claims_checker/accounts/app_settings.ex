defmodule MedicaidClaimsChecker.Accounts.AppSettings do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:key, :string, autogenerate: false}
  schema "app_settings" do
    field :registration_open, :boolean, default: true
    timestamps(type: :utc_datetime)
  end

  def changeset(settings, attrs) do
    settings
    |> cast(attrs, [:registration_open])
    |> validate_required([:registration_open])
  end
end
