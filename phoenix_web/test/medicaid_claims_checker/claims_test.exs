defmodule MedicaidClaimsChecker.ClaimsTest do
  use MedicaidClaimsChecker.DataCase

  alias MedicaidClaimsChecker.Claims
  alias MedicaidClaimsChecker.Claims.NppesProvider
  alias MedicaidClaimsChecker.Repo

  @valid_batch_params %{
    "batch_id" => "test-batch-001",
    "source" => "e2e-test",
    "claims" => [
      %{
        "filename" => "claim_clean.json",
        "claim" => %{
          "claim_id" => "CLM-001",
          "provider" => %{"name" => "Test Clinic", "state" => "MO"},
          "service_lines" => [
            %{
              "procedure_code" => "99213",
              "line_amount" => 150.00,
              "date_of_service" => "2026-01-15"
            }
          ],
          "claim_totals" => %{"total_submitted" => 150.00},
          "2300" => %{"CLM" => %{"claim_amount" => 150, "facility_type" => "Outpatient"}},
          "2400" => %{
            "SV1" => %{"place_of_service" => "11"},
            "DTP" => %{"service_day_of_week" => "TUE"}
          }
        }
      },
      %{
        "filename" => "claim_high_value.json",
        "claim" => %{
          "claim_id" => "CLM-002",
          "provider" => %{"name" => "Surgery Center", "state" => "CA"},
          "service_lines" => [
            %{
              "procedure_code" => "33533",
              "line_amount" => 75_000.00,
              "date_of_service" => "2026-01-15"
            }
          ],
          "claim_totals" => %{"total_submitted" => 75_000.00},
          "2300" => %{"CLM" => %{"claim_amount" => 75_000, "facility_type" => "Outpatient"}},
          "2400" => %{
            "SV1" => %{"place_of_service" => "11"},
            "DTP" => %{"service_day_of_week" => "TUE"}
          }
        }
      }
    ]
  }

  describe "ingest_batch/1" do
    test "creates batch and edi_files in a single transaction" do
      assert {:ok, %{batch: batch, edi_files: edi_files}} =
               Claims.ingest_batch(@valid_batch_params)

      assert batch.batch_id == "test-batch-001"
      assert batch.source == "e2e-test"
      assert batch.file_count == 2
      assert batch.status == "pending"
      assert batch.started_at != nil

      assert length(edi_files) == 2
      [f1, f2] = edi_files
      assert f1.filename == "claim_clean.json"
      assert f1.status == "translated"
      assert f1.file_path == "ingest://test-batch-001/claim_clean.json"
      assert f1.json_output["claim_id"] == "CLM-001"

      assert f2.filename == "claim_high_value.json"
      assert f2.batch_id == batch.id
    end

    test "rejects duplicate batch_id" do
      assert {:ok, _} = Claims.ingest_batch(@valid_batch_params)
      assert {:error, {:batch, _changeset}} = Claims.ingest_batch(@valid_batch_params)
    end

    test "rejects invalid payload (missing batch_id)" do
      assert {:error, :invalid_payload} = Claims.ingest_batch(%{"claims" => []})
    end

    test "rejects invalid payload (missing claims)" do
      assert {:error, :invalid_payload} = Claims.ingest_batch(%{"batch_id" => "x"})
    end

    test "generates default batch_name from source" do
      assert {:ok, %{batch: batch}} = Claims.ingest_batch(@valid_batch_params)
      assert batch.batch_name =~ "e2e-test -"
    end

    test "uses provided batch_name when given" do
      params = Map.put(@valid_batch_params, "batch_name", "My Custom Batch")
      assert {:ok, %{batch: batch}} = Claims.ingest_batch(params)
      assert batch.batch_name == "My Custom Batch"
    end
  end

  describe "batch_summary/1" do
    test "returns counts grouped by status" do
      {:ok, %{batch: batch}} = Claims.ingest_batch(@valid_batch_params)

      summary = Claims.batch_summary(batch.id)
      assert summary.total == 2
      assert summary.translated == 2
      assert summary.pending == 0
      assert summary.flagged_for_review == 0
    end

    test "reflects updated statuses" do
      {:ok, %{batch: batch, edi_files: [f1 | _]}} = Claims.ingest_batch(@valid_batch_params)

      Claims.update_edi_file_evaluation(f1, %{status: "evaluated"})

      summary = Claims.batch_summary(batch.id)
      assert summary.evaluated == 1
      assert summary.translated == 1
    end

    test "counts HighRisk and CriticalRisk reports as flagged for review" do
      {:ok, %{batch: batch, edi_files: [f1, f2]}} = Claims.ingest_batch(@valid_batch_params)

      Claims.update_edi_file_evaluation(f1, %{
        status: "evaluated",
        evaluation_report: %{"overallRisk" => "LowRisk"}
      })

      Claims.update_edi_file_evaluation(f2, %{
        status: "evaluated",
        evaluation_report: %{"overallRisk" => "CriticalRisk"}
      })

      summary = Claims.batch_summary(batch.id)
      assert summary.evaluated == 2
      assert summary.flagged_for_review == 1
    end
  end

  describe "edi_file status" do
    test "rejects \"fraudulent\": a fraud determination is an analyst's decision" do
      {:ok, %{edi_files: [f1 | _]}} = Claims.ingest_batch(@valid_batch_params)

      assert {:error, changeset} = Claims.update_edi_file_evaluation(f1, %{status: "fraudulent"})
      assert %{status: ["is invalid"]} = errors_on(changeset)
    end
  end

  describe "list_files_for_batch/1" do
    test "returns all files for a batch ordered by inserted_at" do
      {:ok, %{batch: batch}} = Claims.ingest_batch(@valid_batch_params)

      files = Claims.list_files_for_batch(batch.id)
      assert length(files) == 2
      assert Enum.map(files, & &1.filename) == ["claim_clean.json", "claim_high_value.json"]
    end
  end

  describe "list_errors_for_batch/1" do
    test "returns only files with syntax errors" do
      {:ok, %{batch: batch, edi_files: [f1, f2]}} = Claims.ingest_batch(@valid_batch_params)

      Claims.update_edi_file_evaluation(f1, %{status: "syntax_error"})

      Claims.update_edi_file_evaluation(f2, %{
        status: "evaluated",
        evaluation_report: %{"overallRisk" => "CriticalRisk"}
      })

      errors = Claims.list_errors_for_batch(batch.id)
      assert length(errors) == 1
      assert hd(errors).filename == "claim_clean.json"
    end

    test "returns empty list when no errors" do
      {:ok, %{batch: batch}} = Claims.ingest_batch(@valid_batch_params)
      assert Claims.list_errors_for_batch(batch.id) == []
    end
  end

  describe "get_batch_by_batch_id/1" do
    test "finds batch by external batch_id" do
      {:ok, %{batch: batch}} = Claims.ingest_batch(@valid_batch_params)

      found = Claims.get_batch_by_batch_id("test-batch-001")
      assert found.id == batch.id
    end

    test "returns nil for unknown batch_id" do
      assert Claims.get_batch_by_batch_id("nonexistent") == nil
    end
  end

  describe "validate_claim_providers/1" do
    test "returns :ok when no NPIs present" do
      claim = %{
        "provider" => %{"name" => "Test"},
        "service_lines" => [%{"date_of_service" => "2026-01-15"}]
      }

      assert :ok = Claims.validate_claim_providers(claim)
    end

    test "checks the rendering provider's NPI, not only the billing provider's" do
      Repo.insert!(%NppesProvider{
        npi: "1122334455",
        entity_type: 2,
        provider_name: "Billing Clinic"
      })

      Repo.insert!(%NppesProvider{
        npi: "1111111112",
        entity_type: 1,
        provider_name: "Deactivated Doctor",
        deactivation_date: ~D[2023-06-15]
      })

      claim = %{
        "provider" => %{"npi" => "1122334455"},
        "billing_provider" => %{"npi" => "1122334455"},
        "rendering_provider" => %{"npi" => "1111111112"},
        "service_lines" => [%{"date_of_service" => "20260901"}]
      }

      assert {:reject, "Provider NPI 1111111112 was deactivated" <> _} =
               Claims.validate_claim_providers(claim)

      assert :ok = Claims.validate_claim_providers(Map.delete(claim, "rendering_provider"))
    end

    test "ignores blank NPIs" do
      claim = %{
        "provider" => %{"npi" => ""},
        "billing_provider" => %{"npi" => "  "},
        "service_lines" => [%{"date_of_service" => "20260901"}]
      }

      assert :ok = Claims.validate_claim_providers(claim)
    end
  end
end
