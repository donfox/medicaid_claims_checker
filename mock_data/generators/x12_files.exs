# The X12 837 cases: raw .x12, .edi and .zip files, each with its expected
# outcome. Run by ../generate.exs, which writes them and manifest.json;
# don't run this file on its own.
#
# Patients and claims are synthetic. Provider NPIs are real, from the NPPES
# registry the app imports (checked against the NPI Registry 2026-10-17),
# except the deliberate bad ones: 1234567890 (fails Luhn), 1999999992
# (Luhn-valid but unassigned), and the malformed NPIs in the format cases.
# Provider names in deactivated cases are made up: CMS publishes no name
# for a deactivated NPI.
# Check results with mock_data/verify.exs.

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
      prior_auth: Keyword.get(opts, :prior_auth),
      # CLM05-3: 1 original, 7 replacement, 8 void.
      frequency: Keyword.get(opts, :frequency, "1")
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

    clm = [["CLM", c.id, c.amount, "", "", comp.([c.pos, facility_code, c.frequency]), "Y", "A", "Y", "Y"]]
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
  # should match; `not_checked` is the exact set of active rules that must come
  # back "not checked"; `nppes` is :ok or a substring of the rejection reason.
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
    single_claims() ++ formats() ++ multi_claim() ++ envelope_errors() ++ frequency_codes() ++ broken_zips()
  end

  def single_claims do
    [
      single("X_x12_files/X1_837p_professional/clean_office_visit.x12", "Clean low-value office visit; no rule should match",
        claim("CLEAN001"), ok("CLEAN001", [])),
      single("X_x12_files/X1_837p_professional/clean_multi_line.x12", "Clean claim with three service lines and two diagnoses",
        claim("CLEAN002",
          dx: ["Z0000", "J069"],
          lines: [{"99214", "210.00", "20260902"}, {"87880", "45.00", "20260902"}, {"36415", "18.00", "20260902"}]),
        ok("CLEAN002", [])),
      single("R_business_rules/R2_each_rule_alone/HighValueClaim.x12", "Claim over $50,000 → HighValueClaim review",
        claim("HIGHVAL01", lines: [{"27447", "62000.00", "20260814"}]),
        ok("HIGHVAL01", ["HighValueClaim", "UnauthorizedProcedure"], not_checked: ["NewProviderLargeSubmission"]),
        @valid_ortho),
      single("R_business_rules/R2_each_rule_alone/HighComplexityERVisit.x12", "99285 over $10,000 → HighComplexityERVisit review",
        claim("ERVISIT01", pos: "23", lines: [{"99285", "12500.00", "20260820"}]),
        ok("ERVISIT01", ["HighComplexityERVisit", "UnauthorizedProcedure"], not_checked: ["NewProviderLargeSubmission"]),
        billing: [name: "KEVIN LANE DO PA", npi: "1003001579", taxonomy: "207Q00000X"]),
      single("R_business_rules/R2_each_rule_alone/ExcessiveTotalCharges.x12", "Total over $750,000 → ExcessiveTotalCharges",
        claim("EXCESS01", lines: [{"27447", "800000.00", "20260810"}]),
        ok("EXCESS01", ["ExcessiveTotalCharges", "HighValueClaim", "UnauthorizedProcedure"],
          not_checked: ["NewProviderLargeSubmission"]),
        @valid_ortho),
      single("R_business_rules/R2_each_rule_alone/ExtremeAmounts.x12", "Total over $1,000,000 → ExtremeAmounts and ExcessiveTotalCharges",
        claim("EXTREME01", lines: [{"27447", "1250000.00", "20260810"}]),
        ok("EXTREME01", ["ExtremeAmounts", "ExcessiveTotalCharges", "HighValueClaim", "UnauthorizedProcedure"],
          not_checked: ["NewProviderLargeSubmission"]),
        @valid_ortho),
      single("R_business_rules/R2_each_rule_alone/SuspiciouslyLowCharge.x12", "Total under $5 → SuspiciouslyLowCharge",
        claim("LOWCHG01", lines: [{"99211", "3.50", "20260903"}]),
        ok("LOWCHG01", ["SuspiciouslyLowCharge"])),
      single("R_business_rules/R2_each_rule_alone/FutureServiceDate.x12",
        "Service date in 2099 → FutureServiceDate only (ImpossibleDates covers dates before 1900)",
        claim("FUTURE01", lines: [{"99213", "150.00", "20991231"}]),
        ok("FUTURE01", ["FutureServiceDate"])),
      single("R_business_rules/R2_each_rule_alone/ImpossibleDates.x12",
        "Service date before 1900 → ImpossibleDates; NPPES rejects (NPI not issued until 2007)",
        claim("OLDDATE01", lines: [{"99213", "150.00", "18991231"}]),
        ok("OLDDATE01", ["ImpossibleDates"], nppes: "was not issued until")),
      single("R_business_rules/R2_each_rule_alone/MissingDiagnosisCodes.x12", "No HI segment → MissingDiagnosisCodes",
        claim("NODX01", dx: []), ok("NODX01", ["MissingDiagnosisCodes"])),
      single("R_business_rules/R10_age_out_of_range_or_missing_dob/missing_dob.x12", "No DMG segment (no date of birth) → MissingRequiredFields",
        claim("NODOB01", member: [dob: nil]), ok("NODOB01", ["MissingRequiredFields"])),
      single("R_business_rules/R10_age_out_of_range_or_missing_dob/born_1880.x12", "Born 1880 → PatientAgeOutOfRange",
        claim("OLDPT01", member: [dob: "18800101"]), ok("OLDPT01", ["PatientAgeOutOfRange"])),
      single("R_business_rules/R10_age_out_of_range_or_missing_dob/born_2099.x12", "Born 2099 (negative age) → PatientAgeOutOfRange",
        claim("FUTDOB01", member: [dob: "20990101"]), ok("FUTDOB01", ["PatientAgeOutOfRange"])),
      single("N_nppes_provider_checks/N2_malformed_npi/nine_digit_npi.x12", "9-digit billing NPI → InvalidNPIFormat, InvalidProviderNPI; NPPES rejects",
        claim("NPIFMT01"),
        ok("NPIFMT01", ["InvalidNPIFormat", "InvalidProviderNPI"], nppes: "not found in NPPES"),
        billing: [npi: "123456789"]),
      single("N_nppes_provider_checks/N2_malformed_npi/bad_checksum.x12", "Billing NPI fails Luhn (so it cannot be in NPPES) → InvalidProviderNPI; NPPES rejects",
        claim("NPILUHN01"), ok("NPILUHN01", ["InvalidProviderNPI"], nppes: "not found in NPPES"),
        billing: [name: "RIVERSIDE FAMILY PRACTICE", npi: "1234567890", taxonomy: "207Q00000X"]),
      single("N_nppes_provider_checks/N3_npi_never_issued/unissued_npi.x12", "Luhn-valid NPI absent from NPPES → NPPES rejects; no engine rule",
        claim("NPIUNK01"), ok("NPIUNK01", [], nppes: "not found in NPPES"),
        billing: [name: "UNREGISTERED CLINIC", npi: "1999999992"]),
      single("N_nppes_provider_checks/N4_deactivated_provider/deactivated_provider.x12", "Real NPI deactivated 2024-12-12, service 2026 → NPPES rejects",
        claim("NPIDEAC01"), ok("NPIDEAC01", [], nppes: "was deactivated"),
        billing: [name: "MARIA GARCIA MD", npi: "1003002304", taxonomy: "207Q00000X"]),
      single("N_nppes_provider_checks/N5_service_before_deactivation/service_before_deactivation.x12", "Same deactivated provider, service before deactivation → NPPES ok",
        claim("NPIDEAC02", lines: [{"99213", "150.00", "20230301"}]), ok("NPIDEAC02", []),
        billing: [name: "MARIA GARCIA MD", npi: "1003002304", taxonomy: "207Q00000X"]),
      single("N_nppes_provider_checks/N6_deactivated_mid_claim/deactivated_mid_claim.x12",
        "Same provider, one line before and one after the 2024-12-12 deactivation → NPPES rejects the later line",
        claim("NPIDEAC03", lines: [{"99213", "150.00", "20241201"}, {"99213", "150.00", "20241220"}]),
        ok("NPIDEAC03", [], nppes: "service rendered on 2024-12-20"),
        billing: [name: "MARIA GARCIA MD", npi: "1003002304", taxonomy: "207Q00000X"]),
      single("N_nppes_provider_checks/N7_reactivated_provider/reactivated_provider.x12",
        "Real NPI deactivated 2008-01-09, reactivated 2009-07-10; service 2026 → NPPES ok",
        claim("NPIREAC01"), ok("NPIREAC01", []),
        billing: [name: "ETHERIDGE CHIROPRACTIC CLINIC INC", npi: "1003003534", taxonomy: "111N00000X"]),
      single("N_nppes_provider_checks/N7_reactivated_provider/reactivation_gap.x12",
        "Same NPI, service 2008-06-01 between deactivation and reactivation → NPPES rejects",
        claim("NPIREAC02", lines: [{"99213", "150.00", "20080601"}]), ok("NPIREAC02", [], nppes: "was deactivated"),
        billing: [name: "ETHERIDGE CHIROPRACTIC CLINIC INC", npi: "1003003534", taxonomy: "111N00000X"]),
      single("R_business_rules/R2_each_rule_alone/MissingProviderTaxonomy.x12", "No PRV*BI, $2,500 → MissingProviderTaxonomy",
        claim("NOTAX01", lines: [{"99215", "2500.00", "20260904"}]),
        ok("NOTAX01", ["MissingProviderTaxonomy"]), @no_taxonomy),
      single("R_business_rules/R9_rule_not_decidable/missing_taxonomy_new_provider.x12",
        "No taxonomy, $8,000 → MissingProviderTaxonomy, UnauthorizedProcedure; TaxonomyMismatchNewProvider not checked (no tenure)",
        claim("NOTAX02", lines: [{"20610", "8000.00", "20260904"}]),
        ok("NOTAX02", ["MissingProviderTaxonomy", "UnauthorizedProcedure"], not_checked: ["TaxonomyMismatchNewProvider"]),
        billing: [name: "SHAZA AWAD DDS", npi: "1003625385", taxonomy: nil]),
      single("R_business_rules/R2_each_rule_alone/UnauthorizedProcedure.x12", "$7,500 with no prior authorization → UnauthorizedProcedure",
        claim("NOAUTH01", lines: [{"29881", "7500.00", "20260904"}]),
        ok("NOAUTH01", ["UnauthorizedProcedure"]), @valid_ortho),
      single("R_business_rules/R2_each_rule_alone/UnauthorizedProcedure_with_auth_no_match.x12", "$7,500 with REF*G1 prior authorization → no rule should match",
        claim("AUTH01", prior_auth: "PA20260001", lines: [{"29881", "7500.00", "20260904"}]),
        ok("AUTH01", []), @valid_ortho),
      single("R_business_rules/R6_weekend_office_variants/saturday_office.x12",
        "Office visit (POS 11) on Saturday 2026-09-05, $650 → WeekendOfficeVisit review",
        claim("WEEKEND01", lines: [{"99214", "650.00", "20260905"}]),
        ok("WEEKEND01", ["WeekendOfficeVisit"])),
      single("N_nppes_provider_checks/N10_no_billing_npi/missing_billing_npi.x12", "NM1*85 with no NPI → MissingRequiredFields",
        claim("NONPI01"), ok("NONPI01", ["MissingRequiredFields"]),
        billing: [npi: ""]),
      single("N_nppes_provider_checks/N11_deactivated_rendering_provider/rendering_npi_deactivated.x12",
        "Valid billing NPI, deactivated rendering provider (NM1*82) → NPPES should reject",
        claim("REND01", rendering: %{last: "GARCIA", first: "MARIA", npi: "1003002304", taxonomy: "207Q00000X"}),
        ok("REND01", [], nppes: "was deactivated")),
      single("R_business_rules/R3_several_rules/many_rules.x12",
        "ER 99285, $15,000, no taxonomy, service in 2099 → four rules at once",
        claim("COMBO01", pos: "23", lines: [{"99285", "15000.00", "20991231"}]),
        ok("COMBO01",
          ["FutureServiceDate", "HighComplexityERVisit", "MissingProviderTaxonomy", "UnauthorizedProcedure"],
          not_checked: ["NewProviderLargeSubmission", "TaxonomyMismatchNewProvider"]),
        @no_taxonomy),
      single("R_business_rules/R5_exact_thresholds/exactly_50000.x12", "Exactly $50,000.00 → HighValueClaim must NOT match (> not >=)",
        claim("BOUND01", lines: [{"27447", "50000.00", "20260814"}]),
        ok("BOUND01", ["UnauthorizedProcedure"], not_checked: ["NewProviderLargeSubmission"]), @valid_ortho),
      single("R_business_rules/R5_exact_thresholds/exactly_5000.x12", "Exactly $5,000.00 → UnauthorizedProcedure must NOT match",
        claim("BOUND02", lines: [{"29881", "5000.00", "20260814"}]), ok("BOUND02", []), @valid_ortho),
      single("R_business_rules/R5_exact_thresholds/exactly_5.x12", "Exactly $5.00 → SuspiciouslyLowCharge must NOT match",
        claim("BOUND03", lines: [{"99211", "5.00", "20260814"}]), ok("BOUND03", [])),
      single("R_business_rules/R6_weekend_office_variants/sunday_office.x12", "Office visit (POS 11) on Sunday 2026-09-06, $650 → WeekendOfficeVisit",
        claim("WEEKEND02", lines: [{"99214", "650.00", "20260906"}]), ok("WEEKEND02", ["WeekendOfficeVisit"])),
      single("R_business_rules/R6_weekend_office_variants/weekday_office_no_match.x12", "Office visit (POS 11) on Friday 2026-09-04, $650 → no match",
        claim("WEEKEND03", lines: [{"99214", "650.00", "20260904"}]), ok("WEEKEND03", [])),
      single("R_business_rules/R6_weekend_office_variants/saturday_home_visit_no_match.x12", "Home visit (POS 12) on Saturday 2026-09-05, $650 → no match",
        claim("WEEKEND04", pos: "12", lines: [{"99214", "650.00", "20260905"}]), ok("WEEKEND04", [])),
      single("R_business_rules/R5_exact_thresholds/exactly_500_weekend_office.x12", "Office visit on Saturday, exactly $500.00 → no match (> not >=)",
        claim("WEEKEND05", lines: [{"99214", "500.00", "20260905"}]), ok("WEEKEND05", [])),
      single("R_business_rules/R4_problem_on_second_line/future_date_line2.x12",
        "Line 1 dated 2026-09-01, line 2 dated 2099 → FutureServiceDate (the rule checks every line)",
        claim("FUTURE02", lines: [{"99213", "150.00", "20260901"}, {"80053", "45.00", "20991231"}]),
        ok("FUTURE02", ["FutureServiceDate"])),
      single("R_business_rules/R4_problem_on_second_line/pre1900_line2.x12",
        "Line 1 dated 2026-09-01, line 2 dated 1899 → ImpossibleDates; NPPES rejects line 2 (NPI not issued until 2007)",
        claim("OLDDATE02", lines: [{"99213", "150.00", "20260901"}, {"80053", "45.00", "18991231"}]),
        ok("OLDDATE02", ["ImpossibleDates"], nppes: "was not issued until")),
      single("R_business_rules/R4_problem_on_second_line/er_99285_line2.x12",
        "Venipuncture on line 1, ER 99285 on line 2, $12,525 → HighComplexityERVisit (the rule checks every line)",
        claim("ERVISIT02", pos: "23", lines: [{"36415", "25.00", "20260820"}, {"99285", "12500.00", "20260820"}]),
        ok("ERVISIT02", ["HighComplexityERVisit", "UnauthorizedProcedure"], not_checked: ["NewProviderLargeSubmission"]),
        billing: [name: "KEVIN LANE DO PA", npi: "1003001579", taxonomy: "207Q00000X"])
    ]
  end

  def formats do
    [
      single("X_x12_files/X2_837i_institutional/institutional.x12", "837I institutional claim (SV2, CL1), clean",
        claim("INST01", pos: "13", lines: [{"99284", "900.00", "20260911"}]), ok("INST01", []),
        kind: :i, billing: [name: "THE ROSS ORTHOPAEDIC WELLNESS CENTER", npi: "1003005000", taxonomy: "207X00000X"]),
      single("X_x12_files/X3_837d_dental/dental.x12", "837D dental claim (SV3, TOO), clean",
        claim("DENT01", lines: [{"D1110", "95.00", "20260912"}]), ok("DENT01", []), kind: :d),
      single("E_edi_files/E1_plain_edi/clean_claim.edi", "Ordinary clean 837P claim in a file named .edi",
        claim("EDICLEAN01"), ok("EDICLEAN01", [])),
      single("X_x12_files/X6_one_line_or_windows_line_endings/no_newlines.x12", "Whole file on one line (no newlines), clean",
        claim("ONELINE01"), ok("ONELINE01", []), format: [newline: ""]),
      single("X_x12_files/X6_one_line_or_windows_line_endings/crlf_line_endings.x12", "Windows CRLF line endings, clean",
        claim("CRLF01"), ok("CRLF01", []), format: [newline: "\r\n"]),
      single("E_edi_files/E2_alternate_delimiters/alternate_delimiters.edi",
        "Element separator | and sub-element separator > (both legal per ISA); ER 99285 over $10,000",
        claim("ALTDELIM01", pos: "23", lines: [{"99285", "12000.00", "20260913"}]),
        ok("ALTDELIM01", ["HighComplexityERVisit", "UnauthorizedProcedure"], not_checked: ["NewProviderLargeSubmission"]),
        format: [element: "|", sub: ">"],
        billing: [name: "KEVIN LANE DO PA", npi: "1003001579", taxonomy: "207Q00000X"]),
      single("R_business_rules/R7_weekend_inpatient_stay/inpatient_weekend.x12",
        "837I bill type 11 (hospital inpatient) on Saturday 2026-09-12, $900 → no WeekendOfficeVisit " <>
          "(facility type 11 is not place of service 11, office)",
        claim("INST02", pos: "11", lines: [{"99223", "900.00", "20260912"}]), ok("INST02", []),
        kind: :i, billing: [name: "THE ROSS ORTHOPAEDIC WELLNESS CENTER", npi: "1003005000", taxonomy: "207X00000X"])
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
        file: "X_x12_files/X4_several_claims_one_transaction_set/three_claims.x12",
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
        file: "X_x12_files/X5_several_transaction_sets/two_transaction_sets.x12",
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
        file: "X_x12_files/X4_several_claims_one_transaction_set/two_claims_same_subscriber.x12",
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
        file: "X_x12_files/X7_broken_envelope_or_file/truncated.x12",
        purpose: "File cut off mid-way through the second claim (no SE/GE/IEA) → reject as incomplete",
        content: truncated,
        expect: %{error: "incomplete transmission"}
      },
      %{
        file: "X_x12_files/X7_broken_envelope_or_file/wrong_se_count.x12",
        purpose: "SE segment count off by 3 → reject",
        content: interchange([transaction([claim("SECOUNT01")])], se_adjust: 3),
        expect: %{error: "SE segment count"}
      },
      %{
        file: "X_x12_files/X7_broken_envelope_or_file/control_number_mismatch.x12",
        purpose: "IEA control number differs from ISA → reject",
        content: interchange([transaction([claim("CTRL01")])], iea_control: "000000999"),
        expect: %{error: "interchange control number mismatch"}
      },
      %{
        file: "E_edi_files/E3_not_x12/not_x12.edi",
        purpose: "Plain text that is not X12 → reject",
        content: String.duplicate("This is not an X12 file. It is a plain text note. ", 4) <> "\n",
        expect: %{error: "must start with ISA"}
      },
      %{
        file: "X_x12_files/X7_broken_envelope_or_file/too_short.x12",
        purpose: "File shorter than an ISA segment → reject",
        content: "ISA*00*~\n",
        expect: %{error: "too short"}
      },
      %{
        file: "X_x12_files/X7_broken_envelope_or_file/envelope_no_claims.x12",
        purpose: "Valid envelope with a billing provider but no CLM → rejected, no claims",
        content: interchange([transaction([])]),
        expect: %{error: "no claims found"}
      }
    ]
  end

  # Replacement (7) and void (8) claims: no rule looks at the frequency code,
  # so they match the same rules as the original (HighValueClaim.x12).
  def frequency_codes do
    for {code, kind} <- [{"7", "replacement"}, {"8", "void"}] do
      id = "FREQ#{code}X12"

      single("R_business_rules/R11_replacement_or_void_claim/#{kind}_frequency_#{code}.x12",
        "#{String.capitalize(kind)} (CLM05-3 = #{code}) of a claim over $50,000: the rules apply as to an original",
        claim(id, frequency: code, lines: [{"27447", "62000.00", "20260814"}]),
        ok(id, ["HighValueClaim", "UnauthorizedProcedure"], not_checked: ["NewProviderLargeSubmission"]),
        @valid_ortho)
    end
  end

  # A zip that can't be opened: a real zip cut off part-way.
  def broken_zips do
    {:ok, {_, whole}} =
      :zip.create(~c"claims.zip", [{~c"claim.x12", interchange([transaction([claim("CORRUPT01")])])}], [:memory])

    [
      %{
        file: "Z_zip_files/Z6_corrupt_zip/cut_off.zip",
        purpose: "Zip file cut off part-way, so it can't be opened → nothing to evaluate",
        content: binary_part(whole, 0, div(byte_size(whole), 2)),
        expect: %{error: "No processable claims found"}
      }
    ]
  end

  # A business-schema JSON claim, as a .json upload or a .json inside a zip.
  # JSON claims can carry fields X12 conversion never fills (tenure, auth).
  def json_claim(id \\ "ZIPJSON01") do
    %{
      "claim_id" => id,
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
         file: "Z_zip_files/Z1_mixed_file_types/mixed_bundle.zip",
         purpose: "Zip holding an .x12, an .edi, a .json and a .txt (ignored)",
         expect: %{claims: [ok("ZIPX12A", []), ok("ZIPEDIB", ["MissingDiagnosisCodes"]), ok("ZIPJSON01", [])]}
       }, bundle},
      {%{
         file: "Z_zip_files/Z3_path_traversal/path_traversal.zip",
         purpose:
           "Zip whose only entry is ../escape.x12 → Erlang's in-memory unzip strips the ../ " <>
             "and the entry is read as escape.x12; nothing is written to disk",
         expect: %{claims: [ok("ESCAPE01", [])]}
       }, [{"../escape.x12", interchange([transaction([claim("ESCAPE01")])])}]},
      {%{
         file: "Z_zip_files/Z2_json_only_zip/two_json_claims.zip",
         purpose: "Zip holding only .json claims",
         expect: %{claims: [ok("ZIPJSON02", []), ok("ZIPJSON03", [])]}
       },
       [
         {"claims/first.json", X12Suite.pretty_json(json_claim("ZIPJSON02"))},
         {"claims/second.json", X12Suite.pretty_json(json_claim("ZIPJSON03"))}
       ]},
      {%{
         file: "Z_zip_files/Z4_nothing_usable/empty.zip",
         purpose: "Zip with no entries → nothing to evaluate",
         expect: %{error: "No processable claims found"}
       }, []},
      {%{
         file: "Z_zip_files/Z4_nothing_usable/text_files_only.zip",
         purpose: "Zip holding only .txt and .csv files, which are ignored → nothing to evaluate",
         expect: %{error: "No processable claims found"}
       }, [{"notes.txt", "Not a claim.\n"}, {"export.csv", "claim_id,amount\nX1,100\n"}]},
      {%{
         file: "Z_zip_files/Z5_zip_inside_zip/nested.zip",
         purpose: "Zip holding an .x12 and another zip; the inner zip is ignored, so only the outer claim is evaluated",
         expect: %{claims: [ok("OUTER01", [])]}
       },
       [
         {"outer.x12", interchange([transaction([claim("OUTER01")])])},
         {"inner.zip", inner_zip([{"inner.x12", interchange([transaction([claim("INNER01")])], control: "000000103")}])}
       ]}
    ]
  end

  defp inner_zip(entries) do
    {:ok, {_, bin}} = :zip.create(~c"inner.zip", Enum.map(entries, fn {n, d} -> {String.to_charlist(n), d} end), [:memory])
    bin
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
       file: "Z_zip_files/Z7_over_15000_claims/large_batch_#{n}.zip",
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

# Returned to ../generate.exs, which writes the files and the manifest.
zips = Enum.map(X12Suite.Cases.zips(), fn {meta, entries} -> Map.put(meta, :zip_entries, entries) end)
X12Suite.Cases.all() ++ zips
