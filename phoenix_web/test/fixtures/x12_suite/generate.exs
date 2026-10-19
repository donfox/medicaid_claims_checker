# Generates the X12 837 test suite: raw .x12/.edi/.zip files under files/
# and manifest.json, which records the correct expected outcome of each file.
#
#   cd phoenix_web
#   elixir test/fixtures/x12_suite/generate.exs              # regular suite
#   elixir test/fixtures/x12_suite/generate.exs --large 15000 # plus a large-batch zip
#
# Patients and claims are synthetic. Provider NPIs are real, from the NPPES
# registry the app imports (checked against the NPI Registry 2026-10-17),
# except the deliberate bad ones: 1234567890 (fails Luhn), 1999999992
# (Luhn-valid but unassigned), and the malformed NPIs in the format cases.
# Provider names in deactivated cases are made up: CMS publishes no name
# for a deactivated NPI.
# Check results with test/scripts/verify_x12_suite.exs.

defmodule X12Suite.Builder do
  @moduledoc false

  @default_billing %{
    name: "MIDWEST INTERNAL MEDICINE ASSOCIATES LLC",
    npi: "1003001538",
    taxonomy: "207R00000X",
    tax_id: "361234567"
  }

  # Practice location (NM1*85 N3/N4) of each real billing NPI, from the NPI
  # Registry. The registry has no address for deactivated NPIs, so those and
  # the deliberately fake NPIs get the synthetic address.
  @practice_addresses %{
    "1003001538" => %{street: "1728 MARION WALDO RD", city: "MARION", state: "OH", zip: "433027457"},
    "1003001579" => %{street: "4103 WILBARGER ST", city: "VERNON", state: "TX", zip: "763843137"},
    "1003003534" => %{street: "631 S 25TH STREET", city: "TERRE HAUTE", state: "IN", zip: "47803"},
    "1003005000" => %{street: "5900 HILLANDALE DR SUITE 215", city: "LITHONIA", state: "GA", zip: "300583802"},
    "1003625385" => %{street: "2184 N BEECH DALY RD STE 4", city: "DEARBORN HEIGHTS", state: "MI", zip: "481273492"}
  }

  @synthetic_address %{street: "100 TEST AVE", city: "CHICAGO", state: "IL", zip: "60601"}

  @default_member %{
    last: "TESTPATIENT",
    first: "ALEX",
    member_id: "MCD000000001",
    dob: "19850315",
    gender: "F"
  }

  @versions %{p: "005010X222A1", i: "005010X223A2", d: "005010X224A2"}

  def default_billing, do: billing_provider([])

  defp billing_provider(overrides) do
    b = Map.merge(@default_billing, Map.new(overrides))
    Map.merge(Map.get(@practice_addresses, b.npi, @synthetic_address), b)
  end

  # A claim spec. `lines` is a list of {procedure, charge, date}; the claim
  # total is their sum unless `amount` overrides it.
  def claim(id, opts \\ []) do
    lines = Keyword.get(opts, :lines, [{"99213", "150.00", "20260901"}])

    amount =
      Keyword.get_lazy(opts, :amount, fn ->
        lines |> Enum.map(fn {_, c, _} -> String.to_float(c) end) |> Enum.sum() |> money()
      end)

    %{
      id: id,
      amount: amount,
      pos: Keyword.get(opts, :pos, "11"),
      dx: Keyword.get(opts, :dx, ["Z0000"]),
      lines: lines,
      member: Map.merge(@default_member, Map.new(Keyword.get(opts, :member, []))),
      rendering: Keyword.get(opts, :rendering),
      prior_auth: Keyword.get(opts, :prior_auth)
    }
  end

  def money(f), do: :erlang.float_to_binary(f * 1.0, decimals: 2)

  # One transaction set (ST..SE): a billing provider and its claims.
  # Each claim gets its own subscriber HL unless `same_subscriber: true`.
  def transaction(claims, opts \\ []) do
    %{
      claims: claims,
      kind: Keyword.get(opts, :kind, :p),
      billing: billing_provider(Keyword.get(opts, :billing, [])),
      same_subscriber: Keyword.get(opts, :same_subscriber, false)
    }
  end

  # Renders an interchange (ISA..IEA) holding one functional group.
  def interchange(transactions, opts \\ []) do
    el = Keyword.get(opts, :element, "*")
    sub = Keyword.get(opts, :sub, ":")
    term = Keyword.get(opts, :term, "~")
    nl = Keyword.get(opts, :newline, "\n")
    ctrl = Keyword.get(opts, :control, "000000101")
    iea_ctrl = Keyword.get(opts, :iea_control, ctrl)
    se_adjust = Keyword.get(opts, :se_adjust, 0)
    kind = hd(transactions).kind

    seg = fn parts -> Enum.join(parts, el) <> term <> nl end
    comp = fn parts -> Enum.join(parts, sub) end

    isa =
      Enum.join(
        [
          "ISA", "00", pad("", 10), "00", pad("", 10), "ZZ", pad("TESTSUBMIT01", 15),
          "ZZ", pad("STMED01", 15), "261016", "1200", "^", "00501", ctrl, "0", "T", sub
        ],
        el
      ) <> term

    106 = byte_size(isa)

    sets =
      transactions
      |> Enum.with_index(1)
      |> Enum.map(fn {tx, n} ->
        st_ctrl = String.pad_leading(Integer.to_string(n), 4, "0")
        body = transaction_segments(tx, st_ctrl, comp)
        count = length(body) + 2 + se_adjust

        ([["ST", "837", st_ctrl, @versions[tx.kind]]] ++
           body ++ [["SE", Integer.to_string(count), st_ctrl]])
        |> Enum.map(seg)
        |> Enum.join()
      end)

    isa <> nl <>
      seg.(["GS", "HC", "TESTSUBMIT01", "STMED01", "20261016", "1200", "101", "X", @versions[kind]]) <>
      Enum.join(sets) <>
      seg.(["GE", Integer.to_string(length(transactions)), "101"]) <>
      seg.(["IEA", "1", iea_ctrl])
  end

  defp transaction_segments(tx, st_ctrl, comp) do
    b = tx.billing

    header = [
      ["BHT", "0019", "00", "TEST" <> st_ctrl, "20261016", "1200", "CH"],
      ["NM1", "41", "2", "EMRTS TEST SUBMITTER", "", "", "", "", "46", "TESTSUBMIT01"],
      ["PER", "IC", "TEST CONTACT", "TE", "5555550100"],
      ["NM1", "40", "2", "STATE MEDICAID PROGRAM", "", "", "", "", "46", "STMED01"],
      ["HL", "1", "", "20", "1"]
    ]

    prv = if b.taxonomy, do: [["PRV", "BI", "PXC", b.taxonomy]], else: []

    billing = [
      ["NM1", "85", "2", b.name, "", "", "", "", "XX", b.npi],
      ["N3", b.street],
      ["N4", b.city, b.state, b.zip],
      ["REF", "EI", b.tax_id]
    ]

    {claim_segs, _} =
      Enum.reduce(tx.claims, {[], 2}, fn c, {acc, hl} ->
        subscriber =
          if tx.same_subscriber and acc != [], do: [], else: subscriber_segments(c, hl)

        next_hl = if subscriber == [], do: hl, else: hl + 1
        {acc ++ subscriber ++ claim_segments(c, tx.kind, comp), next_hl}
      end)

    header ++ prv ++ billing ++ claim_segs
  end

  defp subscriber_segments(c, hl) do
    m = c.member
    dmg = if m.dob, do: [["DMG", "D8", m.dob, m.gender]], else: []

    [
      ["HL", Integer.to_string(hl), "1", "22", "0"],
      ["SBR", "P", "18", "", "", "", "", "", "", "MC"],
      ["NM1", "IL", "1", m.last, m.first, "", "", "", "MI", m.member_id],
      ["N3", "200 MEMBER ST"],
      ["N4", "CHICAGO", "IL", "60602"]
    ] ++ dmg ++ [["NM1", "PR", "2", "STATE MEDICAID PROGRAM", "", "", "", "", "PI", "STMED01"]]
  end

  defp claim_segments(c, kind, comp) do
    {facility_code, cl1} =
      case kind do
        :i -> {"A", [["CL1", "1", "7", "01"]]}
        _ -> {"B", []}
      end

    clm = [["CLM", c.id, c.amount, "", "", comp.([c.pos, facility_code, "1"]), "Y", "A", "Y", "Y"]]
    auth = if c.prior_auth, do: [["REF", "G1", c.prior_auth]], else: []

    hi =
      case c.dx do
        [] -> []
        [first | rest] -> [["HI", comp.(["ABK", first]) | Enum.map(rest, &comp.(["ABF", &1]))]]
      end

    rendering =
      case c.rendering do
        nil -> []
        r -> [["NM1", "82", "1", r.last, r.first, "", "", "", "XX", r.npi], ["PRV", "PE", "PXC", r.taxonomy]]
      end

    lines =
      c.lines
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {{proc, charge, date}, n} ->
        service =
          case kind do
            :p -> [["SV1", comp.(["HC", proc]), charge, "UN", "1", "", "", "1"]]
            :i -> [["SV2", "0450", comp.(["HC", proc]), charge, "UN", "1"]]
            :d -> [["SV3", comp.(["AD", proc]), charge, "", "", "", "1"], ["TOO", "JP", "19"]]
          end

        [["LX", Integer.to_string(n)]] ++ service ++ [["DTP", "472", "D8", date]]
      end)

    clm ++ cl1 ++ auth ++ hi ++ rendering ++ lines
  end

  defp pad(s, n), do: String.pad_trailing(s, n)
end

defmodule X12Suite.Cases do
  @moduledoc false
  import X12Suite.Builder

  @valid_ortho [billing: [name: "THE ROSS ORTHOPAEDIC WELLNESS CENTER", npi: "1003005000", taxonomy: "207X00000X"]]
  @no_taxonomy [billing: [taxonomy: nil]]

  # Expected outcome of one claim. `matched` is the exact set of rules that
  # should match; `not_checked` lists rules that must come back "not checked"
  # (others may too); `nppes` is :ok or a substring of the rejection reason.
  defp ok(id, matched, extra \\ []),
    do: Map.merge(%{claim_id: id, matched: matched, nppes: "ok"}, Map.new(extra))

  defp single(file, purpose, claim, expect, opts \\ []) do
    tx_opts = Keyword.take(opts, [:billing, :kind])

    %{
      file: file,
      purpose: purpose,
      content: interchange([transaction([claim], tx_opts)], Keyword.get(opts, :format, [])),
      expect: %{claims: [expect]},
      known_issue: Keyword.get(opts, :known_issue)
    }
  end

  def all do
    single_claims() ++ formats() ++ multi_claim() ++ envelope_errors()
  end

  def single_claims do
    [
      single("single/01_clean_office_visit.x12", "Clean low-value office visit; no rule should match",
        claim("CLEAN001"), ok("CLEAN001", [])),
      single("single/02_clean_multi_line.x12", "Clean claim with three service lines and two diagnoses",
        claim("CLEAN002",
          dx: ["Z0000", "J069"],
          lines: [{"99214", "210.00", "20260902"}, {"87880", "45.00", "20260902"}, {"36415", "18.00", "20260902"}]),
        ok("CLEAN002", [])),
      single("single/03_high_value_claim.x12", "Claim over $50,000 → HighValueClaim review",
        claim("HIGHVAL01", lines: [{"27447", "62000.00", "20260814"}]),
        ok("HIGHVAL01", ["HighValueClaim", "UnauthorizedProcedure"], not_checked: ["NewProviderLargeSubmission"]),
        @valid_ortho),
      single("single/04_er_high_complexity.x12", "99285 over $10,000 → HighComplexityERVisit review",
        claim("ERVISIT01", pos: "23", lines: [{"99285", "12500.00", "20260820"}]),
        ok("ERVISIT01", ["HighComplexityERVisit", "UnauthorizedProcedure"], not_checked: ["NewProviderLargeSubmission"]),
        billing: [name: "KEVIN LANE DO PA", npi: "1003001579", taxonomy: "207Q00000X"]),
      single("single/05_excessive_charges.x12", "Total over $750,000 → ExcessiveTotalCharges",
        claim("EXCESS01", lines: [{"27447", "800000.00", "20260810"}]),
        ok("EXCESS01", ["ExcessiveTotalCharges", "HighValueClaim", "UnauthorizedProcedure"],
          not_checked: ["NewProviderLargeSubmission"]),
        @valid_ortho),
      single("single/06_extreme_amount.x12", "Total over $1,000,000 → ExtremeAmounts and ExcessiveTotalCharges",
        claim("EXTREME01", lines: [{"27447", "1250000.00", "20260810"}]),
        ok("EXTREME01", ["ExtremeAmounts", "ExcessiveTotalCharges", "HighValueClaim", "UnauthorizedProcedure"],
          not_checked: ["NewProviderLargeSubmission"]),
        @valid_ortho),
      single("single/07_suspicious_low_charge.x12", "Total under $5 → SuspiciouslyLowCharge",
        claim("LOWCHG01", lines: [{"99211", "3.50", "20260903"}]),
        ok("LOWCHG01", ["SuspiciouslyLowCharge"])),
      single("single/08_future_service_date.x12", "Service date in 2099 → FutureServiceDate and ImpossibleDates",
        claim("FUTURE01", lines: [{"99213", "150.00", "20991231"}]),
        ok("FUTURE01", ["FutureServiceDate", "ImpossibleDates"])),
      single("single/09_service_before_1900.x12",
        "Service date before 1900 → ImpossibleDates; NPPES rejects (NPI not issued until 2007)",
        claim("OLDDATE01", lines: [{"99213", "150.00", "18991231"}]),
        ok("OLDDATE01", ["ImpossibleDates"], nppes: "was not issued until")),
      single("single/10_missing_diagnosis.x12", "No HI segment → MissingDiagnosisCodes",
        claim("NODX01", dx: []), ok("NODX01", ["MissingDiagnosisCodes"])),
      single("single/11_missing_dob.x12", "No DMG segment (no date of birth) → MissingRequiredFields",
        claim("NODOB01", member: [dob: nil]), ok("NODOB01", ["MissingRequiredFields"])),
      single("single/12_patient_too_old.x12", "Born 1880 → PatientAgeOutOfRange",
        claim("OLDPT01", member: [dob: "18800101"]), ok("OLDPT01", ["PatientAgeOutOfRange"])),
      single("single/13_dob_in_future.x12", "Born 2099 (negative age) → PatientAgeOutOfRange",
        claim("FUTDOB01", member: [dob: "20990101"]), ok("FUTDOB01", ["PatientAgeOutOfRange"])),
      single("single/14_npi_bad_format.x12", "9-digit billing NPI → InvalidNPIFormat, InvalidProviderNPI; NPPES rejects",
        claim("NPIFMT01"),
        ok("NPIFMT01", ["InvalidNPIFormat", "InvalidProviderNPI"], nppes: "not found in NPPES"),
        billing: [npi: "123456789"]),
      single("single/15_npi_bad_checksum.x12", "Billing NPI fails Luhn (so it cannot be in NPPES) → InvalidProviderNPI; NPPES rejects",
        claim("NPILUHN01"), ok("NPILUHN01", ["InvalidProviderNPI"], nppes: "not found in NPPES"),
        billing: [name: "RIVERSIDE FAMILY PRACTICE", npi: "1234567890", taxonomy: "207Q00000X"]),
      single("single/16_npi_not_in_nppes.x12", "Luhn-valid NPI absent from NPPES → NPPES rejects; no engine rule",
        claim("NPIUNK01"), ok("NPIUNK01", [], nppes: "not found in NPPES"),
        billing: [name: "UNREGISTERED CLINIC", npi: "1999999992"]),
      single("single/17_npi_deactivated.x12", "Real NPI deactivated 2024-12-12, service 2026 → NPPES rejects",
        claim("NPIDEAC01"), ok("NPIDEAC01", [], nppes: "was deactivated"),
        billing: [name: "MARIA GARCIA MD", npi: "1003002304", taxonomy: "207Q00000X"]),
      single("single/18_npi_deactivated_later.x12", "Same deactivated provider, service before deactivation → NPPES ok",
        claim("NPIDEAC02", lines: [{"99213", "150.00", "20230301"}]), ok("NPIDEAC02", []),
        billing: [name: "MARIA GARCIA MD", npi: "1003002304", taxonomy: "207Q00000X"]),
      single("single/18b_npi_deactivated_mid_claim.x12",
        "Same provider, one line before and one after the 2024-12-12 deactivation → NPPES rejects the later line",
        claim("NPIDEAC03", lines: [{"99213", "150.00", "20241201"}, {"99213", "150.00", "20241220"}]),
        ok("NPIDEAC03", [], nppes: "service rendered on 2024-12-20"),
        billing: [name: "MARIA GARCIA MD", npi: "1003002304", taxonomy: "207Q00000X"]),
      single("single/19_npi_reactivated.x12",
        "Real NPI deactivated 2008-01-09, reactivated 2009-07-10; service 2026 → NPPES ok",
        claim("NPIREAC01"), ok("NPIREAC01", []),
        billing: [name: "ETHERIDGE CHIROPRACTIC CLINIC INC", npi: "1003003534", taxonomy: "111N00000X"]),
      single("single/19b_npi_reactivated_gap.x12",
        "Same NPI, service 2008-06-01 between deactivation and reactivation → NPPES rejects",
        claim("NPIREAC02", lines: [{"99213", "150.00", "20080601"}]), ok("NPIREAC02", [], nppes: "was deactivated"),
        billing: [name: "ETHERIDGE CHIROPRACTIC CLINIC INC", npi: "1003003534", taxonomy: "111N00000X"]),
      single("single/20_missing_taxonomy.x12", "No PRV*BI, $2,500 → MissingProviderTaxonomy",
        claim("NOTAX01", lines: [{"99215", "2500.00", "20260904"}]),
        ok("NOTAX01", ["MissingProviderTaxonomy"]), @no_taxonomy),
      single("single/21_missing_taxonomy_new_provider.x12",
        "No taxonomy, $8,000 → MissingProviderTaxonomy, UnauthorizedProcedure; TaxonomyMismatchNewProvider not checked (no tenure)",
        claim("NOTAX02", lines: [{"20610", "8000.00", "20260904"}]),
        ok("NOTAX02", ["MissingProviderTaxonomy", "UnauthorizedProcedure"], not_checked: ["TaxonomyMismatchNewProvider"]),
        billing: [name: "SHAZA AWAD DDS", npi: "1003625385", taxonomy: nil]),
      single("single/22_no_prior_auth.x12", "$7,500 with no prior authorization → UnauthorizedProcedure",
        claim("NOAUTH01", lines: [{"29881", "7500.00", "20260904"}]),
        ok("NOAUTH01", ["UnauthorizedProcedure"]), @valid_ortho),
      single("single/23_with_prior_auth.x12", "$7,500 with REF*G1 prior authorization → no rule should match",
        claim("AUTH01", prior_auth: "PA20260001", lines: [{"29881", "7500.00", "20260904"}]),
        ok("AUTH01", []), @valid_ortho),
      single("single/24_weekend_office_visit.x12",
        "Office visit (POS 11) on Saturday 2026-09-05, $650 → WeekendOfficeVisit review",
        claim("WEEKEND01", lines: [{"99214", "650.00", "20260905"}]),
        ok("WEEKEND01", ["WeekendOfficeVisit"])),
      single("single/25_missing_billing_npi.x12", "NM1*85 with no NPI → MissingRequiredFields",
        claim("NONPI01"), ok("NONPI01", ["MissingRequiredFields"]),
        billing: [npi: ""]),
      single("single/26_rendering_npi_deactivated.x12",
        "Valid billing NPI, deactivated rendering provider (NM1*82) → NPPES should reject",
        claim("REND01", rendering: %{last: "GARCIA", first: "MARIA", npi: "1003002304", taxonomy: "207Q00000X"}),
        ok("REND01", [], nppes: "was deactivated")),
      single("single/27_many_rules.x12",
        "ER 99285, $15,000, no taxonomy, service in 2099 → five rules at once",
        claim("COMBO01", pos: "23", lines: [{"99285", "15000.00", "20991231"}]),
        ok("COMBO01",
          ["FutureServiceDate", "ImpossibleDates", "HighComplexityERVisit", "MissingProviderTaxonomy", "UnauthorizedProcedure"],
          not_checked: ["NewProviderLargeSubmission", "TaxonomyMismatchNewProvider"]),
        @no_taxonomy),
      single("single/28_boundary_50000.x12", "Exactly $50,000.00 → HighValueClaim must NOT match (> not >=)",
        claim("BOUND01", lines: [{"27447", "50000.00", "20260814"}]),
        ok("BOUND01", ["UnauthorizedProcedure"], not_checked: ["NewProviderLargeSubmission"]), @valid_ortho),
      single("single/29_boundary_5000.x12", "Exactly $5,000.00 → UnauthorizedProcedure must NOT match",
        claim("BOUND02", lines: [{"29881", "5000.00", "20260814"}]), ok("BOUND02", []), @valid_ortho),
      single("single/30_boundary_5.x12", "Exactly $5.00 → SuspiciouslyLowCharge must NOT match",
        claim("BOUND03", lines: [{"99211", "5.00", "20260814"}]), ok("BOUND03", [])),
      single("single/31_weekend_office_sunday.x12", "Office visit (POS 11) on Sunday 2026-09-06, $650 → WeekendOfficeVisit",
        claim("WEEKEND02", lines: [{"99214", "650.00", "20260906"}]), ok("WEEKEND02", ["WeekendOfficeVisit"])),
      single("single/32_weekday_office_visit.x12", "Office visit (POS 11) on Friday 2026-09-04, $650 → no match",
        claim("WEEKEND03", lines: [{"99214", "650.00", "20260904"}]), ok("WEEKEND03", [])),
      single("single/33_weekend_not_office.x12", "Home visit (POS 12) on Saturday 2026-09-05, $650 → no match",
        claim("WEEKEND04", pos: "12", lines: [{"99214", "650.00", "20260905"}]), ok("WEEKEND04", [])),
      single("single/34_weekend_office_500.x12", "Office visit on Saturday, exactly $500.00 → no match (> not >=)",
        claim("WEEKEND05", lines: [{"99214", "500.00", "20260905"}]), ok("WEEKEND05", []))
    ]
  end

  def formats do
    [
      single("formats/01_institutional_837i.x12", "837I institutional claim (SV2, CL1), clean",
        claim("INST01", pos: "13", lines: [{"99284", "900.00", "20260911"}]), ok("INST01", []),
        kind: :i, billing: [name: "THE ROSS ORTHOPAEDIC WELLNESS CENTER", npi: "1003005000", taxonomy: "207X00000X"]),
      single("formats/02_dental_837d.x12", "837D dental claim (SV3, TOO), clean",
        claim("DENT01", lines: [{"D1110", "95.00", "20260912"}]), ok("DENT01", []), kind: :d),
      single("formats/03_single_line_no_newlines.x12", "Whole file on one line (no newlines), clean",
        claim("ONELINE01"), ok("ONELINE01", []), format: [newline: ""]),
      single("formats/04_crlf_line_endings.x12", "Windows CRLF line endings, clean",
        claim("CRLF01"), ok("CRLF01", []), format: [newline: "\r\n"]),
      single("formats/05_alternate_delimiters.edi",
        "Element separator | and sub-element separator > (both legal per ISA); ER 99285 over $10,000",
        claim("ALTDELIM01", pos: "23", lines: [{"99285", "12000.00", "20260913"}]),
        ok("ALTDELIM01", ["HighComplexityERVisit", "UnauthorizedProcedure"], not_checked: ["NewProviderLargeSubmission"]),
        format: [element: "|", sub: ">"],
        billing: [name: "KEVIN LANE DO PA", npi: "1003001579", taxonomy: "207Q00000X"])
    ]
  end

  def multi_claim do
    three = [
      claim("MULTI01", member: [last: "ALPHA", member_id: "MCD000000101"]),
      claim("MULTI02", member: [last: "BRAVO", member_id: "MCD000000102"], lines: [{"99285", "64000.00", "20260908"}]),
      claim("MULTI03", member: [last: "CHARLIE", member_id: "MCD000000103"], dx: [])
    ]

    tx_a = [
      claim("TXA01", member: [last: "DELTA", member_id: "MCD000000201"]),
      claim("TXA02", member: [last: "ECHO", member_id: "MCD000000202"], lines: [{"99211", "2.00", "20260907"}])
    ]

    tx_b = [
      claim("TXB01", member: [last: "FOXTROT", member_id: "MCD000000301"]),
      claim("TXB02", member: [last: "GOLF", member_id: "MCD000000302", dob: "18700101"])
    ]

    [
      %{
        file: "multi/01_three_claims.x12",
        purpose: "Three subscribers, one claim each, in one transaction set",
        content: interchange([transaction(three, @valid_ortho)]),
        expect: %{
          claims: [
            ok("MULTI01", []),
            ok("MULTI02", ["HighValueClaim", "HighComplexityERVisit", "UnauthorizedProcedure"],
              not_checked: ["NewProviderLargeSubmission"]),
            ok("MULTI03", ["MissingDiagnosisCodes"])
          ]
        }
      },
      %{
        file: "multi/02_two_transaction_sets.x12",
        purpose: "One interchange, two ST..SE transaction sets with two claims each",
        content: interchange([transaction(tx_a), transaction(tx_b)]),
        expect: %{
          claims: [
            ok("TXA01", []),
            ok("TXA02", ["SuspiciouslyLowCharge"]),
            ok("TXB01", []),
            ok("TXB02", ["PatientAgeOutOfRange"])
          ]
        }
      },
      %{
        file: "multi/03_two_claims_same_subscriber.x12",
        purpose: "One subscriber with two claims (two CLMs under one HL)",
        content:
          interchange([
            transaction(
              [claim("SAMESUB01"), claim("SAMESUB02", lines: [{"99211", "2.00", "20260908"}])],
              same_subscriber: true
            )
          ]),
        expect: %{claims: [ok("SAMESUB01", []), ok("SAMESUB02", ["SuspiciouslyLowCharge"])]}
      }
    ]
  end

  def envelope_errors do
    two = interchange([transaction([claim("TRUNC01"), claim("TRUNC02", member: [member_id: "MCD000000402"])])])
    [_, after_second] = String.split(two, "CLM*TRUNC02", parts: 2)
    truncated = String.slice(two, 0, byte_size(two) - byte_size(after_second)) <> "*150.00***11:B"

    [
      %{
        file: "errors/01_truncated_file.x12",
        purpose: "File cut off mid-way through the second claim (no SE/GE/IEA) → reject as incomplete",
        content: truncated,
        expect: %{error: "incomplete transmission"}
      },
      %{
        file: "errors/02_wrong_se_count.x12",
        purpose: "SE segment count off by 3 → reject",
        content: interchange([transaction([claim("SECOUNT01")])], se_adjust: 3),
        expect: %{error: "SE segment count"}
      },
      %{
        file: "errors/03_control_number_mismatch.x12",
        purpose: "IEA control number differs from ISA → reject",
        content: interchange([transaction([claim("CTRL01")])], iea_control: "000000999"),
        expect: %{error: "interchange control number mismatch"}
      },
      %{
        file: "errors/04_not_x12.edi",
        purpose: "Plain text that is not X12 → reject",
        content: String.duplicate("This is not an X12 file. It is a plain text note. ", 4) <> "\n",
        expect: %{error: "must start with ISA"}
      },
      %{
        file: "errors/05_too_short.x12",
        purpose: "File shorter than an ISA segment → reject",
        content: "ISA*00*~\n",
        expect: %{error: "too short"}
      },
      %{
        file: "errors/06_envelope_no_claims.x12",
        purpose: "Valid envelope with a billing provider but no CLM → rejected, no claims",
        content: interchange([transaction([])]),
        expect: %{error: "no claims found"}
      }
    ]
  end

  # A business-schema JSON claim, as a .json upload or a .json inside a zip.
  # JSON claims can carry fields X12 conversion never fills (tenure, auth).
  def json_claim do
    %{
      "claim_id" => "ZIPJSON01",
      "provider" => %{"npi" => "1003001538", "tenure_days" => 400},
      "billing_provider" => %{"npi" => "1003001538", "taxonomy" => "207R00000X"},
      "patient" => %{"date_of_birth" => "19850315"},
      "financial" => %{"claim_amount" => 220.0},
      "claim_totals" => %{"total_charges" => 220.0},
      "authorization" => %{"authorization_number" => "PA20260002"},
      "diagnosis_codes" => [%{"qualifier" => "ABK", "code" => "Z0000"}],
      "service_lines" => [%{"line_number" => 1, "date_of_service" => "20260910", "procedure_code" => "99213"}]
    }
  end

  def zips do
    bundle = [
      {"bundle/claim_a.x12", interchange([transaction([claim("ZIPX12A")])])},
      {"bundle/claim_b.edi", interchange([transaction([claim("ZIPEDIB", dx: [])])], control: "000000102")},
      {"bundle/claim_c.json", X12Suite.pretty_json(json_claim())},
      {"bundle/README.txt", "Ignored: not .x12, .edi or .json\n"}
    ]

    [
      {%{
         file: "zip/01_mixed_bundle.zip",
         purpose: "Zip holding an .x12, an .edi, a .json and a .txt (ignored)",
         expect: %{claims: [ok("ZIPX12A", []), ok("ZIPEDIB", ["MissingDiagnosisCodes"]), ok("ZIPJSON01", [])]}
       }, bundle},
      {%{
         file: "zip/02_path_traversal.zip",
         purpose:
           "Zip whose only entry is ../escape.x12 → Erlang's in-memory unzip strips the ../ " <>
             "and the entry is read as escape.x12; nothing is written to disk",
         expect: %{claims: [ok("ESCAPE01", [])]}
       }, [{"../escape.x12", interchange([transaction([claim("ESCAPE01")])])}]}
    ]
  end

  # Large batch: `n` clean claims split into 1,000-claim X12 files inside one
  # zip (each file stays under the 10 MB upload limit).
  def large(n) do
    entries =
      1..n
      |> Enum.chunk_every(1000)
      |> Enum.with_index(1)
      |> Enum.map(fn {ids, part} ->
        claims =
          Enum.map(ids, fn i ->
            num = String.pad_leading(Integer.to_string(i), 6, "0")
            claim("BULK" <> num, member: [member_id: "MCD9" <> num])
          end)

        name = "large/part_#{String.pad_leading(Integer.to_string(part), 3, "0")}.x12"
        {name, interchange([transaction(claims)], control: String.pad_leading(Integer.to_string(part), 9, "0"))}
      end)

    {%{
       file: "large/large_batch_#{n}.zip",
       purpose: "#{n} clean claims across #{length(entries)} X12 files",
       expect: %{claim_count: n, over_cap: n > 15_000}
     }, entries}
  end
end

defmodule X12Suite do
  @moduledoc false
  def pretty_json(term),
    do: term |> JSON.encode!() |> :json.decode() |> :json.format() |> IO.iodata_to_binary()
end

root = Path.dirname(__ENV__.file)
files_dir = Path.join(root, "files")
{opts, _} = OptionParser.parse!(System.argv(), strict: [large: :integer])

write = fn rel, content ->
  path = Path.join(files_dir, rel)
  File.mkdir_p!(Path.dirname(path))
  File.write!(path, content)
end

write_zip = fn rel, entries ->
  path = Path.join(files_dir, rel)
  File.mkdir_p!(Path.dirname(path))
  File.rm(path)
  zip_entries = Enum.map(entries, fn {name, data} -> {String.to_charlist(name), data} end)
  {:ok, _} = :zip.create(String.to_charlist(path), zip_entries)
end

case opts[:large] do
  nil ->
    File.rm_rf!(files_dir)
    cases = X12Suite.Cases.all()
    Enum.each(cases, &write.(&1.file, &1.content))

    zip_cases =
      Enum.map(X12Suite.Cases.zips(), fn {meta, entries} ->
        write_zip.(meta.file, entries)
        meta
      end)

    manifest = %{
      about:
        "Expected results for each file in files/. `matched` is the exact set of rules " <>
          "that should match; `not_checked` must be among the rules reported as not checked; " <>
          "`known_issue` marks cases the current code gets wrong. Expectations assume the " <>
          "business rules seeded by priv/repo/seeds.exs as of 2026-10-16.",
      cases:
        Enum.map(cases, &Map.delete(&1, :content)) ++ zip_cases
        |> Enum.map(fn c -> c |> Enum.reject(fn {_, v} -> is_nil(v) end) |> Map.new() end)
    }

    File.write!(Path.join(root, "manifest.json"), X12Suite.pretty_json(manifest) <> "\n")
    IO.puts("Wrote #{length(cases) + length(zip_cases)} files and manifest.json under #{root}")

  n ->
    {meta, entries} = X12Suite.Cases.large(n)
    write_zip.(meta.file, entries)
    File.write!(Path.join([files_dir, "large", "large_batch_#{n}.json"]), X12Suite.pretty_json(meta) <> "\n")
    IO.puts("Wrote #{meta.file} (#{n} claims) — not committed; see .gitignore")
end
