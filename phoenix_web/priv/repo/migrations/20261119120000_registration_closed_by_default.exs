defmodule MedicaidClaimsChecker.Repo.Migrations.RegistrationClosedByDefault do
  use Ecto.Migration

  # A new database starts with registration closed, so nobody can create an
  # account until an admin opens it (Admin page, System, User Registration).
  #
  # The setting is closed only on a database with no users yet, which is a
  # fresh install: migrations run before the seeds create the first admin.
  # A database already in use keeps whatever its admins chose.
  def up do
    alter table(:app_settings) do
      modify :registration_open, :boolean, default: false, null: false
    end

    execute("""
    UPDATE app_settings SET registration_open = false, updated_at = now()
    WHERE key = 'singleton' AND NOT EXISTS (SELECT 1 FROM users)
    """)
  end

  def down do
    alter table(:app_settings) do
      modify :registration_open, :boolean, default: true, null: false
    end
  end
end
