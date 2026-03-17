defmodule MedicaidClaimsChecker.Repo.Migrations.CreateNppesRefreshConfig do
  use Ecto.Migration

  def change do
    create table(:nppes_refresh_config) do
      add :auto_refresh, :boolean, default: true, null: false
      add :interval_seconds, :integer, default: 604_800, null: false
      add :download_url, :string, null: false,
        default: "https://download.cms.gov/nppes/NPPES_Data_Dissemination_March_2026.zip"
      add :last_refresh_at, :utc_datetime
      add :last_row_count, :integer, default: 0, null: false
      add :last_status, :string, default: "never", null: false
      add :last_error, :text

      timestamps(type: :utc_datetime)
    end
  end
end
