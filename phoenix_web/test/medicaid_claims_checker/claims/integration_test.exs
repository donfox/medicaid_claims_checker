defmodule MedicaidClaimsChecker.Claims.IntegrationTest do
  @moduledoc """
  Live integration tests that call the real Haskell engine at http://localhost:8080.

  These tests are tagged :integration and are excluded from `mix test` by default.
  Run them explicitly with:

      mix test --include integration test/medicaid_claims_checker/claims/integration_test.exs

  The Haskell engine must be running:

      cd haskell_engine && cabal run medicaid-claims-dsl-server

  Tests verify end-to-end: ingest → evaluate → result stored correctly.
  """

  use MedicaidClaimsChecker.DataCase

  @moduletag :integration

  alias MedicaidClaimsChecker.Claims
  alias MedicaidClaimsChecker.Claims.{Evaluator, NppesProvider}
  alias MedicaidClaimsChecker.X12.SegmentMapper

  @lab_work Jason.decode!(File.read!("test/fixtures/x12/valid_837p_lab_work.json"))
  @preventive Jason.decode!(File.read!("test/fixtures/x12/valid_837p_preventive.json"))

  setup do
    Application.put_env(:medicaid_claims_checker, :rule_engine_url, "http://localhost:8080")
    Application.put_env(
      :medicaid_claims_checker,
      :rule_engine_secret,
      System.get_env("RULE_ENGINE_SECRET") || "dev-secret-change-in-production"
    )

    on_exit(fn ->
      Application.delete_env(:medicaid_claims_checker, :rule_engine_url)
      Application.delete_env(:medicaid_claims_checker, :rule_engine_secret)
    end)

    Repo.insert!(%NppesProvider{
      npi: "1003001850",
      entity_type: 2,
      provider_name: "Test Lab Provider",
      state: "IL",
      enumeration_date: ~D[2010-01-01],
      deactivation_date: nil
    })

    Repo.insert!(%NppesProvider{
      npi: "1003000118",
      entity_type: 2,
      provider_name: "Test Preventive Provider",
      state: "IL",
      enumeration_date: ~D[2010-01-01],
      deactivation_date: nil
    })

    :ok
  end

  defp create_default_rules! do
    rules = [
      {"missing_required_fields",
       ~s|RULE missing_required_fields "Ensures all mandatory fields are present" WHEN claim_id IS NULL OR provider.npi IS NULL OR patient.date_of_birth IS NULL OR financial.claim_amount IS NULL THEN REJECT "Missing required claim field";|},
      {"missing_diagnosis_codes",
       ~s|RULE missing_diagnosis_codes "Rejects claims with no diagnosis codes" WHEN COUNT(diagnosis_codes) = 0 THEN REJECT "No diagnosis codes present on claim";|},
      {"invalid_npi_format",
       ~s|RULE invalid_npi_format "Rejects claims where the billing provider NPI is not exactly 10 digits" WHEN provider.npi IS NOT NULL AND NOT is_npi_format(provider.npi) THEN REJECT "Provider NPI is not a valid 10-digit number";|},
      {"invalid_provider_npi",
       ~s|RULE invalid_provider_npi "Validates that the billing provider NPI passes Luhn-10 checksum" WHEN provider.npi IS NOT NULL AND NOT is_valid_npi(provider.npi) THEN REJECT "Provider NPI fails Luhn-10 validation";|},
      {"future_service_date",
       ~s|RULE future_service_date "Rejects claims where the date of service has not yet occurred" WHEN is_future_date(service_lines.0.date_of_service) THEN REJECT "Service date is in the future";|},
      {"excessive_total_charges",
       ~s|RULE excessive_total_charges "Flags claims with total charges exceeding $750,000 as potential fraud" WHEN claim_totals.total_charges > 750000 THEN FLAG_FRAUD "Total charges exceed $750K threshold";|},
      {"high_value_claim",
       ~s|RULE high_value_claim DESCRIPTION "Claims exceeding $50,000 require manual review before payment" WHEN financial.claim_amount > 50000 THEN REQUIRE_REVIEW "Claim exceeds high-value threshold — manual approval required" END|}
    ]

    Enum.each(rules, fn {name, text} ->
      {:ok, _} = Claims.create_business_rule(%{name: name, rule_text: text, active: true})
    end)
  end

  defp ingest_and_evaluate!(claims) do
    params = %{
      "batch_id" => "integration-#{System.unique_integer([:positive])}",
      "source" => "integration-test",
      "claims" => claims
    }

    {:ok, %{batch: batch}} = Claims.ingest_batch(params)
    Evaluator.evaluate_batch(batch)
    Claims.list_files_for_batch(batch.id)
  end

  # ---------------------------------------------------------------------------
  # Real fixture claims — should evaluate cleanly
  # ---------------------------------------------------------------------------

  describe "real X12 fixture claims against live engine" do
    setup do
      create_default_rules!()
      :ok
    end

    test "CLM100002 lab_work evaluates without fraud flags" do
      claim = SegmentMapper.normalize(@lab_work)

      [file] =
        ingest_and_evaluate!([%{"filename" => "lab_work.json", "claim" => claim}])

      assert file.status == "evaluated",
             "lab_work CLM100002 should pass all rules; got status=#{file.status}, " <>
               "report=#{inspect(file.json_output)}"

      report = file.json_output || %{}
      assert report["overallRisk"] in ["LowRisk", nil]
    end

    test "CLM100004 preventive evaluates without fraud flags" do
      claim = SegmentMapper.normalize(@preventive)

      [file] =
        ingest_and_evaluate!([%{"filename" => "preventive.json", "claim" => claim}])

      assert file.status == "evaluated",
             "preventive CLM100004 should pass all rules; got status=#{file.status}, " <>
               "report=#{inspect(file.json_output)}"
    end

    test "both fixture claims in one batch both evaluate cleanly" do
      lab = SegmentMapper.normalize(@lab_work)
      prev = SegmentMapper.normalize(@preventive)

      [lab_file, prev_file] =
        ingest_and_evaluate!([
          %{"filename" => "lab_work.json", "claim" => lab},
          %{"filename" => "preventive.json", "claim" => prev}
        ])

      assert lab_file.status == "evaluated"
      assert prev_file.status == "evaluated"
    end
  end

  # ---------------------------------------------------------------------------
  # Fraud trigger — should fire against live engine
  # ---------------------------------------------------------------------------

  describe "fraud trigger claims against live engine" do
    setup do
      create_default_rules!()
      :ok
    end

    test "missing claim_id triggers MissingRequiredFields" do
      claim = %{
        "provider" => %{"npi" => "1003001850"},
        "patient" => %{"date_of_birth" => "19901215"},
        "financial" => %{"claim_amount" => 450.0},
        "diagnosis_codes" => [%{"code" => "E119", "qualifier" => "ABK"}],
        "service_lines" => [%{"date_of_service" => "2026-03-07", "procedure_code" => "80053"}],
        "claim_totals" => %{"total_charges" => 450.0}
      }

      [file] = ingest_and_evaluate!([%{"filename" => "no_claim_id.json", "claim" => claim}])

      assert file.status == "fraudulent",
             "claim without claim_id must be rejected; got status=#{file.status}"
    end

    test "amount > $750K triggers ExcessiveTotalCharges" do
      claim = %{
        "claim_id" => "CLM-EXCESSIVE",
        "provider" => %{"npi" => "1003001850"},
        "patient" => %{"date_of_birth" => "19901215"},
        "financial" => %{"claim_amount" => 800_000.0},
        "diagnosis_codes" => [%{"code" => "E119", "qualifier" => "ABK"}],
        "service_lines" => [%{"date_of_service" => "2026-03-07", "procedure_code" => "80053"}],
        "claim_totals" => %{"total_charges" => 800_000.0}
      }

      [file] = ingest_and_evaluate!([%{"filename" => "excessive.json", "claim" => claim}])

      assert file.status in ["fraudulent", "evaluated"],
             "excessive charges must be flagged; got status=#{file.status}"

      report = file.json_output || %{}

      matched =
        (report["results"] || [])
        |> Enum.any?(&(&1["resultMatched"] == true))

      assert matched, "at least one rule must have fired for $800K claim"
    end

    test "future service date triggers FutureServiceDate" do
      claim = %{
        "claim_id" => "CLM-FUTURE",
        "provider" => %{"npi" => "1003001850"},
        "patient" => %{"date_of_birth" => "19901215"},
        "financial" => %{"claim_amount" => 450.0},
        "diagnosis_codes" => [%{"code" => "E119", "qualifier" => "ABK"}],
        "service_lines" => [%{"date_of_service" => "2099-01-01", "procedure_code" => "80053"}],
        "claim_totals" => %{"total_charges" => 450.0}
      }

      [file] = ingest_and_evaluate!([%{"filename" => "future_date.json", "claim" => claim}])

      assert file.status == "fraudulent",
             "future service date must be rejected; got status=#{file.status}"
    end
  end
end
