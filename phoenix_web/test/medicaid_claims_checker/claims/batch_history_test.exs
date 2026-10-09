defmodule MedicaidClaimsChecker.Claims.BatchHistoryTest do
  use MedicaidClaimsChecker.DataCase, async: true

  alias MedicaidClaimsChecker.Claims
  alias MedicaidClaimsChecker.Claims.Batch

  defp insert_batch(name, inserted_at) do
    Repo.insert!(%Batch{
      batch_id: Ecto.UUID.generate(),
      batch_name: name,
      source: "manual_upload",
      file_count: 1,
      status: "completed",
      inserted_at: inserted_at,
      updated_at: inserted_at
    })
  end

  defp at(iso), do: DateTime.from_iso8601(iso) |> elem(1)

  setup do
    for day <- 1..5 do
      insert_batch("day #{day}", at("2026-09-0#{day}T12:00:00Z"))
    end

    :ok
  end

  test "pages newest first and reports the total" do
    {page1, total} = Claims.list_batches_page(page: 1, per_page: 2)
    {page3, ^total} = Claims.list_batches_page(page: 3, per_page: 2)

    assert total == 5
    assert Enum.map(page1, & &1.batch_name) == ["day 5", "day 4"]
    assert Enum.map(page3, & &1.batch_name) == ["day 1"]
  end

  test "inserted_after hides older batches without deleting them" do
    {batches, total} = Claims.list_batches_page(inserted_after: at("2026-09-03T12:00:00Z"))

    assert Enum.map(batches, & &1.batch_name) == ["day 5", "day 4"]
    assert total == 2
    assert Repo.aggregate(Batch, :count) == 5
  end

  test "from/to bounds are inclusive" do
    opts = [from: at("2026-09-02T12:00:00Z"), to: at("2026-09-04T12:00:00Z")]

    assert Claims.count_batches(opts) == 3
  end
end
