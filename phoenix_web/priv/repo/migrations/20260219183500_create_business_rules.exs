defmodule MedicaidClaimsChecker.Repo.Migrations.CreateBusinessRules do
  use Ecto.Migration

  def change do
    create table(:business_rules) do
      add :name, :string, null: false
      add :rule_text, :text, null: false
      add :active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:business_rules, [:name])
    create index(:business_rules, [:active])
  end
end
