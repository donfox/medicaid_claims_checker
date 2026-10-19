defmodule MedicaidClaimsChecker.Claims.SubmittedFile do
  @moduledoc "A file a batch was built from, keyed by the SHA-256 of its bytes."
  use Ecto.Schema
  import Ecto.Changeset

  schema "submitted_files" do
    field :sha256, :string
    field :filename, :string

    belongs_to :batch, MedicaidClaimsChecker.Claims.Batch

    timestamps(type: :utc_datetime)
  end

  def changeset(submitted_file, attrs) do
    submitted_file
    |> cast(attrs, [:sha256, :filename, :batch_id])
    |> validate_required([:sha256, :filename, :batch_id])
    |> unique_constraint(:sha256)
    |> foreign_key_constraint(:batch_id)
  end
end
