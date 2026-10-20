defmodule MedicaidClaimsChecker.Repo.Migrations.CreateFetchedFiles do
  @moduledoc """
  Files a scheduled fetch source has already picked up, so a file left in
  the source folder isn't fetched (and refused as a duplicate) on every run.
  """
  use Ecto.Migration

  def change do
    create table(:fetched_files) do
      add(:fetch_source_id, references(:fetch_sources, on_delete: :delete_all), null: false)
      add(:filename, :string, null: false)
      add(:sha256, :string, null: false)

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create(unique_index(:fetched_files, [:fetch_source_id, :filename, :sha256]))
  end
end
