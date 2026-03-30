defmodule MedicaidClaimsChecker.Repo.Migrations.WidenNppesProvidersState do
  use Ecto.Migration

  def change do
    alter table(:nppes_providers) do
      modify :state, :string, size: 10, from: {:string, size: 2}
    end
  end
end
