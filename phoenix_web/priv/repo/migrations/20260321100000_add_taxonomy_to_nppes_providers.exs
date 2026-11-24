defmodule MedicaidClaimsChecker.Repo.Migrations.AddTaxonomyToNppesProviders do
  use Ecto.Migration

  def change do
    alter table(:nppes_providers) do
      add :taxonomy, :string
    end
  end
end
