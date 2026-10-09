defmodule MedicaidClaimsChecker.Repo.Migrations.AddHistoryClearedAtToUsers do
  @moduledoc """
  Lets each user clear the Jobs History display without deleting anything.

  Batches inserted before `history_cleared_at` are hidden from that user's
  default view; the batch and claim rows themselves are never touched.
  """
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :history_cleared_at, :utc_datetime
    end
  end
end
