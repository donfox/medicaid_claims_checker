defmodule MedicaidClaimsChecker.Ingestion.ZipLimitTest do
  use ExUnit.Case, async: true

  alias MedicaidClaimsChecker.Ingestion.ZipLimit

  defp zip(entries) do
    {:ok, {_, data}} =
      :zip.create(~c"t.zip", Enum.map(entries, fn {n, d} -> {String.to_charlist(n), d} end), [
        :memory
      ])

    data
  end

  test "a zip that would unpack past the limit is refused before unpacking" do
    # 2 MB of zeros compresses to a few KB.
    bomb = zip([{"a.x12", :binary.copy(<<0>>, 2_000_000)}])
    assert byte_size(bomb) < 20_000

    assert {:error, "it would unpack to 2.0 MB, more than the 1.0 MB allowed"} =
             ZipLimit.check(bomb, 1_000_000)

    assert :ok = ZipLimit.check(bomb, 3_000_000)
  end

  test "sizes of all entries are added up" do
    two = zip([{"a.x12", :binary.copy("x", 600_000)}, {"b.x12", :binary.copy("y", 600_000)}])
    assert {:error, _} = ZipLimit.check(two, 1_000_000)
  end

  test "data that is not a zip is reported as unreadable" do
    assert {:error, "it is not a readable zip file"} = ZipLimit.check("not a zip")
  end
end
