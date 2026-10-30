defmodule MedicaidClaimsChecker.Repo.Migrations.DropStrayRawClaimJson do
  @moduledoc """
  Removes `edi_files.raw_claim_json` where it exists. No migration ever
  created it and no code reads it; it turned up, always empty, in a
  database changed by hand. Databases built from the migrations don't have
  it, so this does nothing there.
  """
  use Ecto.Migration

  def up do
    execute("ALTER TABLE edi_files DROP COLUMN IF EXISTS raw_claim_json")
  end

  # The column was never part of the schema, so there is nothing to restore.
  def down, do: :ok
end
