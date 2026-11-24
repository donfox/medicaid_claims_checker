defmodule MedicaidClaimsChecker.Ingestion.FetchRunnerTest do
  use MedicaidClaimsChecker.DataCase, async: true

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias MedicaidClaimsChecker.{Ingestion, MockData, Repo}
  alias MedicaidClaimsChecker.Claims.Batch
  alias MedicaidClaimsChecker.Ingestion.{FetchRunner, RemoteFetcher}

  @moduletag :tmp_dir

  defp run(dir) do
    {:ok, source} =
      Ingestion.create_fetch_source(%{name: "local", uri: dir <> "/", source_type: "local"})

    {result, _log} =
      with_log(fn ->
        FetchRunner.run(%{id: source.id, name: "local", uri: dir <> "/", source_type: "local"})
      end)

    {result, Repo.one!(Batch)}
  end

  test "a file that can't be read is stored on the batch next to the claims that could", %{
    tmp_dir: dir
  } do
    File.write!(
      Path.join(dir, "good.x12"),
      MockData.read!("x12_files/837p_professional/clean_office_visit.x12")
    )

    File.write!(
      Path.join(dir, "cut.x12"),
      MockData.read!("x12_files/broken_envelope_or_file/truncated.x12")
    )

    assert {{:ok, _}, batch} = run(dir)

    assert batch.file_count == 1

    assert [%{"filename" => "cut.x12", "reason" => "Incomplete transmission:" <> _}] =
             batch.rejected_files
  end

  test "when nothing can be read, a failed batch names every rejected file", %{tmp_dir: dir} do
    File.write!(
      Path.join(dir, "cut.x12"),
      MockData.read!("x12_files/broken_envelope_or_file/truncated.x12")
    )

    File.write!(Path.join(dir, "notes.txt"), "hello")

    assert {{:ok, _}, batch} = run(dir)

    assert batch.status == "failed"
    assert batch.file_count == 0

    assert batch.rejected_files |> Enum.map(& &1["filename"]) |> Enum.sort() == [
             "cut.x12",
             "notes.txt"
           ]
  end

  test "SFTP downloads: plain files beside a zip are kept, and every zip is unpacked", %{
    tmp_dir: dir
  } do
    zip = fn name, entry ->
      {:ok, {_, data}} = :zip.create(~c"z.zip", [{String.to_charlist(entry), "ISA"}], [:memory])
      path = Path.join(dir, name)
      File.write!(path, data)
      path
    end

    plain = Path.join(dir, "plain.x12")
    File.write!(plain, "ISA")
    files = [zip.("one.zip", "a.x12"), plain, zip.("two.zip", "b.edi")]

    config = %{allowed_extensions: [".x12", ".edi", ".txt"]}

    {{:ok, %{files: found}}, _log} =
      with_log(fn -> RemoteFetcher.collect_downloaded(files, dir, config) end)

    assert found |> Enum.map(&Path.basename/1) |> Enum.sort() == ["a.x12", "b.edi", "plain.x12"]
  end
end
