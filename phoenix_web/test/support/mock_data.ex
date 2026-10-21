defmodule MedicaidClaimsChecker.MockData do
  @moduledoc """
  Paths into the repository's `mock_data/` folder, where all test data
  lives. Paths are relative to it, e.g.
  `"X_x12_files/X4_several_claims_one_transaction_set/three_claims.x12"`.
  """

  @root Path.expand("../../../mock_data", __DIR__)

  def root, do: @root

  def path(rel), do: Path.join(@root, rel)

  def read!(rel), do: File.read!(path(rel))
end
