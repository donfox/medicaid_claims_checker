defmodule MedicaidClaimsChecker.Repo.Migrations.EncryptFetchSourceCredentials do
  use Ecto.Migration

  def up do
    # Change credentials from jsonb to bytea so cloak_ecto can store
    # AES-GCM ciphertext. Existing plaintext rows are nullified — operators
    # must re-enter credentials via the UI after this migration runs.
    execute "ALTER TABLE fetch_sources ALTER COLUMN credentials TYPE bytea USING NULL"
  end

  def down do
    execute "ALTER TABLE fetch_sources ALTER COLUMN credentials TYPE jsonb USING NULL"
  end
end
