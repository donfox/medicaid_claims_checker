defmodule MedicaidClaimsChecker.Repo.Migrations.AddRawClaimJsonToEdiFiles do
  use Ecto.Migration

  def change do
    alter table(:edi_files) do
      add :raw_claim_json, :map
    end
  end
end
