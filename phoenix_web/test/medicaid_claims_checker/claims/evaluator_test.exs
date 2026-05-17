defmodule MedicaidClaimsChecker.Claims.EvaluatorTest do
  use MedicaidClaimsChecker.DataCase

  alias MedicaidClaimsChecker.Claims
  alias MedicaidClaimsChecker.Claims.Evaluator
  alias MedicaidClaimsChecker.X12.SegmentMapper

  # Real X12Translator output fixtures — the claims that were previously mis-evaluated
  @lab_work Jason.decode!(File.read!("test/fixtures/x12/valid_837p_lab_work.json"))
  @preventive Jason.decode!(File.read!("test/fixtures/x12/valid_837p_preventive.json"))

  setup do
    bypass = Bypass.open()

    Application.put_env(
      :medicaid_claims_checker,
      :rule_engine_url,
      "http://localhost:#{bypass.port}"
    )

    on_exit(fn ->
      Application.delete_env(:medicaid_claims_checker, :rule_engine_url)
    end)

    {:ok, bypass: bypass}
  end

  defp ingest_batch!(claims, batch_id \\ "eval-test-#{System.unique_integer([:positive])}") do
    params = %{
      "batch_id" => batch_id,
      "source" => "evaluator-test",
      "claims" => claims
    }

    {:ok, %{batch: batch}} = Claims.ingest_batch(params)
    batch
  end

  defp make_claim(filename, claim_amount) do
    %{
      "filename" => filename,
      "claim" => %{
        "claim_id" => "CLM-#{filename}",
        "provider" => %{"name" => "Test Clinic", "state" => "MO"},
        "service_lines" => [
          %{
            "procedure_code" => "99213",
            "line_amount" => claim_amount,
            "date_of_service" => "2026-01-15"
          }
        ],
        "claim_totals" => %{"total_submitted" => claim_amount},
        "2300" => %{"CLM" => %{"claim_amount" => claim_amount, "facility_type" => "Outpatient"}},
        "2400" => %{
          "SV1" => %{"place_of_service" => "11"},
          "DTP" => %{"service_day_of_week" => "TUE"}
        }
      }
    }
  end

  defp create_rule!(name, rule_text) do
    {:ok, rule} = Claims.create_business_rule(%{name: name, rule_text: rule_text, active: true})
    rule
  end

  defp insert_active_nppes_provider(npi) do
    Repo.insert!(%MedicaidClaimsChecker.Claims.NppesProvider{
      npi: npi,
      entity_type: 2,
      provider_name: "Active Provider #{npi}",
      state: "IL",
      enumeration_date: ~D[2010-01-01],
      deactivation_date: nil
    })
  end

  defp engine_response(results) do
    Jason.encode!(%{
      "totalClaims" => length(results),
      "batchResults" =>
        Enum.map(results, fn {risk, matched, rule_results} ->
          %{
            "report" => %{
              "overallRisk" => risk,
              "matchedRules" => matched,
              "totalRules" => 1,
              "results" => rule_results
            }
          }
        end)
    })
  end

  describe "evaluate_batch/1 with no active rules" do
    test "marks batch completed without calling engine" do
      batch = ingest_batch!([make_claim("clean.json", 150)])

      Evaluator.evaluate_batch(batch)

      updated = Claims.get_batch_by_batch_id(batch.batch_id)
      assert updated.status == "completed"
    end
  end

  describe "evaluate_batch/1 with empty translated files" do
    test "marks batch completed immediately" do
      batch = ingest_batch!([make_claim("clean.json", 150)])

      # Manually mark all files as already processed
      Claims.list_files_for_batch(batch.id)
      |> Enum.each(fn f -> Claims.update_edi_file_evaluation(f, %{status: "fraudulent"}) end)

      {:ok, updated} = Evaluator.evaluate_batch(batch)
      assert updated.status == "completed"
    end
  end

  describe "evaluate_batch/1 with rules and engine" do
    test "evaluates claims via Haskell engine and stores results", %{bypass: bypass} do
      create_rule!(
        "high_value_review",
        ~s|RULE high_value_review "Flag high-value claims" WHEN 2300.CLM.claim_amount > 50000 THEN REQUIRE_REVIEW "High value";|
      )

      Bypass.expect_once(bypass, "POST", "/api/batch-evaluate", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(body)

        assert length(payload["claims"]) == 2

        resp =
          engine_response([
            {"LowRisk", 0, []},
            {"HighRisk", 1,
             [
               %{
                 "resultRuleName" => "high_value_review",
                 "resultMatched" => true,
                 "resultAction" => %{"tag" => "RequireReview'", "contents" => "High value"},
                 "resultDetails" => "Exceeds high-value threshold"
               }
             ]}
          ])

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, resp)
      end)

      batch =
        ingest_batch!([
          make_claim("clean.json", 150),
          make_claim("expensive.json", 75_000)
        ])

      Evaluator.evaluate_batch(batch)

      # Verify batch is completed
      updated_batch = Claims.get_batch_by_batch_id(batch.batch_id)
      assert updated_batch.status == "completed"
      assert updated_batch.completed_at != nil

      # Verify individual file results
      files = Claims.list_files_for_batch(batch.id)
      clean = Enum.find(files, &(&1.filename == "clean.json"))
      expensive = Enum.find(files, &(&1.filename == "expensive.json"))

      assert clean.status == "evaluated"
      assert clean.json_output["overallRisk"] == "LowRisk"

      assert expensive.status == "fraudulent"
      assert expensive.json_output["overallRisk"] == "HighRisk"
      assert expensive.json_output["matchedRules"] == 1
    end

    test "marks CriticalRisk claims as fraudulent", %{bypass: bypass} do
      create_rule!(
        "extreme_amount",
        ~s|RULE extreme_amount "Extreme billing" WHEN 2300.CLM.claim_amount > 1000000 THEN FLAG_FRAUD "Extreme amount";|
      )

      Bypass.expect_once(bypass, "POST", "/api/batch-evaluate", fn conn ->
        resp =
          engine_response([
            {"CriticalRisk", 2,
             [
               %{
                 "resultRuleName" => "extreme_amount",
                 "resultMatched" => true,
                 "resultAction" => %{"tag" => "FlagFraud'", "contents" => "Extreme amount"},
                 "resultDetails" => "Extreme billing amount"
               }
             ]}
          ])

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, resp)
      end)

      batch = ingest_batch!([make_claim("extreme.json", 1_500_000)])
      Evaluator.evaluate_batch(batch)

      files = Claims.list_files_for_batch(batch.id)
      assert hd(files).status == "fraudulent"
      assert hd(files).json_output["overallRisk"] == "CriticalRisk"
    end

    test "marks batch failed when engine returns error", %{bypass: bypass} do
      create_rule!(
        "some_rule",
        ~s|RULE test "Test" WHEN 2300.CLM.claim_amount > 0 THEN REQUIRE_REVIEW "Review";|
      )

      Bypass.expect_once(bypass, "POST", "/api/batch-evaluate", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(500, ~s|{"error": "internal engine error"}|)
      end)

      batch = ingest_batch!([make_claim("fail.json", 100)])
      Evaluator.evaluate_batch(batch)

      updated = Claims.get_batch_by_batch_id(batch.batch_id)
      assert updated.status == "failed"
    end
  end

  describe "evaluate_batch/1 with NPPES pre-validation" do
    test "rejects claims with deactivated provider NPI", %{bypass: bypass} do
      # Insert a deactivated provider
      Repo.insert!(%MedicaidClaimsChecker.Claims.NppesProvider{
        npi: "1234567890",
        entity_type: 1,
        provider_name: "Deactivated Doctor",
        state: "MO",
        enumeration_date: ~D[2010-01-01],
        deactivation_date: ~D[2025-01-01]
      })

      create_rule!(
        "test_rule",
        ~s|RULE test "Test" WHEN 2300.CLM.claim_amount > 0 THEN REQUIRE_REVIEW "Review";|
      )

      # Engine is still called; NPPES finding is merged onto the engine report.
      Bypass.expect_once(bypass, "POST", "/api/batch-evaluate", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, engine_response([{"LowRisk", 0, []}]))
      end)

      claim_with_npi = %{
        "filename" => "deactivated_npi.json",
        "claim" => %{
          "claim_id" => "CLM-DEACT",
          "provider" => %{"name" => "Deactivated Doctor", "npi" => "1234567890", "state" => "MO"},
          "service_lines" => [
            %{
              "procedure_code" => "99213",
              "line_amount" => 150,
              "date_of_service" => "2026-01-15"
            }
          ],
          "2300" => %{"CLM" => %{"claim_amount" => 150}},
          "2400" => %{"SV1" => %{"place_of_service" => "11"}}
        }
      }

      batch = ingest_batch!([claim_with_npi])
      Evaluator.evaluate_batch(batch)

      updated_batch = Claims.get_batch_by_batch_id(batch.batch_id)
      assert updated_batch.status == "completed"

      files = Claims.list_files_for_batch(batch.id)
      file = hd(files)
      assert file.status == "fraudulent"
      assert file.json_output["overallRisk"] == "CriticalRisk"

      nppes_result =
        Enum.find(file.json_output["results"], fn result ->
          result["resultRuleName"] == "NPPESProviderLookup"
        end)

      assert nppes_result
      assert nppes_result["resultDetails"] =~ "deactivated"
    end

    test "rejects claims with unknown NPI", %{bypass: bypass} do
      create_rule!(
        "test_rule",
        ~s|RULE test "Test" WHEN 2300.CLM.claim_amount > 0 THEN REQUIRE_REVIEW "Review";|
      )

      Bypass.expect_once(bypass, "POST", "/api/batch-evaluate", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, engine_response([{"LowRisk", 0, []}]))
      end)

      claim_with_unknown_npi = %{
        "filename" => "unknown_npi.json",
        "claim" => %{
          "claim_id" => "CLM-UNKNOWN",
          "provider" => %{"name" => "Unknown Doc", "npi" => "9999999999", "state" => "MO"},
          "service_lines" => [
            %{
              "procedure_code" => "99213",
              "line_amount" => 150,
              "date_of_service" => "2026-01-15"
            }
          ],
          "2300" => %{"CLM" => %{"claim_amount" => 150}},
          "2400" => %{"SV1" => %{"place_of_service" => "11"}}
        }
      }

      batch = ingest_batch!([claim_with_unknown_npi])
      Evaluator.evaluate_batch(batch)

      files = Claims.list_files_for_batch(batch.id)
      file = hd(files)
      assert file.status == "fraudulent"

      nppes_result =
        Enum.find(file.json_output["results"], fn result ->
          result["resultRuleName"] == "NPPESProviderLookup"
        end)

      assert nppes_result
      assert nppes_result["resultDetails"] =~ "not found"
    end

    test "mixed batch: NPPES-rejected + engine-evaluated claims", %{bypass: bypass} do
      # Insert an unknown NPI scenario + a clean claim
      create_rule!(
        "value_rule",
        ~s|RULE value "Value check" WHEN 2300.CLM.claim_amount > 0 THEN REQUIRE_REVIEW "Review";|
      )

      Bypass.expect_once(bypass, "POST", "/api/batch-evaluate", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(body)
        assert length(payload["claims"]) == 2

        resp = engine_response([{"LowRisk", 0, []}, {"LowRisk", 0, []}])

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, resp)
      end)

      claims = [
        # This claim has unknown NPI — still engine-evaluated, but NPPES adds rejection finding
        %{
          "filename" => "bad_npi.json",
          "claim" => %{
            "claim_id" => "CLM-BAD",
            "provider" => %{"name" => "Unknown", "npi" => "0000000000", "state" => "MO"},
            "service_lines" => [
              %{
                "procedure_code" => "99213",
                "line_amount" => 100,
                "date_of_service" => "2026-01-15"
              }
            ],
            "2300" => %{"CLM" => %{"claim_amount" => 100}},
            "2400" => %{"SV1" => %{"place_of_service" => "11"}}
          }
        },
        # This claim has no NPI — passes NPPES and only has engine findings
        make_claim("clean.json", 200)
      ]

      batch = ingest_batch!(claims)
      Evaluator.evaluate_batch(batch)

      updated_batch = Claims.get_batch_by_batch_id(batch.batch_id)
      assert updated_batch.status == "completed"

      files = Claims.list_files_for_batch(batch.id)
      bad = Enum.find(files, &(&1.filename == "bad_npi.json"))
      clean = Enum.find(files, &(&1.filename == "clean.json"))

      assert bad.status == "fraudulent"
      assert clean.status == "evaluated"

      bad_nppes_result =
        Enum.find(bad.json_output["results"], fn result ->
          result["resultRuleName"] == "NPPESProviderLookup"
        end)

      assert bad_nppes_result

      refute Enum.any?(clean.json_output["results"] || [], fn result ->
               result["resultRuleName"] == "NPPESProviderLookup"
             end)
    end
  end

  # ---------------------------------------------------------------------------
  # Full pipeline tests using real X12 fixture claims
  #
  # These tests verify the complete ingest → normalize → evaluate → store path
  # for claims that previously failed due to schema mismatch.  Two things are
  # tested for each fixture:
  #   1. The payload sent to the Haskell engine is correctly normalized
  #      (i.e., the right fields are in the right places before evaluation).
  #   2. The end result is stored as "evaluated" / "LowRisk" (not "fraudulent").
  # ---------------------------------------------------------------------------

  describe "evaluate_batch/1 with real X12 fixture claims" do
    test "lab_work 837P — normalizes correctly and evaluates as LowRisk", %{bypass: bypass} do
      insert_active_nppes_provider("1003001850")

      create_rule!(
        "missing_required_fields",
        ~s|RULE missing_required_fields "Mandatory fields must be present" WHEN claim_id IS NULL OR provider.npi IS NULL OR patient.date_of_birth IS NULL OR financial.claim_amount IS NULL THEN REJECT "Missing required claim field";|
      )

      create_rule!(
        "missing_diagnosis_codes",
        ~s|RULE missing_diagnosis_codes "No diagnosis codes" WHEN COUNT(diagnosis_codes) = 0 THEN REJECT "No diagnosis codes present on claim";|
      )

      Bypass.expect_once(bypass, "POST", "/api/batch-evaluate", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(body)

        # Verify the normalized structure was sent — this is the core assertion:
        # the engine must receive business schema, not the raw X12 nested schema.
        assert length(payload["claims"]) == 1
        [claim] = payload["claims"]

        assert claim["claim_id"] == "CLM100002",
               "claim_id must be at top level, not nested under claim.claim_id"

        assert get_in(claim, ["provider", "npi"]) == "1003001850",
               "provider.npi must come from billing_provider.npi"

        assert get_in(claim, ["patient", "date_of_birth"]) == "19551108",
               "patient.date_of_birth must come from claim.subscriber.date_of_birth"

        assert get_in(claim, ["financial", "claim_amount"]) == 450.0,
               "financial.claim_amount must be a float parsed from total_charge_amount"

        assert length(claim["diagnosis_codes"]) == 2,
               "diagnosis_codes must be mapped from claim.diagnosis_codes"

        assert hd(claim["service_lines"])["date_of_service"] == "20260307",
               "service_line.date_of_service must be mapped from service_date"

        assert get_in(claim, ["billing_provider", "taxonomy"]) == "291U00000X",
               "billing_provider.taxonomy must be mapped from taxonomy_code key"

        resp = engine_response([{"LowRisk", 0, []}])

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, resp)
      end)

      normalized = SegmentMapper.normalize(@lab_work)
      batch = ingest_batch!([%{"filename" => "valid_837p_lab_work.json", "claim" => normalized}])

      Evaluator.evaluate_batch(batch)

      files = Claims.list_files_for_batch(batch.id)
      file = hd(files)

      assert file.status == "evaluated",
             "Lab work claim should be 'evaluated', not '#{file.status}' — MissingRequiredFields must not fire"

      assert file.json_output["overallRisk"] == "LowRisk"
      assert file.json_output["matchedRules"] == 0
    end

    test "preventive 837P — normalizes correctly and evaluates as LowRisk", %{bypass: bypass} do
      insert_active_nppes_provider("1003000118")

      create_rule!(
        "missing_required_fields",
        ~s|RULE missing_required_fields "Mandatory fields must be present" WHEN claim_id IS NULL OR provider.npi IS NULL OR patient.date_of_birth IS NULL OR financial.claim_amount IS NULL THEN REJECT "Missing required claim field";|
      )

      create_rule!(
        "missing_diagnosis_codes",
        ~s|RULE missing_diagnosis_codes "No diagnosis codes" WHEN COUNT(diagnosis_codes) = 0 THEN REJECT "No diagnosis codes present on claim";|
      )

      Bypass.expect_once(bypass, "POST", "/api/batch-evaluate", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(body)

        assert length(payload["claims"]) == 1
        [claim] = payload["claims"]

        assert claim["claim_id"] == "CLM100004"
        assert get_in(claim, ["provider", "npi"]) == "1003000118"
        assert get_in(claim, ["patient", "date_of_birth"]) == "20180905"
        assert get_in(claim, ["financial", "claim_amount"]) == 275.0
        assert length(claim["diagnosis_codes"]) == 1
        assert hd(claim["diagnosis_codes"])["code"] == "Z0000"
        assert length(claim["service_lines"]) == 3
        assert hd(claim["service_lines"])["date_of_service"] == "20260312"

        resp = engine_response([{"LowRisk", 0, []}])

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, resp)
      end)

      normalized = SegmentMapper.normalize(@preventive)
      batch = ingest_batch!([%{"filename" => "valid_837p_preventive.json", "claim" => normalized}])

      Evaluator.evaluate_batch(batch)

      files = Claims.list_files_for_batch(batch.id)
      file = hd(files)

      assert file.status == "evaluated",
             "Preventive claim should be 'evaluated', not '#{file.status}' — MissingRequiredFields must not fire"

      assert file.json_output["overallRisk"] == "LowRisk"
      assert file.json_output["matchedRules"] == 0
    end

    test "both real X12 claims in one batch are each evaluated correctly", %{bypass: bypass} do
      insert_active_nppes_provider("1003001850")
      insert_active_nppes_provider("1003000118")

      create_rule!(
        "missing_required_fields",
        ~s|RULE missing_required_fields "Mandatory fields must be present" WHEN claim_id IS NULL OR provider.npi IS NULL OR patient.date_of_birth IS NULL OR financial.claim_amount IS NULL THEN REJECT "Missing required claim field";|
      )

      Bypass.expect_once(bypass, "POST", "/api/batch-evaluate", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(body)

        assert length(payload["claims"]) == 2

        claim_ids = Enum.map(payload["claims"], & &1["claim_id"])
        assert "CLM100002" in claim_ids
        assert "CLM100004" in claim_ids

        # Both claims must have non-nil required fields
        Enum.each(payload["claims"], fn claim ->
          refute is_nil(claim["claim_id"])
          refute is_nil(get_in(claim, ["provider", "npi"]))
          refute is_nil(get_in(claim, ["patient", "date_of_birth"]))
          refute is_nil(get_in(claim, ["financial", "claim_amount"]))
        end)

        resp = engine_response([{"LowRisk", 0, []}, {"LowRisk", 0, []}])

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, resp)
      end)

      claims = [
        %{"filename" => "valid_837p_lab_work.json", "claim" => SegmentMapper.normalize(@lab_work)},
        %{
          "filename" => "valid_837p_preventive.json",
          "claim" => SegmentMapper.normalize(@preventive)
        }
      ]

      batch = ingest_batch!(claims)
      Evaluator.evaluate_batch(batch)

      files = Claims.list_files_for_batch(batch.id)
      assert length(files) == 2
      assert Enum.all?(files, &(&1.status == "evaluated"))
      assert Enum.all?(files, &(&1.json_output["overallRisk"] == "LowRisk"))
    end
  end

  describe "PubSub broadcasts" do
    test "broadcasts :batch_completed on success", %{bypass: bypass} do
      create_rule!(
        "pub_rule",
        ~s|RULE pub "Pub" WHEN 2300.CLM.claim_amount > 0 THEN REQUIRE_REVIEW "Review";|
      )

      Bypass.expect_once(bypass, "POST", "/api/batch-evaluate", fn conn ->
        resp = engine_response([{"LowRisk", 0, []}])

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, resp)
      end)

      Phoenix.PubSub.subscribe(MedicaidClaimsChecker.PubSub, Evaluator.topic())

      batch = ingest_batch!([make_claim("pub.json", 100)])
      Evaluator.evaluate_batch(batch)

      assert_receive {:batch_completed, %{batch_id: batch_id}}
      assert batch_id == batch.batch_id
    end

    test "broadcasts :batch_failed on engine error", %{bypass: bypass} do
      create_rule!(
        "fail_rule",
        ~s|RULE fail "Fail" WHEN 2300.CLM.claim_amount > 0 THEN REQUIRE_REVIEW "Review";|
      )

      Bypass.expect_once(bypass, "POST", "/api/batch-evaluate", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(500, ~s|{"error": "boom"}|)
      end)

      Phoenix.PubSub.subscribe(MedicaidClaimsChecker.PubSub, Evaluator.topic())

      batch = ingest_batch!([make_claim("fail.json", 100)])
      Evaluator.evaluate_batch(batch)

      assert_receive {:batch_failed, %{batch_id: batch_id}}
      assert batch_id == batch.batch_id
    end
  end
end
