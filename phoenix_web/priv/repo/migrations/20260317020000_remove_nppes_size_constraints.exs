defmodule MedicaidClaimsChecker.Repo.Migrations.RemoveNppesSizeConstraints do
  use Ecto.Migration

  def change do
    alter table(:nppes_providers) do
      modify :npi, :string, from: {:string, size: 10}
      modify :state, :string, from: {:string, size: 10}
    end
  end
end
