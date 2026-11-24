defmodule MedicaidClaimsChecker.Repo.Migrations.CreateFetchSourcesAndSchedules do
  use Ecto.Migration

  def change do
    create table(:fetch_sources) do
      add :name, :string, null: false
      add :uri, :string, null: false
      add :source_type, :string, null: false
      add :enabled, :boolean, default: true, null: false
      add :credentials, :map

      timestamps(type: :utc_datetime)
    end

    create unique_index(:fetch_sources, [:name])

    create table(:fetch_schedules) do
      add :fetch_source_id, references(:fetch_sources, on_delete: :delete_all), null: false
      add :cron_expression, :string
      add :interval_seconds, :integer
      add :enabled, :boolean, default: true, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:fetch_schedules, [:fetch_source_id])
  end
end
