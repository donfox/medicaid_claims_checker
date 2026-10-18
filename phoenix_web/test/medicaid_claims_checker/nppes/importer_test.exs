defmodule MedicaidClaimsChecker.Nppes.ImporterTest do
  use MedicaidClaimsChecker.DataCase, async: true

  alias MedicaidClaimsChecker.Claims.NppesProvider
  alias MedicaidClaimsChecker.Nppes.Importer

  # The first 48 columns of the NPPES dissemination file, in CMS order. The
  # real file has more columns after these; the importer must find its
  # columns by name, not by position.
  @nppes_header [
    "NPI",
    "Entity Type Code",
    "Replacement NPI",
    "Employer Identification Number (EIN)",
    "Provider Organization Name (Legal Business Name)",
    "Provider Last Name (Legal Name)",
    "Provider First Name",
    "Provider Middle Name",
    "Provider Name Prefix Text",
    "Provider Name Suffix Text",
    "Provider Credential Text",
    "Provider Other Organization Name",
    "Provider Other Organization Name Type Code",
    "Provider Other Last Name",
    "Provider Other First Name",
    "Provider Other Middle Name",
    "Provider Other Name Prefix Text",
    "Provider Other Name Suffix Text",
    "Provider Other Credential Text",
    "Provider Other Last Name Type Code",
    "Provider First Line Business Mailing Address",
    "Provider Second Line Business Mailing Address",
    "Provider Business Mailing Address City Name",
    "Provider Business Mailing Address State Name",
    "Provider Business Mailing Address Postal Code",
    "Provider Business Mailing Address Country Code (If outside U.S.)",
    "Provider Business Mailing Address Telephone Number",
    "Provider Business Mailing Address Fax Number",
    "Provider First Line Business Practice Location Address",
    "Provider Second Line Business Practice Location Address",
    "Provider Business Practice Location Address City Name",
    "Provider Business Practice Location Address State Name",
    "Provider Business Practice Location Address Postal Code",
    "Provider Business Practice Location Address Country Code (If outside U.S.)",
    "Provider Business Practice Location Address Telephone Number",
    "Provider Business Practice Location Address Fax Number",
    "Provider Enumeration Date",
    "Last Update Date",
    "NPI Deactivation Reason Code",
    "NPI Deactivation Date",
    "NPI Reactivation Date",
    "Provider Gender Code",
    "Authorized Official Last Name",
    "Authorized Official First Name",
    "Authorized Official Middle Name",
    "Authorized Official Title or Position",
    "Authorized Official Telephone Number",
    "Healthcare Provider Taxonomy Code_1"
  ]

  defp row(values) do
    Enum.map(@nppes_header, &Map.get(values, &1, ""))
  end

  defp write_csv(rows, opts \\ []) do
    path = Path.join(System.tmp_dir!(), "nppes_test_#{System.unique_integer([:positive])}.csv")
    on_exit(fn -> File.rm(path) end)
    body = rows |> NimbleCSV.RFC4180.dump_to_iodata() |> IO.iodata_to_binary()
    File.write!(path, Keyword.get(opts, :prefix, "") <> body)
    path
  end

  # An active organization, laid out as in the CMS file (second address line
  # just before the practice state, gender just after reactivation).
  @active_org %{
    "NPI" => "1871971291",
    "Entity Type Code" => "2",
    "Provider Organization Name (Legal Business Name)" => "SARAH H TORRES INC",
    "Provider First Line Business Practice Location Address" => "100 MAIN ST",
    "Provider Second Line Business Practice Location Address" => "SUITE 127",
    "Provider Business Practice Location Address City Name" => "AUSTIN",
    "Provider Business Practice Location Address State Name" => "TX",
    "Provider Enumeration Date" => "05/18/2015",
    "Last Update Date" => "07/01/2024",
    "Healthcare Provider Taxonomy Code_1" => "101YM0800X"
  }

  # CMS publishes a deactivated NPI with only its NPI and deactivation date.
  @deactivated %{"NPI" => "1184887309", "NPI Deactivation Date" => "03/14/2019"}

  @reactivated %{
    "NPI" => "1659374601",
    "Entity Type Code" => "1",
    "Provider Last Name (Legal Name)" => "OBERDICK",
    "Provider First Name" => "WENDY",
    "Provider Credential Text" => "MD",
    "Provider Second Line Business Practice Location Address" => "STE 1F",
    "Provider Business Practice Location Address State Name" => "TN",
    "Provider Enumeration Date" => "05/23/2005",
    "NPI Deactivation Date" => "02/01/2010",
    "NPI Reactivation Date" => "05/24/2010",
    "Provider Gender Code" => "F",
    "Healthcare Provider Taxonomy Code_1" => "207Q00000X"
  }

  defp provider(npi),
    do:
      Repo.one!(
        from(p in NppesProvider, where: p.npi == ^npi, select: %{p | taxonomy: p.taxonomy})
      )

  test "reads each field from its named column" do
    path = write_csv([@nppes_header, row(@active_org), row(@deactivated), row(@reactivated)])

    assert {:ok, 3} = Importer.import_from_file(path)

    org = provider("1871971291")
    assert org.entity_type == 2
    assert org.provider_name == "SARAH H TORRES INC"
    assert org.state == "TX"
    assert org.taxonomy == "101YM0800X"
    assert org.enumeration_date == ~D[2015-05-18]
    assert org.last_update_date == ~D[2024-07-01]
    assert org.deactivation_date == nil
    assert org.reactivation_date == nil

    gone = provider("1184887309")
    assert gone.deactivation_date == ~D[2019-03-14]
    refute NppesProvider.active_on_date?(gone, ~D[2026-01-15])

    back = provider("1659374601")
    assert back.provider_name == "OBERDICK, WENDY"
    assert back.credential == "MD"
    assert back.state == "TN"
    assert back.deactivation_date == ~D[2010-02-01]
    assert back.reactivation_date == ~D[2010-05-24]
    assert NppesProvider.active_on_date?(back, ~D[2026-01-15])
  end

  test "finds columns by name when CMS reorders them" do
    reordered = Enum.reverse(@nppes_header)
    values = Enum.map(reordered, &Map.get(@active_org, &1, ""))

    assert {:ok, 1} = Importer.import_from_file(write_csv([reordered, values]))
    assert provider("1871971291").state == "TX"
  end

  test "accepts a header that starts with a byte-order mark" do
    path = write_csv([@nppes_header, row(@active_org)], prefix: "﻿")

    assert {:ok, 1} = Importer.import_from_file(path)
  end

  test "refuses a file missing a needed column, importing nothing" do
    header = List.delete(@nppes_header, "NPI Deactivation Date")
    values = Enum.map(header, &Map.get(@active_org, &1, ""))

    assert {:error, "NPPES file is missing columns: NPI Deactivation Date"} =
             Importer.import_from_file(write_csv([header, values]))

    assert Repo.aggregate(NppesProvider, :count) == 0
  end
end
