defmodule MedicaidClaimsChecker.Repo.Migrations.CreateAppSettings do
  use Ecto.Migration

  def change do
    create table(:app_settings, primary_key: false) do
      add :key, :string, primary_key: true
      add :registration_open, :boolean, default: true, null: false
      timestamps(type: :utc_datetime)
    end

    execute(
      "INSERT INTO app_settings (key, registration_open, inserted_at, updated_at) VALUES ('singleton', true, now(), now())",
      "DELETE FROM app_settings WHERE key = 'singleton'"
    )
  end
end
