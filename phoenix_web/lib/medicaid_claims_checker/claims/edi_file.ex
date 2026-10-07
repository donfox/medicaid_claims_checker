defmodule MedicaidClaimsChecker.Claims.EdiFile do
  use Ecto.Schema
  import Ecto.Changeset

  schema "edi_files" do
    field :filename, :string
    field :file_path, :string
    # The translated claim, as ingested. Never overwritten by evaluation.
    field :json_output, :map
    # The rule engine's report for the most recent evaluation (advisory).
    field :evaluation_report, :map
    field :status, :string, default: "pending"
    field :error_message, :string
    field :error_details, :map
    field :processed_at, :utc_datetime

    belongs_to :batch, MedicaidClaimsChecker.Claims.Batch

    timestamps(type: :utc_datetime)
  end

  def changeset(edi_file, attrs) do
    edi_file
    |> cast(attrs, [:filename, :file_path, :json_output, :evaluation_report, :status, :error_message, :error_details, :processed_at, :batch_id])
    |> validate_required([:filename, :file_path, :status, :batch_id])
    # Processing state only. Whether a claim is fraudulent is an analyst's
    # decision, never a file status set by the engine.
    |> validate_inclusion(:status, ["pending", "translated", "evaluated", "syntax_error"])
    |> foreign_key_constraint(:batch_id)
  end
end
