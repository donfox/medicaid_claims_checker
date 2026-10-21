defmodule MedicaidClaimsCheckerWeb.UseCases.ZZipFilesTest do
  @moduledoc "Z1–Z7: uploading .zip files."
  use MedicaidClaimsCheckerWeb.UseCaseCase

  alias MedicaidClaimsChecker.Claims.Evaluator

  manifest_tests(~w(Z1 Z2 Z3 Z4 Z5 Z6))

  # Z7's zip is too big to commit; it is built here by the same generator
  # as `elixir mock_data/generate.exs --large 15001`.
  @tag use_case: "Z7"
  @tag timeout: 300_000
  test "Z7 a zip of 15,001 claims: the batch is refused, with the limit named", %{conn: conn} do
    n = Evaluator.max_batch_claims() + 1
    {_cases, _} = Code.eval_file(MedicaidClaimsChecker.MockData.path("generators/x12_files.exs"))
    {_meta, entries} = apply(X12Suite.Cases, :large, [n])

    {:ok, {_, zip}} =
      :zip.create(~c"large.zip", Enum.map(entries, fn {name, data} -> {String.to_charlist(name), data} end), [:memory])

    %{batches: [batch], claims: claims, message: message} = upload(conn, [{"large_batch_#{n}.zip", zip}])

    assert map_size(claims) == n
    assert Enum.all?(Map.values(claims), &(&1.status == "translated")), "no claim may be evaluated"
    assert batch.status == "failed"
    assert message =~ "the limit is #{Evaluator.max_batch_claims()}"
  end
end
