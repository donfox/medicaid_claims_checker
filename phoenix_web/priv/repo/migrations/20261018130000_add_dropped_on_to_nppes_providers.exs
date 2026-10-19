defmodule MedicaidClaimsChecker.Repo.Migrations.AddDroppedOnToNppesProviders do
  @moduledoc """
  Records when an NPI stopped appearing in the NPPES full file.

  Dropped NPIs are kept, not deleted: a claim can arrive months after the
  service date, and services rendered before the NPI was dropped must still
  be checked against its last known record.
  """
  use Ecto.Migration

  def change do
    alter table(:nppes_providers) do
      add :dropped_on, :date
    end
  end
end
