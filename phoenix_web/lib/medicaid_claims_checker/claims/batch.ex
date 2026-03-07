defmodule MedicaidClaimsChecker.Claims.Batch do
  use Ecto.Schema
  import Ecto.Changeset

  schema "batches" do
    field :batch_id, :string
    field :source, :string
    field :file_count, :integer
    field :status, :string, default: "pending"
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime

    has_many :edi_files, MedicaidClaimsChecker.Claims.EdiFile, foreign_key: :batch_id

    timestamps(type: :utc_datetime)
  end

  def changeset(batch, attrs) do
    batch
    |> cast(attrs, [:batch_id, :source, :file_count, :status, :started_at, :completed_at])
    |> validate_required([:batch_id, :file_count, :status])
    |> validate_inclusion(:status, ["pending", "processing", "completed", "failed"])
    |> unique_constraint(:batch_id)
  end
end
