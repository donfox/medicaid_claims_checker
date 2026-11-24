defmodule MedicaidClaimsChecker.Repo.Migrations.AddBatchNameToBatches do
  use Ecto.Migration

  def change do
    alter table(:batches) do
      add :batch_name, :string
    end
  end
end
