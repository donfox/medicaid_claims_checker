defmodule MedicaidClaimsChecker.Repo.Migrations.CreateNppesProviders do
  use Ecto.Migration

  def change do
    create table(:nppes_providers, primary_key: false) do
      add :npi, :string, size: 10, primary_key: true
      add :entity_type, :integer, null: false
      add :provider_name, :string, null: false
      add :credential, :string
      add :state, :string, size: 2
      add :enumeration_date, :date
      add :deactivation_date, :date
      add :reactivation_date, :date
      add :last_update_date, :date

      timestamps(type: :utc_datetime)
    end

    create index(:nppes_providers, [:state])
    create index(:nppes_providers, [:deactivation_date])
  end
end
