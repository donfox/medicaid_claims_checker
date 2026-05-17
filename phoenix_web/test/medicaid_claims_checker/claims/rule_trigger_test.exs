defmodule MedicaidClaimsChecker.Claims.RuleTriggerTest do
  @moduledoc """
  Negative-case (trigger) tests: verifies that claims with specific fraud patterns
  are correctly normalized, sent to the engine with the right structure, and stored
  as fraudulent when the engine flags them.

  Each test:
  1. Builds a claim that should trigger a specific rule
  2. Uses a Bypass mock to verify the payload reaches the engine correctly structured
  3. Mocks the engine response as if the rule fired
  4. Asserts the file is stored as "fraudulent"

  The actual rule logic is covered by the Haskell unit tests.
  These tests cover the Elixir pipeline side.
  """

  use MedicaidClaimsChecker.DataCase

  alias MedicaidClaimsChecker.Claims
  alias MedicaidClaimsChecker.Claims.Evaluator
  alias MedicaidClaimsChecker.Claims.NppesProvider

  setup do
    bypass = Bypass.open()

    Application.put_env(
      :medicaid_claims_checker,
      :rule_engine_url,
      "http://localhost:#{bypass.port}"
    )

    # Pre-populate NPPES so provider NPI lookups don't hard-reject valid test claims
    insert_active_nppes_provider("1003001850")
    insert_active_nppes_provider("1003000118")

    on_exit(fn ->
      Application.delete_env(:medicaid_claims_checker, :rule_engine_url)
    end)

    {:ok, bypass: bypass}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp ingest_batch!(claims) do
    params = %{
      "batch_id" => "trigger-test-#{System.unique_integer([:positive])}",
      "source" => "rule-trigger-test",
      "claims" => claims
    }

    {:ok, %{batch: batch}} = Claims.ingest_batch(params)
    batch
  end

  defp create_rule!(name, rule_text) do
    {:ok, rule} = Claims.create_business_rule(%{name: name, rule_text: rule_text, active: true})
    rule
  end

  defp fraud_response do
    Jason.encode!(%{
      "totalClaims" => 1,
      "batchResults" => [
        %{
          "report" => %{
            "overallRisk" => "CriticalRisk",
            "matchedRules" => 1,
            "totalRules" => 1,
            "results" => [
              %{
                "resultRuleName" => "triggered_rule",
                "resultMatched" => true,
                "resultAction" => %{"tag" => "RejectClaim'", "contents" => "Rule triggered"},
                "resultDetails" => "Rule triggered in test"
              }
            ]
          }
        }
      ]
    })
  end

  defp low_risk_response do
    Jason.encode!(%{
      "totalClaims" => 1,
      "batchResults" => [
        %{
          "report" => %{
            "overallRisk" => "LowRisk",
            "matchedRules" => 0,
            "totalRules" => 1,
            "results" => []
          }
        }
      ]
    })
  end

  # A valid baseline claim that satisfies all active rules
  defp valid_claim(overrides \\ %{}) do
    base = %{
      "claim_id" => "CLM-VALID-001",
      "provider" => %{
        "npi" => "1003001850",
        "tenure_days" => 500
      },
      "patient" => %{"date_of_birth" => "19901215"},
      "financial" => %{"claim_amount" => 450.0},
      "claim_totals" => %{"total_charges" => 450.0},
      "diagnosis_codes" => [%{"code" => "E119", "qualifier" => "ABK"}],
      "service_lines" => [
        %{"date_of_service" => "2026-03-07", "procedure_code" => "80053"}
      ],
      "billing_provider" => %{"taxonomy" => "291U00000X"},
      "authorization" => %{"authorization_number" => "AUTH-001"}
    }

    Map.merge(base, overrides)
  end

  defp expect_fraud_response(bypass) do
    Bypass.expect_once(bypass, "POST", "/api/batch-evaluate", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, fraud_response())
    end)
  end

  defp expect_low_risk_response(bypass) do
    Bypass.expect_once(bypass, "POST", "/api/batch-evaluate", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, low_risk_response())
    end)
  end

  defp run_and_get_file(batch) do
    Evaluator.evaluate_batch(batch)
    batch.id |> Claims.list_files_for_batch() |> hd()
  end

  defp insert_active_nppes_provider(npi) do
    Repo.insert!(%NppesProvider{
      npi: npi,
      entity_type: 2,
      provider_name: "Test Provider #{npi}",
      state: "IL",
      enumeration_date: ~D[2010-01-01],
      deactivation_date: nil
    })
  end

  # ---------------------------------------------------------------------------
  # MissingRequiredFields — null claim fields
  # ---------------------------------------------------------------------------

  describe "RULE MissingRequiredFields" do
    setup do
      create_rule!(
        "missing_required_fields",
        ~s|RULE missing_required_fields "Ensures all mandatory fields are present" WHEN claim_id IS NULL OR provider.npi IS NULL OR patient.date_of_birth IS NULL OR financial.claim_amount IS NULL THEN REJECT "Missing required claim field";|
      )

      :ok
    end

    test "null claim_id: engine receives null and pipeline stores fraudulent", %{bypass: bypass} do
      claim = valid_claim(%{"claim_id" => nil})

      Bypass.expect_once(bypass, "POST", "/api/batch-evaluate", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(body)
        [sent] = payload["claims"]

        assert is_nil(sent["claim_id"]),
               "claim_id should be null in payload so MissingRequiredFields fires"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, fraud_response())
      end)

      batch = ingest_batch!([%{"filename" => "missing_id.json", "claim" => claim}])
      file = run_and_get_file(batch)

      assert file.status == "fraudulent"
    end

    test "null provider.npi: engine receives null and pipeline stores fraudulent", %{
      bypass: bypass
    } do
      claim = valid_claim(%{"provider" => %{"npi" => nil, "tenure_days" => 500}})

      Bypass.expect_once(bypass, "POST", "/api/batch-evaluate", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(body)
        [sent] = payload["claims"]

        assert is_nil(get_in(sent, ["provider", "npi"])),
               "provider.npi should be null so MissingRequiredFields fires"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, fraud_response())
      end)

      batch = ingest_batch!([%{"filename" => "missing_npi.json", "claim" => claim}])
      file = run_and_get_file(batch)

      assert file.status == "fraudulent"
    end

    test "null patient.date_of_birth: pipeline stores fraudulent", %{bypass: bypass} do
      claim = valid_claim(%{"patient" => %{"date_of_birth" => nil}})
      expect_fraud_response(bypass)

      batch = ingest_batch!([%{"filename" => "missing_dob.json", "claim" => claim}])
      file = run_and_get_file(batch)

      assert file.status == "fraudulent"
    end

    test "null financial.claim_amount: pipeline stores fraudulent", %{bypass: bypass} do
      claim = valid_claim(%{"financial" => %{"claim_amount" => nil}})
      expect_fraud_response(bypass)

      batch = ingest_batch!([%{"filename" => "missing_amount.json", "claim" => claim}])
      file = run_and_get_file(batch)

      assert file.status == "fraudulent"
    end

    test "all required fields present: pipeline stores evaluated", %{bypass: bypass} do
      claim = valid_claim()
      expect_low_risk_response(bypass)

      batch = ingest_batch!([%{"filename" => "all_fields.json", "claim" => claim}])
      file = run_and_get_file(batch)

      assert file.status == "evaluated"
    end
  end

  # ---------------------------------------------------------------------------
  # MissingDiagnosisCodes — empty array
  # ---------------------------------------------------------------------------

  describe "RULE MissingDiagnosisCodes" do
    setup do
      create_rule!(
        "missing_diagnosis_codes",
        ~s|RULE missing_diagnosis_codes "Rejects claims with no diagnosis codes" WHEN COUNT(diagnosis_codes) = 0 THEN REJECT "No diagnosis codes present on claim";|
      )

      :ok
    end

    test "empty diagnosis_codes array: engine receives [] and pipeline stores fraudulent", %{
      bypass: bypass
    } do
      claim = valid_claim(%{"diagnosis_codes" => []})

      Bypass.expect_once(bypass, "POST", "/api/batch-evaluate", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(body)
        [sent] = payload["claims"]

        assert sent["diagnosis_codes"] == [],
               "diagnosis_codes must be empty array so COUNT = 0 fires"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, fraud_response())
      end)

      batch = ingest_batch!([%{"filename" => "no_dx.json", "claim" => claim}])
      file = run_and_get_file(batch)

      assert file.status == "fraudulent"
    end

    test "non-empty diagnosis_codes: pipeline stores evaluated", %{bypass: bypass} do
      claim = valid_claim()
      expect_low_risk_response(bypass)

      batch = ingest_batch!([%{"filename" => "has_dx.json", "claim" => claim}])
      file = run_and_get_file(batch)

      assert file.status == "evaluated"
    end
  end

  # ---------------------------------------------------------------------------
  # InvalidNPIFormat — non-10-digit NPI
  # ---------------------------------------------------------------------------

  describe "RULE InvalidNPIFormat" do
    setup do
      create_rule!(
        "invalid_npi_format",
        ~s|RULE invalid_npi_format "Rejects claims where the billing provider NPI is not exactly 10 digits" WHEN provider.npi IS NOT NULL AND NOT is_npi_format(provider.npi) THEN REJECT "Provider NPI is not a valid 10-digit number";|
      )

      :ok
    end

    test "5-digit NPI: engine receives short NPI and pipeline stores fraudulent", %{
      bypass: bypass
    } do
      claim = valid_claim(%{"provider" => %{"npi" => "12345", "tenure_days" => 500}})

      Bypass.expect_once(bypass, "POST", "/api/batch-evaluate", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(body)
        [sent] = payload["claims"]

        assert get_in(sent, ["provider", "npi"]) == "12345"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, fraud_response())
      end)

      batch = ingest_batch!([%{"filename" => "short_npi.json", "claim" => claim}])
      file = run_and_get_file(batch)

      assert file.status == "fraudulent"
    end

    test "NPI with letters: pipeline stores fraudulent", %{bypass: bypass} do
      claim = valid_claim(%{"provider" => %{"npi" => "123456789a", "tenure_days" => 500}})
      expect_fraud_response(bypass)

      batch = ingest_batch!([%{"filename" => "alpha_npi.json", "claim" => claim}])
      file = run_and_get_file(batch)

      assert file.status == "fraudulent"
    end

    test "valid 10-digit NPI: pipeline stores evaluated", %{bypass: bypass} do
      claim = valid_claim()
      expect_low_risk_response(bypass)

      batch = ingest_batch!([%{"filename" => "valid_npi_fmt.json", "claim" => claim}])
      file = run_and_get_file(batch)

      assert file.status == "evaluated"
    end
  end

  # ---------------------------------------------------------------------------
  # InvalidProviderNPI — Luhn-10 failure
  # ---------------------------------------------------------------------------

  describe "RULE InvalidProviderNPI" do
    setup do
      create_rule!(
        "invalid_provider_npi",
        ~s|RULE invalid_provider_npi "Validates that the billing provider NPI passes Luhn-10 checksum" WHEN provider.npi IS NOT NULL AND NOT is_valid_npi(provider.npi) THEN REJECT "Provider NPI fails Luhn-10 validation";|
      )

      :ok
    end

    test "NPI 1234567890 (valid format, invalid Luhn): pipeline stores fraudulent", %{
      bypass: bypass
    } do
      claim = valid_claim(%{"provider" => %{"npi" => "1234567890", "tenure_days" => 500}})

      Bypass.expect_once(bypass, "POST", "/api/batch-evaluate", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(body)
        [sent] = payload["claims"]

        assert get_in(sent, ["provider", "npi"]) == "1234567890",
               "bad-Luhn NPI must be passed to engine"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, fraud_response())
      end)

      batch = ingest_batch!([%{"filename" => "bad_luhn.json", "claim" => claim}])
      file = run_and_get_file(batch)

      assert file.status == "fraudulent"
    end

    test "lab_work fixture NPI 1003001850 (valid Luhn): pipeline stores evaluated", %{
      bypass: bypass
    } do
      claim = valid_claim()
      expect_low_risk_response(bypass)

      batch = ingest_batch!([%{"filename" => "valid_luhn_lab.json", "claim" => claim}])
      file = run_and_get_file(batch)

      assert file.status == "evaluated",
             "NPI 1003001850 has valid Luhn — InvalidProviderNPI must not fire"
    end

    test "preventive fixture NPI 1003000118 (valid Luhn): engine receives NPI correctly", %{
      bypass: bypass
    } do
      claim = valid_claim(%{"provider" => %{"npi" => "1003000118", "tenure_days" => 500}})

      Bypass.expect_once(bypass, "POST", "/api/batch-evaluate", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(body)
        [sent] = payload["claims"]

        assert get_in(sent, ["provider", "npi"]) == "1003000118"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, low_risk_response())
      end)

      batch = ingest_batch!([%{"filename" => "valid_luhn_prev.json", "claim" => claim}])
      file = run_and_get_file(batch)

      assert file.status == "evaluated",
             "NPI 1003000118 has valid Luhn — InvalidProviderNPI must not fire"
    end
  end

  # ---------------------------------------------------------------------------
  # FutureServiceDate — future date in service line
  # ---------------------------------------------------------------------------

  describe "RULE FutureServiceDate" do
    setup do
      create_rule!(
        "future_service_date",
        ~s|RULE future_service_date "Rejects claims where the date of service has not yet occurred" WHEN is_future_date(service_lines.0.date_of_service) THEN REJECT "Service date is in the future";|
      )

      :ok
    end

    test "future service date 2099-01-01: engine receives future date and pipeline stores fraudulent",
         %{bypass: bypass} do
      claim =
        valid_claim(%{
          "service_lines" => [%{"date_of_service" => "2099-01-01", "procedure_code" => "80053"}]
        })

      Bypass.expect_once(bypass, "POST", "/api/batch-evaluate", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(body)
        [sent] = payload["claims"]

        assert hd(sent["service_lines"])["date_of_service"] == "2099-01-01",
               "future date must reach engine"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, fraud_response())
      end)

      batch = ingest_batch!([%{"filename" => "future_date.json", "claim" => claim}])
      file = run_and_get_file(batch)

      assert file.status == "fraudulent"
    end

    test "past service date 2026-03-07: pipeline stores evaluated", %{bypass: bypass} do
      claim = valid_claim()
      expect_low_risk_response(bypass)

      batch = ingest_batch!([%{"filename" => "past_date.json", "claim" => claim}])
      file = run_and_get_file(batch)

      assert file.status == "evaluated"
    end
  end

  # ---------------------------------------------------------------------------
  # ExcessiveTotalCharges / ExtremeAmounts — large charge amounts
  # ---------------------------------------------------------------------------

  describe "RULE ExcessiveTotalCharges and ExtremeAmounts" do
    setup do
      create_rule!(
        "excessive_total_charges",
        ~s|RULE excessive_total_charges "Flags claims with total charges exceeding $750,000 as potential fraud" WHEN claim_totals.total_charges > 750000 THEN FLAG_FRAUD "Total charges exceed $750K threshold";|
      )

      create_rule!(
        "extreme_amounts",
        ~s|RULE extreme_amounts "Flags claims with total charges exceeding $1,000,000" WHEN claim_totals.total_charges > 1000000 THEN FLAG_FRAUD "Extreme billing amount exceeds $1M";|
      )

      :ok
    end

    test "$800K claim: engine receives correct total_charges and pipeline stores fraudulent", %{
      bypass: bypass
    } do
      claim =
        valid_claim(%{
          "financial" => %{"claim_amount" => 800_000.0},
          "claim_totals" => %{"total_charges" => 800_000.0}
        })

      Bypass.expect_once(bypass, "POST", "/api/batch-evaluate", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(body)
        [sent] = payload["claims"]

        assert get_in(sent, ["claim_totals", "total_charges"]) == 800_000.0,
               "total_charges must reach engine as float"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, fraud_response())
      end)

      batch = ingest_batch!([%{"filename" => "excessive.json", "claim" => claim}])
      file = run_and_get_file(batch)

      assert file.status == "fraudulent"
    end

    test "$450 claim: pipeline stores evaluated", %{bypass: bypass} do
      claim = valid_claim()
      expect_low_risk_response(bypass)

      batch = ingest_batch!([%{"filename" => "normal_amount.json", "claim" => claim}])
      file = run_and_get_file(batch)

      assert file.status == "evaluated"
    end
  end

  # ---------------------------------------------------------------------------
  # UnauthorizedProcedure — null auth + high amount
  # ---------------------------------------------------------------------------

  describe "RULE UnauthorizedProcedure" do
    setup do
      create_rule!(
        "unauthorized_procedure",
        ~s|RULE unauthorized_procedure DESCRIPTION "High-value claim submitted without a valid authorization number" WHEN authorization.authorization_number IS NULL AND financial.claim_amount > 5000 THEN REJECT "High-value claim lacks required authorization" END|
      )

      :ok
    end

    test "null auth + $10K: engine receives null authorization_number and pipeline stores fraudulent",
         %{bypass: bypass} do
      claim =
        valid_claim(%{
          "financial" => %{"claim_amount" => 10_000.0},
          "authorization" => %{"authorization_number" => nil}
        })

      Bypass.expect_once(bypass, "POST", "/api/batch-evaluate", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(body)
        [sent] = payload["claims"]

        assert is_nil(get_in(sent, ["authorization", "authorization_number"])),
               "authorization_number must be null"

        assert get_in(sent, ["financial", "claim_amount"]) == 10_000.0

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, fraud_response())
      end)

      batch = ingest_batch!([%{"filename" => "no_auth_high.json", "claim" => claim}])
      file = run_and_get_file(batch)

      assert file.status == "fraudulent"
    end

    test "null auth + $450 (below threshold): pipeline stores evaluated", %{bypass: bypass} do
      # amount < $5000 so rule does not fire despite missing auth
      claim = valid_claim(%{"authorization" => %{"authorization_number" => nil}})
      expect_low_risk_response(bypass)

      batch = ingest_batch!([%{"filename" => "no_auth_low.json", "claim" => claim}])
      file = run_and_get_file(batch)

      assert file.status == "evaluated"
    end

    test "auth present + $10K: pipeline stores evaluated", %{bypass: bypass} do
      claim = valid_claim(%{"financial" => %{"claim_amount" => 10_000.0}})
      expect_low_risk_response(bypass)

      batch = ingest_batch!([%{"filename" => "has_auth_high.json", "claim" => claim}])
      file = run_and_get_file(batch)

      assert file.status == "evaluated"
    end
  end

  # ---------------------------------------------------------------------------
  # SuspiciouslyLowCharge — amount < $5
  # ---------------------------------------------------------------------------

  describe "RULE SuspiciouslyLowCharge" do
    setup do
      create_rule!(
        "suspicious_low_charge",
        ~s|RULE suspicious_low_charge DESCRIPTION "Charge below $5 may indicate billing manipulation or data error" WHEN financial.claim_amount < 5 THEN FLAG_FRAUD "Suspiciously low charge — possible billing manipulation" END|
      )

      :ok
    end

    test "$2.50 claim: engine receives amount and pipeline stores fraudulent", %{bypass: bypass} do
      claim = valid_claim(%{"financial" => %{"claim_amount" => 2.50}})
      expect_fraud_response(bypass)

      batch = ingest_batch!([%{"filename" => "low_charge.json", "claim" => claim}])
      file = run_and_get_file(batch)

      assert file.status == "fraudulent"
    end

    test "$5.00 claim (boundary — rule is strict < 5): pipeline stores evaluated", %{
      bypass: bypass
    } do
      claim = valid_claim(%{"financial" => %{"claim_amount" => 5.0}})
      expect_low_risk_response(bypass)

      batch = ingest_batch!([%{"filename" => "boundary_charge.json", "claim" => claim}])
      file = run_and_get_file(batch)

      assert file.status == "evaluated"
    end
  end

  # ---------------------------------------------------------------------------
  # NULL safety: tenure_days null → NewProviderLargeSubmission does NOT fire
  # ---------------------------------------------------------------------------

  describe "NULL safety — tenure_days" do
    setup do
      create_rule!(
        "new_provider_large_submission",
        ~s|RULE new_provider_large_submission DESCRIPTION "Large claim from a provider credentialed less than 90 days ago" WHEN provider.tenure_days < 90 AND financial.claim_amount > 10000 THEN REQUIRE_REVIEW "Large submission from newly credentialed provider" END|
      )

      :ok
    end

    test "null tenure_days + $50K claim: engine receives null tenure_days safely", %{
      bypass: bypass
    } do
      # Even though amount > $10K, null tenure_days must NOT trigger the rule
      # (numeric comparison with null must safely return false)
      claim =
        valid_claim(%{
          "provider" => %{"npi" => "1003001850", "tenure_days" => nil},
          "financial" => %{"claim_amount" => 50_000.0}
        })

      Bypass.expect_once(bypass, "POST", "/api/batch-evaluate", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(body)
        [sent] = payload["claims"]

        assert is_nil(get_in(sent, ["provider", "tenure_days"])),
               "tenure_days must be null in payload"

        # Engine returns LowRisk because null tenure_days means the rule doesn't fire
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, low_risk_response())
      end)

      batch = ingest_batch!([%{"filename" => "null_tenure.json", "claim" => claim}])
      file = run_and_get_file(batch)

      assert file.status == "evaluated",
             "null tenure_days must not cause NewProviderLargeSubmission to fire"
    end

    test "tenure_days=30 + $50K: pipeline routes to engine as trigger case", %{bypass: bypass} do
      claim =
        valid_claim(%{
          "provider" => %{"npi" => "1003001850", "tenure_days" => 30},
          "financial" => %{"claim_amount" => 50_000.0}
        })

      Bypass.expect_once(bypass, "POST", "/api/batch-evaluate", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(body)
        [sent] = payload["claims"]

        assert get_in(sent, ["provider", "tenure_days"]) == 30
        assert get_in(sent, ["financial", "claim_amount"]) == 50_000.0

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, fraud_response())
      end)

      batch = ingest_batch!([%{"filename" => "new_provider_large.json", "claim" => claim}])
      file = run_and_get_file(batch)

      assert file.status == "fraudulent"
    end
  end

  # ---------------------------------------------------------------------------
  # PatientAgeOutOfRange — extreme age
  # ---------------------------------------------------------------------------

  describe "RULE PatientAgeOutOfRange" do
    setup do
      create_rule!(
        "patient_age_out_of_range",
        ~s|RULE patient_age_out_of_range "Rejects claims where the patient age is negative or exceeds 130 years" WHEN patient.date_of_birth IS NOT NULL AND NOT is_age_valid(patient.date_of_birth, 0, 130) THEN REJECT "Patient age is out of valid range (0-130)";|
      )

      :ok
    end

    test "DOB 18001101 (age > 130): engine receives extreme DOB and pipeline stores fraudulent",
         %{bypass: bypass} do
      claim = valid_claim(%{"patient" => %{"date_of_birth" => "18001101"}})

      Bypass.expect_once(bypass, "POST", "/api/batch-evaluate", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(body)
        [sent] = payload["claims"]

        assert get_in(sent, ["patient", "date_of_birth"]) == "18001101"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, fraud_response())
      end)

      batch = ingest_batch!([%{"filename" => "extreme_age.json", "claim" => claim}])
      file = run_and_get_file(batch)

      assert file.status == "fraudulent"
    end

    test "DOB 19901215 (age ~35): pipeline stores evaluated", %{bypass: bypass} do
      claim = valid_claim()
      expect_low_risk_response(bypass)

      batch = ingest_batch!([%{"filename" => "normal_age.json", "claim" => claim}])
      file = run_and_get_file(batch)

      assert file.status == "evaluated"
    end
  end

  # ---------------------------------------------------------------------------
  # Authorization header — verify Bearer token is sent on every engine call
  # ---------------------------------------------------------------------------

  describe "Authorization header" do
    setup do
      Application.put_env(:medicaid_claims_checker, :rule_engine_secret, "test-secret-abc")
      on_exit(fn -> Application.delete_env(:medicaid_claims_checker, :rule_engine_secret) end)
      create_rule!("missing_required_fields",
        ~s|RULE missing_required_fields "test" WHEN claim_id IS NULL THEN REJECT "missing";|)
      :ok
    end

    test "correct Bearer token is sent to engine on every request", %{bypass: bypass} do
      claim = valid_claim()

      Bypass.expect_once(bypass, "POST", "/api/batch-evaluate", fn conn ->
        auth = Plug.Conn.get_req_header(conn, "authorization")
        assert auth == ["Bearer test-secret-abc"],
               "evaluator must send Authorization: Bearer <secret> on every engine call"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, low_risk_response())
      end)

      batch = ingest_batch!([%{"filename" => "auth_check.json", "claim" => claim}])
      run_and_get_file(batch)
    end

    test "engine 401 response causes batch to fail gracefully", %{bypass: bypass} do
      claim = valid_claim()

      Bypass.expect_once(bypass, "POST", "/api/batch-evaluate", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(401, ~s|{"error":"Unauthorized"}|)
      end)

      batch = ingest_batch!([%{"filename" => "auth_fail.json", "claim" => claim}])
      Evaluator.evaluate_batch(batch)

      updated_batch = Claims.get_batch!(batch.id)
      assert updated_batch.status == "failed",
             "batch must be marked failed when engine returns 401"
    end
  end
end
