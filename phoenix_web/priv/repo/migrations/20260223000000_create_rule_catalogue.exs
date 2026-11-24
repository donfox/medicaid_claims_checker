defmodule MedicaidClaimsChecker.Repo.Migrations.CreateRuleCatalogue do
  use Ecto.Migration

  def change do
    create table(:rule_catalogue) do
      add :name, :string, null: false
      add :description, :text
      add :entry_type, :string, null: false
      add :status, :string, null: false, default: "Active"
      add :editable, :boolean, null: false, default: false
      add :removable, :boolean, null: false, default: false
      add :redundant, :boolean, null: false, default: false
      add :db_access, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:rule_catalogue, [:name])
    create index(:rule_catalogue, [:entry_type])
    create index(:rule_catalogue, [:status])
  end
end
