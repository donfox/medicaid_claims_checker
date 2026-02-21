defmodule X12FraudWeb.Repo.Migrations.CreateBatchesAndEdiFiles do
  use Ecto.Migration

  def change do
    create table(:batches) do
      add :batch_id, :string, null: false
      add :source, :string
      add :file_count, :integer, null: false
      add :status, :string, null: false, default: "pending"
      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:batches, [:batch_id])
    create index(:batches, [:status])

    create table(:edi_files) do
      add :filename, :string, null: false
      add :file_path, :string, null: false
      add :json_output, :map
      add :status, :string, null: false, default: "pending"
      add :error_message, :text
      add :error_details, :map
      add :processed_at, :utc_datetime
      add :batch_id, references(:batches, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:edi_files, [:batch_id])
    create index(:edi_files, [:status])
  end
end
