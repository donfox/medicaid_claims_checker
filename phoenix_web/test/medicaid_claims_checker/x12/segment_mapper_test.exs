defmodule MedicaidClaimsChecker.X12.SegmentMapperTest do
  use ExUnit.Case, async: true

  alias MedicaidClaimsChecker.X12.SegmentMapper

  # Load X12Translator output fixtures at compile time.
  # These are the real files produced by X12Translator from 837P EDI input.
  @lab_work Jason.decode!(File.read!("test/fixtures/x12/valid_837p_lab_work.json"))
  @preventive Jason.decode!(File.read!("test/fixtures/x12/valid_837p_preventive.json"))

  # ---------------------------------------------------------------------------
  # Idempotency and edge cases
  # ---------------------------------------------------------------------------

  describe "normalize/1 — idempotency and edge cases" do
    test "already-normalized claim (has top-level claim_id string key) passes through unchanged" do
      normalized = SegmentMapper.normalize(@lab_work)
      assert SegmentMapper.normalize(normalized) == normalized
    end

    test "already-normalized claim (atom claim_id key) passes through unchanged" do
      claim = %{claim_id: "CLM-ATOM-KEY", financial: %{claim_amount: 100.0}}
      assert SegmentMapper.normalize(claim) == claim
    end

    test "non-map values pass through unchanged" do
      assert SegmentMapper.normalize("string") == "string"
      assert SegmentMapper.normalize(nil) == nil
      assert SegmentMapper.normalize([1, 2, 3]) == [1, 2, 3]
    end

    test "business-schema fixture (already has claim_id) passes through unchanged" do
      biz_claim = %{
        "claim_id" => "CLM-EXISTING",
        "provider" => %{"npi" => "1234567890"},
        "financial" => %{"claim_amount" => 500.0}
      }

      assert SegmentMapper.normalize(biz_claim) == biz_claim
    end
  end

  # ---------------------------------------------------------------------------
  # Lab work claim — CLM100002
  # 837P professional: lab panels, 4 service lines, $450 total
  # ---------------------------------------------------------------------------

  describe "normalize/1 — lab_work 837P (CLM100002)" do
    setup do
      {:ok, claim: SegmentMapper.normalize(@lab_work)}
    end

    # --- Core identity fields ---

    test "maps claim_id from claim.claim_id", %{claim: claim} do
      assert claim["claim_id"] == "CLM100002"
    end

    test "maps transaction_type", %{claim: claim} do
      assert claim["transaction_type"] == "837P"
    end

    # --- Provider fields ---

    test "maps provider.npi from billing_provider.npi", %{claim: claim} do
      assert claim["provider"]["npi"] == "1003001850"
    end

    test "maps provider.taxonomy from billing_provider.taxonomy_code", %{claim: claim} do
      assert claim["provider"]["taxonomy"] == "291U00000X"
    end

    test "maps provider.tax_id from billing_provider.tax_id", %{claim: claim} do
      assert claim["provider"]["tax_id"] == "271839456"
    end

    test "sets provider.tenure_days to nil (not in X12)", %{claim: claim} do
      assert is_nil(claim["provider"]["tenure_days"])
    end

    # --- Patient fields ---

    test "maps patient.date_of_birth from claim.subscriber.date_of_birth", %{claim: claim} do
      assert claim["patient"]["date_of_birth"] == "19551108"
    end

    test "maps patient.gender from subscriber", %{claim: claim} do
      assert claim["patient"]["gender"] == "M"
    end

    test "maps patient name components from subscriber", %{claim: claim} do
      assert claim["patient"]["name"]["first"] == "TERRENCE"
      assert claim["patient"]["name"]["last"] == "WILLIAMS"
    end

    # --- Financial fields ---

    test "maps financial.claim_amount from total_charge_amount as float", %{claim: claim} do
      assert claim["financial"]["claim_amount"] == 450.0
    end

    test "maps claim_totals.total_charges from total_charge_amount as float", %{claim: claim} do
      assert claim["claim_totals"]["total_charges"] == 450.0
    end

    # --- Diagnosis codes ---

    test "maps diagnosis_codes array from claim.diagnosis_codes", %{claim: claim} do
      codes = claim["diagnosis_codes"]
      assert is_list(codes)
      assert length(codes) == 2
    end

    test "diagnosis code entries have code and qualifier keys", %{claim: claim} do
      Enum.each(claim["diagnosis_codes"], fn code ->
        assert Map.has_key?(code, "code")
        assert Map.has_key?(code, "qualifier")
      end)
    end

    test "correct diagnosis codes are present", %{claim: claim} do
      codes = Enum.map(claim["diagnosis_codes"], & &1["code"])
      assert "E119" in codes
      assert "I10" in codes
    end

    # --- Service lines ---

    test "maps 4 service lines", %{claim: claim} do
      assert length(claim["service_lines"]) == 4
    end

    test "service_line.date_of_service is mapped from service_date", %{claim: claim} do
      Enum.each(claim["service_lines"], fn line ->
        assert line["date_of_service"] == "20260307"
        refute Map.has_key?(line, "service_date")
      end)
    end

    test "service_line.procedure_code is mapped correctly", %{claim: claim} do
      procedure_codes = Enum.map(claim["service_lines"], & &1["procedure_code"])
      assert "80053" in procedure_codes
      assert "85025" in procedure_codes
    end

    # --- Billing provider (top-level, for taxonomy rule) ---

    test "maps billing_provider.taxonomy from taxonomy_code key", %{claim: claim} do
      assert claim["billing_provider"]["taxonomy"] == "291U00000X"
      refute Map.has_key?(claim["billing_provider"], "taxonomy_code")
    end

    test "maps billing_provider.npi", %{claim: claim} do
      assert claim["billing_provider"]["npi"] == "1003001850"
    end

    # --- Authorization ---

    test "sets authorization.authorization_number to nil (not in 837P)", %{claim: claim} do
      assert is_nil(claim["authorization"]["authorization_number"])
    end

    # ---------------------------------------------------------------------------
    # Rule-by-rule trace: verify lab_work does NOT trigger any active fraud rules
    # ---------------------------------------------------------------------------

    test "RULE MissingRequiredFields — all mandatory fields are present", %{claim: claim} do
      # WHEN claim_id IS NULL OR provider.npi IS NULL OR patient.date_of_birth IS NULL
      #   OR financial.claim_amount IS NULL
      refute is_nil(claim["claim_id"])
      refute is_nil(get_in(claim, ["provider", "npi"]))
      refute is_nil(get_in(claim, ["patient", "date_of_birth"]))
      refute is_nil(get_in(claim, ["financial", "claim_amount"]))
    end

    test "RULE MissingDiagnosisCodes — diagnosis codes are present", %{claim: claim} do
      # WHEN COUNT(diagnosis_codes) = 0
      assert length(claim["diagnosis_codes"]) > 0
    end

    test "RULE InvalidNPIFormat — NPI is exactly 10 digits", %{claim: claim} do
      # WHEN NOT is_npi_format(provider.npi)
      assert String.match?(claim["provider"]["npi"], ~r/^\d{10}$/)
    end

    test "RULE ExcessiveTotalCharges — charges do not exceed $750K", %{claim: claim} do
      # WHEN claim_totals.total_charges > 750000
      refute claim["claim_totals"]["total_charges"] > 750_000
    end

    test "RULE ExtremeAmounts — charges do not exceed $1M", %{claim: claim} do
      # WHEN claim_totals.total_charges > 1000000
      refute claim["claim_totals"]["total_charges"] > 1_000_000
    end

    test "RULE HighValueClaim — claim_amount does not exceed $50K", %{claim: claim} do
      # WHEN financial.claim_amount > 50000
      refute claim["financial"]["claim_amount"] > 50_000
    end

    test "RULE HighComplexityERVisit — procedure is not 99285", %{claim: claim} do
      # WHEN service_lines.0.procedure_code = "99285" AND financial.claim_amount > 10000
      first_procedure = hd(claim["service_lines"])["procedure_code"]
      refute first_procedure == "99285"
    end

    test "RULE SuspiciouslyLowCharge — charge is not below $5", %{claim: claim} do
      # WHEN financial.claim_amount < 5
      refute claim["financial"]["claim_amount"] < 5
    end

    test "RULE UnauthorizedProcedure — amount is under $5000 threshold", %{claim: claim} do
      # WHEN authorization_number IS NULL AND financial.claim_amount > 5000
      # authorization_number IS NULL but amount is $450, so rule does not fire
      refute claim["financial"]["claim_amount"] > 5_000
    end

    test "RULE MissingProviderTaxonomy — taxonomy is present", %{claim: claim} do
      # WHEN billing_provider.taxonomy IS NULL AND financial.claim_amount > 1000
      refute is_nil(claim["billing_provider"]["taxonomy"])
    end

    test "RULE FutureServiceDate — service date is not in the future", %{claim: claim} do
      # WHEN is_future_date(service_lines.0.date_of_service)
      # Date 20260307 (March 7, 2026) is in the past
      date_str = hd(claim["service_lines"])["date_of_service"]
      {:ok, date} = Date.from_iso8601("#{String.slice(date_str, 0, 4)}-#{String.slice(date_str, 4, 2)}-#{String.slice(date_str, 6, 2)}")
      refute Date.after?(date, Date.utc_today())
    end

    test "RULE PatientAgeOutOfRange — patient age is in valid range (0-130)", %{claim: claim} do
      # DOB 19551108 → ~70 years old
      dob_str = claim["patient"]["date_of_birth"]
      {:ok, dob} = Date.from_iso8601("#{String.slice(dob_str, 0, 4)}-#{String.slice(dob_str, 4, 2)}-#{String.slice(dob_str, 6, 2)}")
      age_years = Date.diff(Date.utc_today(), dob) |> div(365)
      assert age_years >= 0 and age_years <= 130
    end
  end

  # ---------------------------------------------------------------------------
  # Preventive care claim — CLM100004
  # 837P professional: pediatric well-visit + immunizations, 3 service lines, $275
  # ---------------------------------------------------------------------------

  describe "normalize/1 — preventive 837P (CLM100004)" do
    setup do
      {:ok, claim: SegmentMapper.normalize(@preventive)}
    end

    test "maps claim_id", %{claim: claim} do
      assert claim["claim_id"] == "CLM100004"
    end

    test "maps provider.npi", %{claim: claim} do
      assert claim["provider"]["npi"] == "1003000118"
    end

    test "maps provider.taxonomy", %{claim: claim} do
      assert claim["provider"]["taxonomy"] == "208D00000X"
    end

    test "maps patient.date_of_birth (pediatric patient)", %{claim: claim} do
      # Child born 2018-09-05
      assert claim["patient"]["date_of_birth"] == "20180905"
    end

    test "maps financial.claim_amount as float", %{claim: claim} do
      assert claim["financial"]["claim_amount"] == 275.0
    end

    test "maps claim_totals.total_charges as float", %{claim: claim} do
      assert claim["claim_totals"]["total_charges"] == 275.0
    end

    test "maps 1 diagnosis code", %{claim: claim} do
      assert length(claim["diagnosis_codes"]) == 1
      assert hd(claim["diagnosis_codes"])["code"] == "Z0000"
    end

    test "maps 3 service lines", %{claim: claim} do
      assert length(claim["service_lines"]) == 3
    end

    test "service_line.date_of_service mapped from service_date", %{claim: claim} do
      Enum.each(claim["service_lines"], fn line ->
        assert line["date_of_service"] == "20260312"
      end)
    end

    test "maps correct procedure codes", %{claim: claim} do
      codes = Enum.map(claim["service_lines"], & &1["procedure_code"])
      assert "99392" in codes
      assert "90460" in codes
      assert "90688" in codes
    end

    test "RULE MissingRequiredFields — all mandatory fields are present", %{claim: claim} do
      refute is_nil(claim["claim_id"])
      refute is_nil(get_in(claim, ["provider", "npi"]))
      refute is_nil(get_in(claim, ["patient", "date_of_birth"]))
      refute is_nil(get_in(claim, ["financial", "claim_amount"]))
    end

    test "RULE MissingDiagnosisCodes — diagnosis code Z0000 is present", %{claim: claim} do
      assert length(claim["diagnosis_codes"]) > 0
    end

    test "RULE InvalidNPIFormat — NPI is 10 digits", %{claim: claim} do
      assert String.match?(claim["provider"]["npi"], ~r/^\d{10}$/)
    end

    test "RULE UnauthorizedProcedure — amount $275 is below $5K threshold", %{claim: claim} do
      refute claim["financial"]["claim_amount"] > 5_000
    end

    test "RULE MissingProviderTaxonomy — taxonomy is present", %{claim: claim} do
      refute is_nil(claim["billing_provider"]["taxonomy"])
    end

    test "RULE PatientAgeOutOfRange — pediatric patient age is in range (0-130)", %{claim: claim} do
      dob_str = claim["patient"]["date_of_birth"]
      {:ok, dob} = Date.from_iso8601("#{String.slice(dob_str, 0, 4)}-#{String.slice(dob_str, 4, 2)}-#{String.slice(dob_str, 6, 2)}")
      age_years = Date.diff(Date.utc_today(), dob) |> div(365)
      assert age_years >= 0 and age_years <= 130
    end

    test "RULE FutureServiceDate — service date 20260312 is in the past", %{claim: claim} do
      date_str = hd(claim["service_lines"])["date_of_service"]
      {:ok, date} = Date.from_iso8601("#{String.slice(date_str, 0, 4)}-#{String.slice(date_str, 4, 2)}-#{String.slice(date_str, 6, 2)}")
      refute Date.after?(date, Date.utc_today())
    end
  end
end
