defmodule MedicaidClaimsChecker.Repo.Migrations.AddRejectedFilesToBatches do
  @moduledoc """
  `batches.rejected_files`: files (or claims split from them) a scheduled
  fetch could not read, each `%{"filename" => ..., "reason" => ...}`, so
  Jobs History shows them instead of only the log.
  """
  use Ecto.Migration

  def change do
    alter table(:batches) do
      add(:rejected_files, {:array, :map}, null: false, default: [])
    end
  end
end
