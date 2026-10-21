# The JSON claim cases, each with its expected outcome. Run by
# ../generate.exs, which writes them and manifest.json; don't run this file
# on its own.
#
# Claims use the field layout the rules see (X12.SegmentMapper.normalize
# output), so a rule that works on a sample works on a converted 837.
# provider.tenure_days and authorization.authorization_number are the
# exception: X12 conversion never fills tenure_days, so the two new-provider
# rules can only be exercised with JSON claims like these.
#
# Providers are real: names, NPIs, primary taxonomies and practice addresses
# from the NPI Registry (checked 2026-10-19). Exceptions, all named in the
# claim's sample_notes: the deliberately invalid NPIs, and the deactivated
# and dropped NPIs, for which CMS publishes no address. Patients, member IDs,
# tax IDs and authorization numbers are synthetic.
#
# Check results with mock_data/verify.exs.

defmodule Samples do
  @moduledoc false

  # Real providers (NPI Registry, primary taxonomy, practice location).
  @providers %{
    lane: {"1003001579", "KEVIN LANE DO PA", "207Q00000X", "4103 WILBARGER ST", "VERNON", "TX", "763843137"},
    midwest:
      {"1003001538", "MIDWEST INTERNAL MEDICINE ASSOCIATES LLC", "207R00000X", "1728 MARION WALDO RD", "MARION",
       "OH", "433027457"},
    coastal: {"1003308305", "COASTAL PLAINS PATHOLOGY PA", "207ZP0102X", "1705 TARBORO ST SW", "WILSON", "NC", "27893"},
    jarman: {"1003003229", "JARMAN ORTHOPEDICS, P.C.", "207X00000X", "501 4TH ST", "AURORA", "IN", "47001"},
    ross:
      {"1003005000", "THE ROSS ORTHOPAEDIC WELLNESS CENTER", "207X00000X", "5900 HILLANDALE DR SUITE 215", "LITHONIA",
       "GA", "300583802"},
    miami: {"1003005067", "MIAMI FAMILY CARE INC", "208D00000X", "15806 SW 98TH ST", "MIAMI", "FL", "33196"},
    singing_river:
      {"1003005133", "SINGING RIVER HEALTH SYSTEM", "208G00000X", "2101 HIGHWAY 90", "GAUTIER", "MS", "39553"},
    ninigret: {"1003005497", "NINIGRET ORTHOPEDICS INC", "207X00000X", "81 BEACH ST", "WESTERLY", "RI", "028912769"},
    delray:
      {"1003007014", "DELRAY FAMILY PRACTICE INC", "208D00000X", "3816 HOLLYWOOD BLVD SUITE 102", "HOLLYWOOD", "FL",
       "33021"},
    horizon:
      {"1003008905", "HORIZON MENTAL HEALTH MANAGEMENT, INC.", "2084P0800X", "18 UPPER MAIN ST", "SHARON", "CT",
       "06069"},
    tlc_pain:
      {"1003019779", "TLC PAIN MANAGEMENT & SLEEP RESTORATION SC", "208VP0014X", "1883 HICKS RD STE A",
       "ROLLING MEADOWS", "IL", "60008"},
    windham:
      {"1003023482", "WINDHAM COMMUNITY MEMORIAL HOSPITAL", "282N00000X", "123 QUARRY ST", "WILLIMANTIC", "CT",
       "062261247"},
    citydoc:
      {"1003044942", "CITYDOC URGENT CARE CENTER 2, PLLC", "261QU0200X", "5301 LOVERS LANE", "DALLAS", "TX", "75209"},
    epp_sc:
      {"1003058876", "EMERGENCY PHYSICIAN PARTNERS OF SOUTH CAROLINA PLLC", "207P00000X", "1700 SKYLYN DR",
       "SPARTANBURG", "SC", "29307"},
    mcep:
      {"1003096553", "MEDICAL CENTER EMERGENCY PHYSICIANS PA", "207P00000X", "17200 ST LUKES WAY", "THE WOODLANDS",
       "TX", "773848007"},
    tirr:
      {"1003003146", "THE INSTITUTE FOR REHABILITATION AND RESEARCH", "283X00000X", "1333 MOURSUND ST", "HOUSTON",
       "TX", "770303405"},
    hurley: {"1003002429", "HURLEY PHO OF MID - MICHIGAN", "208D00000X", "701 W 8TH AVE", "FLINT", "MI", "485031261"},
    awad:
      {"1003625385", "SHAZA AWAD DDS", "261QD0000X", "2184 N BEECH DALY RD STE 4", "DEARBORN HEIGHTS", "MI",
       "481273492"},
    bayer_garner:
      {"1003895764", "BAYER-GARNER, ILENE", "207ND0900X", "285 BERRYWOOD DR", "SEVERNA PARK", "MD", "211462034"},
    kennestone:
      {"1003011776", "KENNESTONE HEART PHYSICIANS GROUP", "207RC0000X", "101 RIVERSTONE VIS SUITE 217", "BLUE RIDGE",
       "GA", "305136648"},
    bluegrass: {"1003037375", "BLUEGRASS CARDIOLOGY PSC", "207RC0000X", "60 MERCY COURT", "IRVINE", "KY", "40336"},
    # Reactivated NPI: deactivated 2008-01-09, reactivated 2009-07-10.
    etheridge:
      {"1003003534", "ETHERIDGE CHIROPRACTIC CLINIC INC", "111N00000X", "631 S 25TH STREET", "TERRE HAUTE", "IN",
       "47803"},
    # Deactivated 2024-12-12. CMS publishes no name or address for it.
    deactivated:
      {"1003002304", "DEACTIVATED NPI - NAME NOT PUBLISHED", "207Q00000X", "100 TEST AVE", "CHICAGO", "IL", "60601"},
    # Dropped from the NPPES file (dropped_on 2026-10-18 in the dev registry).
    # The registry API no longer returns it, so the address is synthetic.
    dropped: {"1093462368", "BLACK, NEDDA", "1041C0700X", "100 TEST AVE", "CHICAGO", "IL", "60601"},
    # Deliberately invalid NPIs.
    bad_format: {"1234567", "UNREGISTERED BILLING ENTITY", "208D00000X", "100 TEST AVE", "CHICAGO", "IL", "60601"},
    # Kevin Lane's NPI with the last digit mistyped: fails the Luhn check.
    bad_checksum: {"1003001578", "KEVIN LANE DO PA", "207Q00000X", "4103 WILBARGER ST", "VERNON", "TX", "763843137"},
    # Passes the Luhn check but was never issued.
    unissued: {"1999999992", "UNREGISTERED BILLING ENTITY", "208D00000X", "100 TEST AVE", "CHICAGO", "IL", "60601"}
  }

  @patients [
    {"MARGARET", "A", "HOLLOWAY", "1958-04-11", "F"},
    {"DONALD", "R", "PRUITT", "1971-09-30", "M"},
    {"ELENA", "M", "VASQUEZ", "1989-02-17", "F"},
    {"JAMAL", "T", "WHITAKER", "2004-06-05", "M"},
    {"RUTH", "E", "OKAFOR", "1946-12-22", "F"},
    {"TYLER", "J", "BRANNIGAN", "1995-03-08", "M"},
    {"SOPHIE", "L", "NGUYEN", "2012-08-14", "F"},
    {"WALTER", "H", "KESSLER", "1939-01-27", "M"}
  ]

  def provider!(key), do: Map.fetch!(@providers, key)

  @doc """
  One claim in the rule engine's field layout.

  opts: :type ("837P", "837I" or "837D"), :pos, :facility, :frequency, :tenure,
  :taxonomy (false = missing), :auth (nil = none), :dx, :lines, :patient
  (index into @patients), :dob (false = missing), :notes.
  Each line is {date, procedure_code, amount} or {date, procedure_code,
  amount, line_opts} with :units, :pos, :revenue, :tooth, :qualifier (default
  HC; AD for dental codes).
  """
  def claim(id, provider_key, opts) do
    {npi, name, taxonomy, street, city, state, zip} = provider!(provider_key)
    type = Keyword.get(opts, :type, "837P")
    taxonomy = if Keyword.get(opts, :taxonomy, true) == false, do: nil, else: taxonomy
    claim_pos = if type == "837I", do: nil, else: Keyword.get(opts, :pos, "11")
    {first, middle, last, dob, gender} = Enum.at(@patients, Keyword.get(opts, :patient, 0))
    dob = if Keyword.get(opts, :dob) == false, do: nil, else: Keyword.get(opts, :dob, dob)
    member_id = "MCD" <> String.pad_leading(Integer.to_string(:erlang.phash2(id, 1_000_000_000)), 9, "0")

    lines =
      opts
      |> Keyword.fetch!(:lines)
      |> Enum.with_index(1)
      |> Enum.map(fn {line, n} -> service_line(line, n, claim_pos) end)

    total = lines |> Enum.map(& &1["charge_amount"]) |> Enum.sum() |> Float.round(2)

    %{
      "claim_id" => id,
      "transaction_type" => type,
      "sample_notes" => Keyword.fetch!(opts, :notes),
      "provider" => %{
        "npi" => npi,
        "name" => name,
        "taxonomy" => taxonomy,
        "tax_id" => tax_id(npi),
        "tenure_days" => Keyword.get(opts, :tenure, 2400)
      },
      "billing_provider" => %{
        "npi" => npi,
        "name" => name,
        "taxonomy" => taxonomy,
        "tax_id" => tax_id(npi),
        "address" => %{"street" => street, "city" => city, "state" => state, "zip" => zip}
      },
      "rendering_provider" => nil,
      "claim_details" => %{
        "place_of_service" => claim_pos,
        "facility_type_code" => if(type == "837I", do: Keyword.get(opts, :facility, "11")),
        "frequency_code" => Keyword.get(opts, :frequency, "1")
      },
      "patient" => %{
        "date_of_birth" => dob,
        "gender" => gender,
        "name" => %{"first" => first, "middle" => middle, "last" => last}
      },
      "subscriber" => %{
        "member_id" => member_id,
        "first_name" => first,
        "middle_name" => middle,
        "last_name" => last,
        "date_of_birth" => dob,
        "gender" => gender,
        "relationship_code" => "18",
        "group_number" => nil,
        "payer_responsibility" => "P",
        "address" => %{"street" => "100 MAIN ST", "city" => city, "state" => state, "zip" => String.slice(zip, 0, 5)}
      },
      "payer" => %{"name" => "STATE MEDICAID PROGRAM", "payer_id" => "STMED01"},
      "financial" => %{"claim_amount" => total},
      "claim_totals" => %{"total_charges" => total},
      "authorization" => %{"authorization_number" => Keyword.get(opts, :auth)},
      "diagnosis_codes" =>
        opts
        |> Keyword.get(:dx, ["Z0000"])
        |> Enum.with_index()
        |> Enum.map(fn {code, i} -> %{"code" => code, "qualifier" => if(i == 0, do: "ABK", else: "ABF")} end),
      "service_lines" => lines
    }
  end

  defp service_line({date, code, amount}, n, pos), do: service_line({date, code, amount, []}, n, pos)

  defp service_line({date, code, amount, o}, n, pos) do
    %{
      "line_number" => n,
      "date_of_service" => Date.to_iso8601(date),
      "place_of_service" => Keyword.get(o, :pos, pos),
      "procedure_code" => code,
      "procedure_qualifier" => Keyword.get(o, :qualifier, if(code, do: "HC")),
      "charge_amount" => amount / 1,
      "units" => Keyword.get(o, :units, 1),
      "unit_type" => if(Keyword.has_key?(o, :revenue), do: "DA", else: "UN"),
      "diagnosis_pointer" => "1",
      "revenue_code" => Keyword.get(o, :revenue),
      "tooth_info" =>
        case Keyword.get(o, :tooth) do
          nil -> nil
          {tooth, surface} -> %{"tooth_code_qualifier" => "JP", "tooth_number" => tooth, "tooth_surface" => surface}
        end
    }
  end

  # Synthetic EIN, stable per NPI.
  defp tax_id(npi), do: "9" <> String.pad_leading(Integer.to_string(:erlang.phash2(npi, 100_000_000)), 8, "0")

  def weekday!(%Date{} = d) do
    if Date.day_of_week(d) in 1..5, do: d, else: raise("#{d} is not a weekday")
  end

  def saturday!(%Date{} = d) do
    if Date.day_of_week(d) == 6, do: d, else: raise("#{d} is not a Saturday")
  end

  # NPI check digit: Luhn over "80840" <> the first nine digits.
  def luhn_valid?(npi) when byte_size(npi) == 10 do
    digits = ("80840" <> npi) |> String.graphemes() |> Enum.map(&String.to_integer/1) |> Enum.reverse()

    sum =
      digits
      |> Enum.with_index()
      |> Enum.map(fn
        {d, i} when rem(i, 2) == 1 -> if d * 2 > 9, do: d * 2 - 9, else: d * 2
        {d, _} -> d
      end)
      |> Enum.sum()

    rem(sum, 10) == 0
  end

  def luhn_valid?(_), do: false

  def pretty_json(term),
    do: term |> JSON.encode!() |> :json.decode() |> :json.format() |> IO.iodata_to_binary()
end


# Service dates: September 2026, weekdays unless a case needs otherwise.
mon = Samples.weekday!(~D[2026-09-14])
tue = Samples.weekday!(~D[2026-09-15])
wed = Samples.weekday!(~D[2026-09-16])
thu = Samples.weekday!(~D[2026-09-17])
fri = Samples.weekday!(~D[2026-09-18])
sat = Samples.saturday!(~D[2026-09-12])
sat2 = Samples.saturday!(~D[2026-09-19])

true = Samples.luhn_valid?("1999999992")
false = Samples.luhn_valid?("1003001578")
true = Samples.luhn_valid?("1003001579")

# {folder, file name, purpose, claim, expect}; expect = {matched rules, nppes}
# where nppes is "ok" or text the rejection must contain.
# Rules match the active business rules seeded by priv/repo/seeds.exs.
samples = [
  # ---------------------------------------------------------------- clean
  {"R_business_rules/R1_clean_claim", "office_visit", "Established-patient office visit; no rule should match",
   Samples.claim("MOCK-CLEAN-001", :lane,
     dx: ["J069"],
     lines: [{tue, "99213", 150}],
     notes: "Clean claim: weekday office visit, $150, taxonomy present. No rule should match."),
   {[], "ok"}},
  {"R_business_rules/R1_clean_claim", "preventive_care", "Annual preventive exam; no rule should match",
   Samples.claim("MOCK-CLEAN-002", :midwest,
     patient: 1,
     dx: ["Z0000", "E785"],
     lines: [{wed, "99396", 220}],
     notes: "Clean claim: adult preventive visit, $220. No rule should match."),
   {[], "ok"}},
  {"R_business_rules/R1_clean_claim", "outpatient_lab", "Three lab tests from a pathology group; no rule should match",
   Samples.claim("MOCK-CLEAN-003", :coastal,
     patient: 2,
     pos: "81",
     dx: ["Z13220", "E119"],
     lines: [{thu, "80053", 125}, {thu, "80061", 110}, {thu, "83036", 90}],
     notes: "Clean claim: independent lab (POS 81), three tests totalling $325. No rule should match."),
   {[], "ok"}},
  {"R_business_rules/R1_clean_claim", "specialist_consultation", "Orthopedic consultation with an X-ray; no rule should match",
   Samples.claim("MOCK-CLEAN-004", :jarman,
     patient: 1,
     dx: ["M5450", "M5116"],
     lines: [{mon, "99244", 350}, {mon, "72100", 95}],
     notes: "Clean claim: office consultation plus lumbar X-ray, $445. No rule should match."),
   {[], "ok"}},
  {"R_business_rules/R7_weekend_inpatient_stay", "inpatient_weekend_stay", "837I inpatient stay over a weekend; WeekendOfficeVisit must not match",
   Samples.claim("MOCK-CLEAN-005", :windham,
     type: "837I",
     facility: "11",
     patient: 4,
     auth: "PA2026091101",
     dx: ["J189", "I10"],
     lines: [
       {sat, nil, 3600, revenue: "0120", units: 3},
       {sat, nil, 640, revenue: "0250"},
       {sat, nil, 560, revenue: "0300"}
     ],
     notes:
       "Institutional (837I) claim, facility type 11 (hospital inpatient), dated on a Saturday, $4,800. " <>
         "WeekendOfficeVisit is limited to claims with no facility type, so nothing should match."),
   {[], "ok"}},

  # ---------------------------------------------------------- single rule
  {"R_business_rules/R2_each_rule_alone", "ExcessiveTotalCharges", "Total charges over $750,000 (below $1M)",
   Samples.claim("MOCK-RULE-EXCESSIVE", :singing_river,
     type: "837I",
     patient: 7,
     auth: "PA2026090301",
     dx: ["I214", "I509"],
     lines: [
       {mon, nil, 168_000, revenue: "0200", units: 14},
       {mon, nil, 412_000, revenue: "0360"},
       {mon, nil, 220_000, revenue: "0278"}
     ],
     notes: "Inpatient cardiac stay totalling $800,000: ExcessiveTotalCharges, and HighValueClaim (over $50,000)."),
   {["ExcessiveTotalCharges", "HighValueClaim"], "ok"}},
  {"R_business_rules/R2_each_rule_alone", "ExtremeAmounts", "Total charges over $1,000,000",
   Samples.claim("MOCK-RULE-EXTREME", :tirr,
     type: "837I",
     patient: 1,
     auth: "PA2026082801",
     dx: ["S14105A", "G8220"],
     lines: [{mon, nil, 1_050_000, revenue: "0118", units: 42}, {mon, nil, 200_000, revenue: "0420", units: 120}],
     notes:
       "Rehabilitation hospital stay totalling $1,250,000: ExtremeAmounts, ExcessiveTotalCharges and HighValueClaim."),
   {["ExtremeAmounts", "ExcessiveTotalCharges", "HighValueClaim"], "ok"}},
  {"R_business_rules/R2_each_rule_alone", "FutureServiceDate", "Second service line dated 2099",
   Samples.claim("MOCK-RULE-FUTURE", :delray,
     patient: 2,
     dx: ["J069"],
     lines: [{tue, "99213", 150}, {~D[2099-01-14], "87880", 45}],
     notes: "Line 1 is dated 2026-09-15, line 2 is dated 2099-01-14: FutureServiceDate checks every line."),
   {["FutureServiceDate"], "ok"}},
  {"R_business_rules/R2_each_rule_alone", "HighComplexityERVisit", "99285 on the second line, claim over $10,000",
   Samples.claim("MOCK-RULE-ER99285", :epp_sc,
     pos: "23",
     patient: 5,
     auth: "PA2026091502",
     dx: ["R079", "I209"],
     lines: [{tue, "99291", 9_800}, {tue, "99285", 2_700}],
     notes:
       "Emergency department claim, $12,500, with 99285 on line 2 (HighComplexityERVisit checks every line). " <>
         "Authorization present, so UnauthorizedProcedure does not match."),
   {["HighComplexityERVisit"], "ok"}},
  {"R_business_rules/R2_each_rule_alone", "HighValueClaim", "Claim over $50,000 with authorization",
   Samples.claim("MOCK-RULE-HIGHVALUE", :ross,
     pos: "21",
     patient: 0,
     auth: "PA2026090801",
     dx: ["M1711", "Z96641"],
     lines: [{mon, "27447", 58_000}, {wed, "99232", 7_000}],
     notes: "Knee replacement billed at $65,000 with an authorization: HighValueClaim only."),
   {["HighValueClaim"], "ok"}},
  {"R_business_rules/R2_each_rule_alone", "ImpossibleDates", "Second service line dated 1899",
   Samples.claim("MOCK-RULE-PRE1900", :hurley,
     patient: 3,
     dx: ["J029"],
     lines: [{wed, "99213", 150}, {~D[1899-12-29], "87880", 30}],
     notes:
       "Line 2 is dated 1899-12-29: ImpossibleDates. The NPPES check also rejects it, since the NPI was not " <>
         "issued until 2007."),
   {["ImpossibleDates"], "was not issued until"}},
  {"R_business_rules/R2_each_rule_alone", "InvalidNPIFormat", "Seven-digit billing NPI",
   Samples.claim("MOCK-RULE-NPIFORMAT", :bad_format,
     patient: 2,
     dx: ["R059"],
     lines: [{tue, "99213", 200}],
     notes:
       "NPI 1234567 is not 10 digits: InvalidNPIFormat and InvalidProviderNPI. NPPES rejects it. " <>
         "The provider name and address are made up."),
   {["InvalidNPIFormat", "InvalidProviderNPI"], "not found in NPPES"}},
  {"R_business_rules/R2_each_rule_alone", "InvalidProviderNPI", "Real NPI with the last digit mistyped",
   Samples.claim("MOCK-RULE-NPILUHN", :bad_checksum,
     patient: 3,
     dx: ["J069"],
     lines: [{thu, "99213", 150}],
     notes:
       "Kevin Lane DO PA's NPI 1003001579 keyed as 1003001578, which fails the Luhn check digit: " <>
         "InvalidProviderNPI. NPPES rejects it."),
   {["InvalidProviderNPI"], "not found in NPPES"}},
  {"R_business_rules/R2_each_rule_alone", "MissingDiagnosisCodes", "Urgent care claim with no diagnosis codes",
   Samples.claim("MOCK-RULE-NODX", :citydoc,
     patient: 5,
     dx: [],
     lines: [{fri, "99214", 230}, {fri, "87804", 70}],
     notes: "Empty diagnosis_codes list: MissingDiagnosisCodes."),
   {["MissingDiagnosisCodes"], "ok"}},
  {"R_business_rules/R2_each_rule_alone", "MissingProviderTaxonomy", "No taxonomy, claim over $1,000",
   Samples.claim("MOCK-RULE-NOTAXONOMY", :horizon,
     taxonomy: false,
     patient: 2,
     dx: ["F321"],
     lines: [{mon, "90837", 400}, {tue, "90837", 400}, {wed, "90837", 400}, {thu, "90837", 400}],
     notes: "Four psychotherapy sessions, $1,600, sent without a taxonomy code: MissingProviderTaxonomy."),
   {["MissingProviderTaxonomy"], "ok"}},
  {"R_business_rules/R2_each_rule_alone", "MissingRequiredFields", "Patient date of birth missing",
   Samples.claim("MOCK-RULE-NODOB", :bayer_garner,
     dob: false,
     patient: 4,
     dx: ["L578"],
     lines: [{wed, "88305", 240}],
     notes:
       "patient.date_of_birth is missing: MissingRequiredFields. PatientAgeOutOfRange checks only a date " <>
         "of birth that is present, so it does not match."),
   {["MissingRequiredFields"], "ok"}},
  {"R_business_rules/R2_each_rule_alone", "NewProviderLargeSubmission", "Provider credentialed 45 days ago, claim over $10,000",
   Samples.claim("MOCK-RULE-NEWPROV", :awad,
     tenure: 45,
     patient: 6,
     auth: "PA2026090402",
     dx: ["K0262"],
     lines: [
       {mon, "D2740", 1_450, tooth: {"3", nil}},
       {mon, "D2740", 1_450, tooth: {"14", nil}},
       {tue, "D3330", 1_300, tooth: {"19", nil}},
       {tue, "D6010", 4_900, tooth: {"30", nil}},
       {wed, "D6058", 2_900, tooth: {"30", nil}},
       {wed, "D4341", 2_000}
     ],
     notes:
       "Dental practice enumerated 2025-01-02, credentialed with Medicaid 45 days ago, billing $14,000: " <>
         "NewProviderLargeSubmission. tenure_days comes only from JSON claims; X12 conversion leaves it empty."),
   {["NewProviderLargeSubmission"], "ok"}},
  {"R_business_rules/R2_each_rule_alone", "PatientAgeOutOfRange", "Date of birth in 1890",
   Samples.claim("MOCK-RULE-AGE", :midwest,
     dob: "1890-03-02",
     patient: 7,
     dx: ["I10"],
     lines: [{fri, "99214", 180}],
     notes: "Date of birth 1890-03-02 makes the patient over 130: PatientAgeOutOfRange."),
   {["PatientAgeOutOfRange"], "ok"}},
  {"R_business_rules/R2_each_rule_alone", "SuspiciouslyLowCharge", "Claim total of $2.00",
   Samples.claim("MOCK-RULE-LOWCHARGE", :lane,
     patient: 1,
     dx: ["Z0000"],
     lines: [{mon, "99211", 2}],
     notes: "A $2.00 nurse visit: SuspiciouslyLowCharge."),
   {["SuspiciouslyLowCharge"], "ok"}},
  {"R_business_rules/R2_each_rule_alone", "TaxonomyMismatchNewProvider", "New provider, no taxonomy, claim over $5,000",
   Samples.claim("MOCK-RULE-NEWNOTAX", :tlc_pain,
     taxonomy: false,
     tenure: 30,
     patient: 1,
     auth: "PA2026091001",
     dx: ["M5416"],
     lines: [{tue, "64483", 3_000}, {tue, "64484", 1_500}, {thu, "62323", 3_000}],
     notes:
       "Provider credentialed 30 days ago, no taxonomy, $7,500 of injections: TaxonomyMismatchNewProvider, " <>
         "and MissingProviderTaxonomy (no taxonomy, over $1,000)."),
   {["TaxonomyMismatchNewProvider", "MissingProviderTaxonomy"], "ok"}},
  {"R_business_rules/R2_each_rule_alone", "UnauthorizedProcedure", "Claim over $5,000 with no authorization",
   Samples.claim("MOCK-RULE-NOAUTH", :ninigret,
     pos: "24",
     patient: 5,
     dx: ["M2361"],
     lines: [{wed, "29881", 6_200}, {wed, "29876", 1_800}],
     notes: "Knee arthroscopy at an ambulatory surgical center (POS 24), $8,000, no authorization."),
   {["UnauthorizedProcedure"], "ok"}},
  {"R_business_rules/R2_each_rule_alone", "WeekendOfficeVisit", "Saturday office visit over $500",
   Samples.claim("MOCK-RULE-WEEKEND", :miami,
     patient: 3,
     dx: ["J449", "I10"],
     lines: [{sat, "99215", 340}, {sat, "94010", 180}, {sat, "71046", 130}],
     notes: "Office visit (POS 11) on Saturday 2026-09-12, $650: WeekendOfficeVisit."),
   {["WeekendOfficeVisit"], "ok"}},

  # ----------------------------------------------------------- multi rule
  {"R_business_rules/R3_several_rules", "new_provider_no_auth", "New dental provider, no taxonomy, no authorization, $35,000",
   Samples.claim("MOCK-MULTI-NEWPROV", :awad,
     taxonomy: false,
     tenure: 20,
     patient: 0,
     dx: ["K0889"],
     lines: [
       {mon, "D6010", 4_900, tooth: {"3", nil}},
       {mon, "D6010", 4_900, tooth: {"14", nil}},
       {mon, "D6010", 4_900, tooth: {"19", nil}},
       {mon, "D6010", 4_900, tooth: {"30", nil}},
       {thu, "D7210", 3_400, tooth: {"1", nil}},
       {thu, "D6114", 12_000}
     ],
     notes:
       "Four rules at once: TaxonomyMismatchNewProvider, MissingProviderTaxonomy, NewProviderLargeSubmission " <>
         "and UnauthorizedProcedure."),
   {["TaxonomyMismatchNewProvider", "MissingProviderTaxonomy", "NewProviderLargeSubmission", "UnauthorizedProcedure"],
    "ok"}},
  {"R_business_rules/R3_several_rules", "er_visit_no_auth", "99285 over $10,000 with no authorization",
   Samples.claim("MOCK-MULTI-ERNOAUTH", :mcep,
     pos: "23",
     patient: 3,
     dx: ["S060X0A", "S0990XA"],
     lines: [{fri, "99285", 2_900}, {fri, "99291", 8_100}, {fri, "70450", 3_500}],
     notes: "Emergency department claim, $14,500, no authorization: HighComplexityERVisit and UnauthorizedProcedure."),
   {["HighComplexityERVisit", "UnauthorizedProcedure"], "ok"}},
  {"R_business_rules/R3_several_rules", "extreme_new_provider", "Over $1M, new provider, no authorization",
   Samples.claim("MOCK-MULTI-EXTREME", :windham,
     type: "837I",
     tenure: 60,
     patient: 7,
     dx: ["A419", "J9601"],
     lines: [{mon, nil, 640_000, revenue: "0200", units: 32}, {mon, nil, 460_000, revenue: "0250"}],
     notes:
       "$1,100,000 inpatient claim, provider credentialed 60 days ago, no authorization: ExtremeAmounts, " <>
         "ExcessiveTotalCharges, HighValueClaim, UnauthorizedProcedure and NewProviderLargeSubmission."),
   {["ExtremeAmounts", "ExcessiveTotalCharges", "HighValueClaim", "UnauthorizedProcedure",
     "NewProviderLargeSubmission"], "ok"}},
  {"R_business_rules/R3_several_rules", "weekend_no_taxonomy", "Saturday office visit sent without a taxonomy",
   Samples.claim("MOCK-MULTI-WEEKENDTAX", :jarman,
     taxonomy: false,
     patient: 5,
     dx: ["S83511A"],
     lines: [{sat2, "99204", 420}, {sat2, "73721", 780}],
     notes: "Saturday 2026-09-19 office visit, $1,200, no taxonomy: WeekendOfficeVisit and MissingProviderTaxonomy."),
   {["WeekendOfficeVisit", "MissingProviderTaxonomy"], "ok"}},

  # ---------------------------------------------------------------- nppes
  {"N_nppes_provider_checks/N4_deactivated_provider", "deactivated_provider", "NPI deactivated 2024-12-12, service in 2026",
   Samples.claim("MOCK-NPPES-DEACT", :deactivated,
     patient: 1,
     dx: ["J069"],
     lines: [{tue, "99213", 150}],
     notes:
       "NPI 1003002304 was deactivated on 2024-12-12, so NPPES rejects a 2026 service. CMS publishes no " <>
         "name or address for a deactivated NPI; both are placeholders. No business rule matches."),
   {[], "was deactivated"}},
  {"N_nppes_provider_checks/N8_service_before_npi_issued", "before_enumeration", "Service dated before the NPI was issued",
   Samples.claim("MOCK-NPPES-PREENUM", :coastal,
     patient: 2,
     dx: ["Z13220"],
     lines: [{~D[2017-11-08], "80061", 110}],
     notes: "Coastal Plains Pathology's NPI was issued 2018-06-01; this service is dated 2017-11-08."),
   {[], "was not issued until"}},
  {"N_nppes_provider_checks/N7_reactivated_provider", "reactivation_gap", "Service while the NPI was deactivated (before its reactivation)",
   Samples.claim("MOCK-NPPES-GAP", :etheridge,
     patient: 4,
     dx: ["M5450"],
     lines: [{~D[2008-06-02], "98941", 65}],
     notes: "NPI 1003003534 was deactivated 2008-01-09 and reactivated 2009-07-10; service dated 2008-06-02."),
   {[], "was deactivated"}},
  {"N_nppes_provider_checks/N7_reactivated_provider", "reactivated_provider", "Same reactivated NPI, service in 2026: accepted",
   Samples.claim("MOCK-NPPES-REACT", :etheridge,
     patient: 4,
     dx: ["M5450"],
     lines: [{tue, "98941", 65}],
     notes: "NPI 1003003534 was reactivated 2009-07-10, so a 2026 service is accepted."),
   {[], "ok"}},
  {"N_nppes_provider_checks/N9_dropped_from_nppes", "dropped_provider", "NPI no longer in the NPPES file",
   Samples.claim("MOCK-NPPES-DROPPED", :dropped,
     patient: 2,
     dx: ["F411"],
     lines: [{~D[2026-10-18], "90834", 160}],
     notes:
       "NPI 1093462368 was missing from the October 2026 full NPPES file (dropped_on 2026-10-18 in the dev " <>
         "registry); service on 2026-10-18. Address is a placeholder. Needs a registry imported with that file."),
   {[], "has not been in the NPPES file since"}},
  {"N_nppes_provider_checks/N3_npi_never_issued", "unissued_npi", "Luhn-valid NPI that was never issued",
   Samples.claim("MOCK-NPPES-UNISSUED", :unissued,
     patient: 3,
     dx: ["J069"],
     lines: [{wed, "99213", 150}],
     notes: "1999999992 passes the check digit, so no rule matches, but no such NPI exists. Name and address are made up."),
   {[], "not found in NPPES"}},

  # ------------------------------------------------- 837I and 837D layouts
  {"J_json_files/J8_837i_or_837d_style_json", "dental_837d", "837D-style JSON claim (procedure qualifier AD, tooth number); clean",
   Samples.claim("MOCK-DENTAL-001", :awad,
     patient: 3,
     dx: ["K0251"],
     lines: [{tue, "D0120", 65, qualifier: "AD"}, {tue, "D2391", 180, qualifier: "AD", tooth: {"19", "O"}}],
     type: "837D",
     notes: "Dental claim as the converter writes an 837D: periodic exam and a one-surface filling on tooth 19, $245. No rule should match."),
   {[], "ok"}},
  {"J_json_files/J8_837i_or_837d_style_json", "institutional_837i", "837I-style JSON claim (facility type, revenue codes, no procedure codes); clean",
   Samples.claim("MOCK-INST-001", :windham,
     type: "837I",
     facility: "13",
     patient: 1,
     dx: ["R1010"],
     lines: [{wed, nil, 420, revenue: "0450"}, {wed, nil, 180, revenue: "0300"}],
     notes: "Hospital outpatient (facility type 13) claim with revenue-code lines only, on a weekday, $600. No rule should match."),
   {[], "ok"}},

  # ---------------------------------------- replacement and void claims
  {"R_business_rules/R11_replacement_or_void_claim", "replacement_frequency_7",
   "Replacement (frequency code 7) of a claim over $50,000: the rules apply as to an original",
   Samples.claim("MOCK-FREQ-REPLACE", :ross,
     pos: "21",
     frequency: "7",
     auth: "PA2026090802",
     dx: ["M1711", "Z96641"],
     lines: [{mon, "27447", 58_000}, {wed, "99232", 7_000}],
     notes: "Like MOCK-RULE-HIGHVALUE but a replacement claim (CLM05-3 = 7). No rule looks at the frequency code, so HighValueClaim matches."),
   {["HighValueClaim"], "ok"}},
  {"R_business_rules/R11_replacement_or_void_claim", "void_frequency_8",
   "Void (frequency code 8) of a claim over $50,000: the rules apply as to an original",
   Samples.claim("MOCK-FREQ-VOID", :ross,
     pos: "21",
     frequency: "8",
     auth: "PA2026090803",
     dx: ["M1711", "Z96641"],
     lines: [{mon, "27447", 58_000}, {wed, "99232", 7_000}],
     notes: "Like MOCK-RULE-HIGHVALUE but a void (CLM05-3 = 8). No rule looks at the frequency code, so HighValueClaim matches."),
   {["HighValueClaim"], "ok"}}
]

# Redundancy samples: evaluated against P2's redundancy_levels.dsl, not
# the database rules. Each shows which overlapping rules fire together.
r = &Samples.claim/3

redundancy = [
  {"exact_duplicate", "Group A Level 1: two identical > $50,000 rules both fire",
   r.("REDUN-EXACT-DUP-001", :ross,
     pos: "22",
     tenure: 400,
     dx: ["M1711"],
     auth: "PA2026090901",
     lines: [{tue, "27447", 65_000}],
     notes: "$65,000: high_amount_50k and its exact duplicate, plus the group G amount rules."),
   ~w(high_amount_50k high_amount_50k_dup high_or_er high_or_er_dup high_amount_only moderate_amount_flag)},
  {"subsumption_extreme_amount", "Group A Levels 2-3: > $100,000 is subsumed by > $50,000; > $75,000 REJECT shadows",
   r.("REDUN-SUBSUME-001", :singing_river,
     pos: "21",
     tenure: 600,
     dx: ["I214"],
     auth: "PA2026091101",
     lines: [{mon, "33533", 150_000}],
     notes: "$150,000 at POS 21: every group A amount rule except the $40k-$60k range, group G, and inpatient_high_amount."),
   ~w(high_amount_50k high_amount_50k_dup extreme_amount_100k high_amount_reject high_or_er high_or_er_dup
      high_amount_only moderate_amount_flag inpatient_high_amount)},
  {"overlap_mid_range", "Group A Level 4: $55,000 is inside both > $50,000 and $40,000-$60,000",
   r.("REDUN-OVERLAP-001", :jarman,
     pos: "22",
     tenure: 300,
     dx: ["M1711"],
     auth: "PA2026091601",
     lines: [{wed, "27447", 55_000}],
     notes: "$55,000 sits where the > $50,000 rules and the $40,000-$60,000 range overlap."),
   ~w(high_amount_50k high_amount_50k_dup mid_range_review high_or_er high_or_er_dup high_amount_only
      moderate_amount_flag)},
  {"new_provider_subsumption", "Group B Levels 2-4: tenure 20 days fires every tenure rule",
   r.("REDUN-PROV-SUB-001", :lane,
     tenure: 20,
     dx: ["J069"],
     lines: [{thu, "99214", 2_500}],
     notes: "Tenure 20 days: < 90, < 30, < 60 and the 0-120 probation window all match."),
   ~w(new_provider_90 very_new_provider_30 new_provider_reject provider_probation)},
  {"shadowed_er_visit", "Group C Levels 1 and 3: ER place of service, same condition, FLAG vs REJECT",
   r.("REDUN-SHADOW-001", :mcep,
     pos: "23",
     tenure: 500,
     dx: ["S060X0A"],
     auth: "PA2026091801",
     lines: [{fri, "99285", 8_500}],
     notes: "POS 23 at $8,500: the three ER rules and the ER arm of the group G OR rules."),
   ~w(er_visit_flag er_visit_flag_copy er_visit_reject high_or_er high_or_er_dup)},
  {"compound_all_levels", "Groups A-D together: $80,000 ER claim from a 45-day provider",
   r.("REDUN-COMPOUND-001", :ninigret,
     pos: "23",
     tenure: 45,
     dx: ["S72001A"],
     auth: "PA2026091401",
     lines: [{mon, "27236", 80_000}],
     notes: "Matches rules in groups A, B, C, D and G at once."),
   ~w(high_amount_50k high_amount_50k_dup high_amount_reject new_provider_90 new_provider_reject provider_probation
      er_visit_flag er_visit_flag_copy er_visit_reject high_amount_new_provider moderate_amount_newer_provider
      high_or_er high_or_er_dup high_amount_only moderate_amount_flag)},
  {"control_no_triggers", "Negative control: no redundancy rule should match",
   r.("REDUN-CONTROL-001", :midwest,
     tenure: 800,
     dx: ["J069"],
     lines: [{tue, "99213", 350}],
     notes: "$350 office visit, established provider: nothing matches."),
   []},
  {"string_diagnosis_dup", "Group E Levels 1 and 3: principal diagnosis E11.9",
   r.("REDUN-STRING-001", :midwest,
     tenure: 500,
     dx: ["E119", "E785"],
     lines: [{wed, "99214", 1_200}],
     notes: "Principal diagnosis E11.9: the three diabetes rules; hypertension_review does not match."),
   ~w(diabetes_flag diabetes_flag_dup diabetes_reject)},
  {"between_overlap", "Group F Levels 1 and 4: 12 room-and-board days",
   r.("REDUN-BETWEEN-001", :windham,
     type: "837I",
     tenure: 700,
     dx: ["J189"],
     auth: "PA2026090102",
     lines: [{mon, nil, 16_800, revenue: "0120", units: 12}, {mon, nil, 1_800, revenue: "0250"}],
     notes: "12 days (revenue code 0120 units) falls in 7-14 and 10-21, not 1-5."),
   ~w(stay_7_14 stay_7_14_dup stay_10_21)},
  {"between_disjoint", "Group F control: 3 room-and-board days",
   r.("REDUN-BETWEEN-002", :windham,
     type: "837I",
     tenure: 900,
     dx: ["K3580"],
     auth: "PA2026091502",
     lines: [{tue, nil, 4_200, revenue: "0120", units: 3}, {tue, nil, 1_200, revenue: "0360"}],
     notes: "3 days falls only in the 1-5 range."),
   ~w(stay_1_5)},
  {"or_condition", "Group G: the amount arm of the OR",
   r.("REDUN-OR-001", :jarman,
     tenure: 400,
     dx: ["M5450"],
     auth: "PA2026090803",
     lines: [{tue, "22612", 75_000}],
     notes: "$75,000 at POS 11: the OR rules via the amount arm. Not over $75,000, so high_amount_reject does not match."),
   ~w(high_amount_50k high_amount_50k_dup high_or_er high_or_er_dup high_amount_only moderate_amount_flag)},
  {"or_er_arm", "Group G: the ER arm of the OR",
   r.("REDUN-OR-002", :mcep,
     pos: "23",
     tenure: 600,
     dx: ["S060X0A"],
     lines: [{sat, "99285", 500}],
     notes: "$500 at POS 23: the OR rules via the ER arm, and the group C ER rules."),
   ~w(high_or_er high_or_er_dup er_visit_flag er_visit_flag_copy er_visit_reject)},
  {"negation", "Group H Levels 1 and 3: a replacement claim (frequency 7)",
   r.("REDUN-NOT-001", :midwest,
     frequency: "7",
     tenure: 450,
     dx: ["J189"],
     lines: [{mon, "99223", 2_000}],
     notes: "Frequency code 7 (replacement), so NOT frequency_code = \"1\" holds: the three group H rules."),
   ~w(not_original_flag not_original_flag_dup not_original_reject)},
  {"negation_control", "Group H control: an original claim (frequency 1)",
   r.("REDUN-NOT-002", :midwest,
     tenure: 1200,
     dx: ["J069"],
     lines: [{tue, "99213", 800}],
     notes: "Original claim: the NOT condition is false, so no group H rule matches."),
   []},
  {"multi_field_partial", "Group I: cardiology inpatient claim over $50,000",
   r.("REDUN-PARTIAL-001", :kennestone,
     pos: "21",
     tenure: 350,
     dx: ["I214"],
     auth: "PA2026091701",
     lines: [{thu, "92928", 70_000}],
     notes: "Cardiology taxonomy, POS 21, $70,000: all three group I rules, plus groups A and G."),
   ~w(cardio_high_amount inpatient_high_amount cardio_moderate high_amount_50k high_amount_50k_dup high_or_er
      high_or_er_dup high_amount_only moderate_amount_flag)},
  {"multi_field_no_overlap", "Group I control: same amount and POS, orthopedic taxonomy",
   r.("REDUN-PARTIAL-002", :jarman,
     pos: "21",
     tenure: 350,
     dx: ["M1711"],
     auth: "PA2026091702",
     lines: [{thu, "27236", 70_000}],
     notes: "Orthopedic taxonomy: inpatient_high_amount matches, the two cardiology rules do not."),
   ~w(inpatient_high_amount high_amount_50k high_amount_50k_dup high_or_er high_or_er_dup high_amount_only
      moderate_amount_flag)},
  {"cardiology_moderate", "Group I: cardiology at $30,000 matches only the moderate rule",
   r.("REDUN-PARTIAL-003", :bluegrass,
     pos: "22",
     tenure: 900,
     dx: ["I2510"],
     auth: "PA2026091102",
     lines: [{fri, "93458", 30_000}],
     notes: "$30,000 cardiology: cardio_moderate (> $20,000) only; not over $30,000, so no group G rule."),
   ~w(cardio_moderate)}
]

# Batches: several claims in one upload ({"claims": [...]}).
batch = fn prefix, items ->
  for {id, prov, opts} <- items, do: Samples.claim(prefix <> id, prov, opts)
end

batches = [
  {"mixed_batch", "Six claims in one file: two clean, four that each match different rules",
   batch.("MOCK-BATCH-", [
     {"001", :lane, dx: ["J069"], lines: [{wed, "99213", 150}], notes: "Clean."},
     {"002", :coastal, patient: 2, pos: "81", dx: ["E119"], lines: [{wed, "83036", 90}], notes: "Clean."},
     {"003", :miami, patient: 3, dx: ["J449"], lines: [{sat2, "99215", 340}, {sat2, "94010", 180}],
      notes: "WeekendOfficeVisit."},
     {"004", :ninigret, pos: "24", patient: 5, dx: ["M2361"], lines: [{thu, "29881", 6_200}],
      notes: "UnauthorizedProcedure."},
     {"005", :epp_sc, pos: "23", patient: 7, auth: "PA2026091903", dx: ["R079"],
      lines: [{fri, "99285", 2_700}, {fri, "99291", 9_800}], notes: "HighComplexityERVisit."},
     {"006", :citydoc, patient: 6, dx: [], lines: [{mon, "99213", 140}], notes: "MissingDiagnosisCodes."}
   ]),
   [
     {"MOCK-BATCH-001", [], "ok"},
     {"MOCK-BATCH-002", [], "ok"},
     {"MOCK-BATCH-003", ["WeekendOfficeVisit"], "ok"},
     {"MOCK-BATCH-004", ["UnauthorizedProcedure"], "ok"},
     {"MOCK-BATCH-005", ["HighComplexityERVisit"], "ok"},
     {"MOCK-BATCH-006", ["MissingDiagnosisCodes"], "ok"}
   ]},
  {"clean_batch", "Four clean claims from four providers; nothing should match",
   batch.("MOCK-CLEANBATCH-", [
     {"001", :midwest, patient: 1, dx: ["Z0000"], lines: [{mon, "99396", 220}], notes: "Clean."},
     {"002", :jarman, patient: 5, dx: ["M2551"], lines: [{tue, "99213", 160}, {tue, "73030", 85}], notes: "Clean."},
     {"003", :horizon, patient: 2, dx: ["F411"], lines: [{wed, "90834", 160}], notes: "Clean."},
     {"004", :etheridge, patient: 4, dx: ["M5450"], lines: [{thu, "98941", 65}], notes: "Clean."}
   ]),
   Enum.map(1..4, &{"MOCK-CLEANBATCH-00#{&1}", [], "ok"})}
]

# ------------------------------------------------------------------ output

# Returned to ../generate.exs, which writes the files and the manifest.
json = fn term -> Samples.pretty_json(term) <> "\n" end
expect = fn id, matched, nppes -> %{"claim_id" => id, "matched" => Enum.sort(matched), "nppes" => nppes} end
p2 = "P_rules_page/P2_redundancy_levels"

Enum.map(samples, fn {dir, name, purpose, c, {matched, nppes}} ->
  %{
    "file" => "#{dir}/#{name}.json",
    "purpose" => purpose,
    "content" => json.(c),
    "expect" => %{"claims" => [expect.(c["claim_id"], matched, nppes)]}
  }
end) ++
  Enum.map(redundancy, fn {name, purpose, c, matched} ->
    %{
      "file" => "#{p2}/claims/#{name}.json",
      "purpose" => purpose,
      "content" => json.(c),
      "rules" => "#{p2}/redundancy_levels.dsl",
      "expect" => %{"claims" => [expect.(c["claim_id"], matched, "ok")]}
    }
  end) ++
  Enum.map(batches, fn {name, purpose, claims, expected} ->
    %{
      "file" => "J_json_files/J3_claims_wrapper/#{name}.json",
      "purpose" => purpose,
      "content" => json.(%{"claims" => claims}),
      "expect" => %{"claims" => Enum.map(expected, fn {id, m, n} -> expect.(id, m, n) end)}
    }
  end) ++
  [
    %{
      "file" => "J_json_files/J2_list_of_claims/two_claims.json",
      "purpose" => "A plain list [...] of two claims, without the {\"claims\": ...} wrapper",
      "content" =>
        json.(
          batch.("MOCK-LIST-", [
            {"001", :lane, dx: ["J069"], lines: [{tue, "99213", 150}], notes: "Clean."},
            {"002", :citydoc, patient: 6, dx: [], lines: [{mon, "99213", 140}], notes: "MissingDiagnosisCodes."}
          ])
        ),
      "expect" => %{
        "claims" => [expect.("MOCK-LIST-001", [], "ok"), expect.("MOCK-LIST-002", ["MissingDiagnosisCodes"], "ok")]
      }
    },
    %{
      "file" => "J_json_files/J5_not_a_claim/patient_record.json",
      "purpose" => "Valid JSON that is not a claim (a patient record, no claim_id) → refused, nothing evaluated",
      "content" =>
        json.(%{
          "patient" => %{"name" => %{"first" => "ELENA", "last" => "VASQUEZ"}, "date_of_birth" => "1989-02-17"},
          "note" => "Not a claim: there is no claim_id or claim field."
        }),
      "expect" => %{"error" => "no claim found"}
    },
    %{
      "file" => "J_json_files/J7_invalid_json/cut_off.json",
      "purpose" => "A claim file cut off part-way, so not valid JSON → refused, nothing evaluated",
      "content" => String.slice(json.(Samples.claim("MOCK-BROKEN-001", :lane, lines: [{tue, "99213", 150}], notes: "Cut off.")), 0, 300),
      "expect" => %{"error" => "not valid JSON"}
    }
  ]
