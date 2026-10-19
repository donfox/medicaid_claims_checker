defmodule MedicaidClaimsChecker.Repo.Migrations.AddDuplicateSubmissionTracking do
  @moduledoc """
  Lets ingestion refuse a file or claim that was already submitted.

    * `submitted_files` - SHA-256 of every file a batch came from.
    * `edi_files.claim_fingerprint` - SHA-256 of the claim without its X12
      envelope (see `Claims.Fingerprint`). Existing rows are backfilled.
    * `batches.duplicates` - what a batch refused as duplicates, and the
      earlier batch each one was first submitted in.
  """
  use Ecto.Migration

  import Ecto.Query

  alias MedicaidClaimsChecker.Claims.Fingerprint

  def up do
    create table(:submitted_files) do
      add :sha256, :string, null: false
      add :filename, :string, null: false
      add :batch_id, references(:batches, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:submitted_files, [:sha256])

    alter table(:edi_files) do
      add :claim_fingerprint, :string
    end

    create index(:edi_files, [:claim_fingerprint])

    alter table(:batches) do
      add :duplicates, {:array, :map}, null: false, default: []
    end

    flush()

    from(f in "edi_files", where: not is_nil(f.json_output), select: {f.id, f.json_output})
    |> repo().all()
    |> Enum.each(fn {id, claim} ->
      from(f in "edi_files", where: f.id == ^id)
      |> repo().update_all(set: [claim_fingerprint: Fingerprint.claim(claim)])
    end)
  end

  def down do
    alter table(:batches) do
      remove :duplicates
    end

    drop index(:edi_files, [:claim_fingerprint])

    alter table(:edi_files) do
      remove :claim_fingerprint
    end

    drop table(:submitted_files)
  end
end
