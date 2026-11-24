defmodule MedicaidClaimsChecker.Repo.Migrations.RecalculateClaimFingerprints do
  @moduledoc """
  Recalculates `edi_files.claim_fingerprint` after `Claims.Fingerprint` moved
  to a fixed list of fields, so stored claims still match new submissions.
  Only that column changes.
  """
  use Ecto.Migration

  import Ecto.Query

  alias MedicaidClaimsChecker.Claims.Fingerprint

  @batch_size 1000

  def up do
    recalculate_after(0)
  end

  # The old hashes aren't kept, so rolling back leaves the column as it is.
  def down, do: :ok

  defp recalculate_after(last_id) do
    rows =
      from(f in "edi_files",
        where: f.id > ^last_id and not is_nil(f.json_output),
        order_by: f.id,
        limit: @batch_size,
        select: {f.id, f.json_output}
      )
      |> repo().all()

    Enum.each(rows, fn {id, claim} ->
      from(f in "edi_files", where: f.id == ^id)
      |> repo().update_all(set: [claim_fingerprint: Fingerprint.claim(claim)])
    end)

    case List.last(rows) do
      nil -> :ok
      {id, _claim} -> recalculate_after(id)
    end
  end
end
