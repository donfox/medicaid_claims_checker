defmodule MedicaidClaimsChecker.Ingestion.FetchedFile do
  @moduledoc """
  A file a fetch source has already picked up, keyed by its name and the
  SHA-256 of its bytes. The same name with new content is a new file.
  """
  use Ecto.Schema

  schema "fetched_files" do
    field(:filename, :string)
    field(:sha256, :string)

    belongs_to(:fetch_source, MedicaidClaimsChecker.Ingestion.FetchSource)

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
