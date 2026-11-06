defmodule MedicaidClaimsChecker.Nppes.LatestFileTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias MedicaidClaimsChecker.Nppes.LatestFile

  @base "https://download.cms.gov/nppes/"

  # Shaped like CMS's NPI_Files.html: relative links next to the weekly and
  # deactivation files, which must not be picked.
  @page """
  <h2>Monthly NPPES Downloadable File Version 2 (V.2)</h2>
  <a href="./NPPES_Data_Dissemination_November_2026_V2.zip">NPPES Data Dissemination V.2 (November 02, 2026)</a>
  <a href="./NPPES_Deactivated_NPI_Report_110226_V2.zip">Monthly Deactivation Update</a>
  <a href="./NPPES_Data_Dissemination_102626_110126_Weekly_V2.zip">Weekly Update</a>
  """

  describe "latest_from_html/1" do
    test "picks the monthly file, not the weekly or deactivation files" do
      assert LatestFile.latest_from_html(@page) ==
               {:ok, @base <> "NPPES_Data_Dissemination_November_2026_V2.zip"}
    end

    test "picks the newest month, across a year boundary" do
      html = """
      <a href="./NPPES_Data_Dissemination_December_2026_V2.zip">Dec</a>
      <a href="./NPPES_Data_Dissemination_January_2027_V2.zip">Jan</a>
      <a href="./NPPES_Data_Dissemination_March_2026_V2.zip">Mar</a>
      """

      assert LatestFile.latest_from_html(html) ==
               {:ok, @base <> "NPPES_Data_Dissemination_January_2027_V2.zip"}
    end

    test "prefers V2 when a month has both versions" do
      html = """
      <a href="./NPPES_Data_Dissemination_May_2026_V2.zip">V2</a>
      <a href="./NPPES_Data_Dissemination_May_2026.zip">V1</a>
      """

      assert LatestFile.latest_from_html(html) ==
               {:ok, @base <> "NPPES_Data_Dissemination_May_2026_V2.zip"}
    end

    test "reports a page with no monthly file" do
      assert {:error, "no monthly file listed" <> _} =
               LatestFile.latest_from_html("<p>Site maintenance</p>")
    end
  end

  describe "follows_latest?/1" do
    test "is true for CMS monthly files, with or without V2, and for a blank URL" do
      assert LatestFile.follows_latest?(@base <> "NPPES_Data_Dissemination_October_2026_V2.zip")
      assert LatestFile.follows_latest?(@base <> "NPPES_Data_Dissemination_March_2026.zip")
      assert LatestFile.follows_latest?("")
      assert LatestFile.follows_latest?(nil)
    end

    test "is false for other URLs" do
      refute LatestFile.follows_latest?(
               @base <> "NPPES_Data_Dissemination_102626_110126_Weekly_V2.zip"
             )

      refute LatestFile.follows_latest?(
               "https://mirror.example.com/NPPES_Data_Dissemination_October_2026_V2.zip"
             )

      refute LatestFile.follows_latest?("http://localhost:9000/nppes.zip")
    end
  end

  describe "resolve/2" do
    @october @base <> "NPPES_Data_Dissemination_October_2026_V2.zip"

    test "swaps a stale monthly URL for the newest one" do
      fetch = fn url ->
        assert url == LatestFile.index_url()
        {:ok, @page}
      end

      assert LatestFile.resolve(@october, fetch: fetch) ==
               @base <> "NPPES_Data_Dissemination_November_2026_V2.zip"
    end

    test "keeps the saved URL, and says why, when the page cannot be read" do
      fetch = fn _url -> {:error, "download page returned HTTP 503"} end

      log = capture_log(fn -> assert LatestFile.resolve(@october, fetch: fetch) == @october end)
      assert log =~ "HTTP 503"
    end

    test "keeps the saved URL when the page lists no monthly file" do
      fetch = fn _url -> {:ok, "<p>Site maintenance</p>"} end

      capture_log(fn -> assert LatestFile.resolve(@october, fetch: fetch) == @october end)
    end

    test "uses any other URL as entered, without reading the page" do
      custom = "https://mirror.example.com/nppes/full.zip"
      fetch = fn _url -> flunk("should not read the CMS page for a custom URL") end

      assert LatestFile.resolve(custom, fetch: fetch) == custom
    end
  end
end
