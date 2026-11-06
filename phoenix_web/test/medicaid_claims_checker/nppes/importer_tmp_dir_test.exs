defmodule MedicaidClaimsChecker.Nppes.ImporterTmpDirTest do
  @moduledoc """
  Clean-up of the folders a refresh downloads and unzips into. Each test works
  in its own ExUnit tmp folder, never the machine's shared temp folder.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias MedicaidClaimsChecker.Nppes.Importer

  @moduletag :tmp_dir

  defp make_refresh_dir(parent, name, age_seconds) do
    dir = Path.join(parent, name)
    file = Path.join(dir, "nppes.zip")
    File.mkdir_p!(dir)
    File.write!(file, "partial download")

    when_ = System.os_time(:second) - age_seconds
    File.touch!(file, when_)
    File.touch!(dir, when_)
    dir
  end

  test "new_tmp_dir names a refresh folder without creating it", %{tmp_dir: parent} do
    dir = Importer.new_tmp_dir(parent)

    assert Path.dirname(dir) == parent
    assert Path.basename(dir) =~ ~r/\Anppes_\d+\z/
    refute File.exists?(dir)
  end

  test "removes refresh folders untouched for over an hour", %{tmp_dir: parent} do
    old = make_refresh_dir(parent, "nppes_1", 2 * 3600)

    capture_log(fn -> assert Importer.remove_stale_tmp_dirs(parent) == [old] end)

    refute File.exists?(old)
  end

  test "leaves a folder whose download is still being written", %{tmp_dir: parent} do
    # The folder itself is old, but the file inside changed a minute ago.
    active = make_refresh_dir(parent, "nppes_2", 2 * 3600)
    File.touch!(Path.join(active, "nppes.zip"), System.os_time(:second) - 60)

    assert Importer.remove_stale_tmp_dirs(parent) == []
    assert File.exists?(active)
  end

  test "leaves anything not named like a refresh folder", %{tmp_dir: parent} do
    other = make_refresh_dir(parent, "something_else", 2 * 3600)

    assert Importer.remove_stale_tmp_dirs(parent) == []
    assert File.exists?(other)
  end
end
