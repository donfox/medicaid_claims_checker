defmodule MedicaidClaimsChecker.Repo.Migrations.EnsureTaxonomyColumnOnNppesProviders do
  use Ecto.Migration

  def up do
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'nppes_providers'
          AND column_name = 'taxonomy'
      ) THEN
        ALTER TABLE nppes_providers ADD COLUMN taxonomy varchar;
      END IF;
    END
    $$;
    """)
  end

  def down do
    :ok
  end
end
