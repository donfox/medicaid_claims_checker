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

  describe "ingest_batch/1 duplicate submissions" do
    defp claim_entry(filename, claim, source_file \\ nil) do
      entry = %{"filename" => filename, "claim" => claim}
      if source_file, do: Map.put(entry, "source_file", source_file), else: entry
    end

    defp x12_claim(claim_id, opts \\ []) do
      %{
        "claim_id" => claim_id,
        "claim_details" => %{"place_of_service" => "11", "frequency_code" => Keyword.get(opts, :frequency, "1")},
        "financial" => %{"claim_amount" => 150.0},
        "interchange" => %{"control_number" => Keyword.get(opts, :control, "000000001"), "date" => "261017"}
      }
    end

    defp ingest(batch_id, entries, name \\ nil) do
      params = %{"batch_id" => batch_id, "source" => "manual_upload", "claims" => entries}
      Claims.ingest_batch(if name, do: Map.put(params, "batch_name", name), else: params)
    end

    test "refuses a claim already in an earlier batch and names that batch" do
      {:ok, _} = ingest("dup-1", [claim_entry("a.json", x12_claim("CLM-9"))], "First Upload")

      assert {:ok, %{batch: batch, edi_files: [], duplicates: [dup]}} =
               ingest("dup-2", [claim_entry("a_again.json", x12_claim("CLM-9"))])

      assert batch.status == "failed"
      assert batch.file_count == 0
      assert batch.completed_at != nil
      assert dup["kind"] == "claim"
      assert dup["claim_id"] == "CLM-9"
      assert dup["previous_batch_id"] == "dup-1"
      assert dup["previous_filename"] == "a.json"
      assert Claims.describe_duplicate(dup) =~ ~s(claim CLM-9 (a_again.json\) was already submitted in "First Upload" on )
      assert [%{"previous_batch_name" => "First Upload"}] = Claims.get_batch_by_batch_id("dup-2").duplicates
    end

    test "refuses the same claim re-sent in a new X12 envelope" do
      {:ok, _} = ingest("env-1", [claim_entry("a.json", x12_claim("CLM-9", control: "000000001"))])

      assert {:ok, %{edi_files: [], duplicates: [%{"previous_batch_id" => "env-1"}]}} =
               ingest("env-2", [claim_entry("a.json", x12_claim("CLM-9", control: "000000777"))])
    end

    test "accepts a void or replacement of an earlier claim" do
      {:ok, _} = ingest("void-1", [claim_entry("a.json", x12_claim("CLM-9"))])

      assert {:ok, %{edi_files: [_], duplicates: []}} =
               ingest("void-2", [claim_entry("a_void.json", x12_claim("CLM-9", frequency: "8"))])

      assert {:ok, %{edi_files: [_], duplicates: []}} =
               ingest("void-3", [claim_entry("a_repl.json", x12_claim("CLM-9", frequency: "7"))])
    end

    test "refuses a re-submitted file once, however many claims it holds" do
      source = %{"filename" => "daily.x12", "sha256" => String.duplicate("ab", 32)}

      {:ok, _} =
        ingest("file-1", [
          claim_entry("daily_C1.json", x12_claim("C1"), source),
          claim_entry("daily_C2.json", x12_claim("C2"), source)
        ])

      # Claims edited after the first submission still come from the same file bytes.
      assert {:ok, %{edi_files: [], duplicates: [dup]}} =
               ingest("file-2", [
                 claim_entry("daily_C1.json", x12_claim("C1-x"), source),
                 claim_entry("daily_C2.json", x12_claim("C2-x"), source)
               ])

      assert dup["kind"] == "file"
      assert dup["filename"] == "daily.x12"
      assert dup["previous_batch_id"] == "file-1"
      assert Claims.describe_duplicate(dup) =~ "daily.x12 was already submitted in"
    end

    test "evaluates the new claims and refuses only the duplicates" do
      {:ok, _} = ingest("part-1", [claim_entry("old.json", x12_claim("OLD"))])

      assert {:ok, %{batch: batch, edi_files: [new_file], duplicates: [%{"claim_id" => "OLD"}]}} =
               ingest("part-2", [
                 claim_entry("old.json", x12_claim("OLD")),
                 claim_entry("new.json", x12_claim("NEW"))
               ])

      assert new_file.json_output["claim_id"] == "NEW"
      assert new_file.claim_fingerprint != nil
      assert batch.file_count == 1
      assert batch.status == "pending"
    end

    test "refuses a claim repeated within one submission" do
      assert {:ok, %{edi_files: [first], duplicates: [dup]}} =
               ingest("same-1", [
                 claim_entry("a.json", x12_claim("CLM-9")),
                 claim_entry("b.json", x12_claim("CLM-9"))
               ])

      assert first.filename == "a.json"
      assert dup["previous_batch_id"] == nil
      assert Claims.describe_duplicate(dup) == "claim CLM-9 (b.json) appears twice in this submission (first as a.json)"
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

    test "checks every service line's date, not only the earliest" do
      Repo.insert!(%NppesProvider{
        npi: "1111111112",
        entity_type: 1,
        provider_name: "Deactivated Doctor",
        deactivation_date: ~D[2026-03-15]
      })

      claim = %{
        "billing_provider" => %{"npi" => "1111111112"},
        "service_lines" => [%{"date_of_service" => "2026-03-10"}, %{"date_of_service" => "2026-03-20"}]
      }

      assert {:reject, "Provider NPI 1111111112 was deactivated on 2026-03-15, service rendered on 2026-03-20"} =
               Claims.validate_claim_providers(claim)

      assert :ok = Claims.validate_claim_providers(%{claim | "service_lines" => [%{"date_of_service" => "2026-03-10"}]})
    end

    test "rejects a service dated before the NPI was issued" do
      Repo.insert!(%NppesProvider{npi: "1122334455", entity_type: 2, provider_name: "New Lab", enumeration_date: ~D[2018-04-02]})

      claim = %{
        "billing_provider" => %{"npi" => "1122334455"},
        "service_lines" => [%{"date_of_service" => "20180315"}]
      }

      assert {:reject, "Provider NPI 1122334455 was not issued until 2018-04-02, service rendered on 2018-03-15"} =
               Claims.validate_claim_providers(claim)
    end

    test "a late claim for an NPI later dropped from NPPES is checked on its last record" do
      Repo.insert!(%NppesProvider{npi: "1093462368", entity_type: 1, provider_name: "Dropped, Dr", dropped_on: ~D[2026-10-17]})

      before_drop = %{
        "billing_provider" => %{"npi" => "1093462368"},
        "service_lines" => [%{"date_of_service" => "2026-03-10"}]
      }

      assert :ok = Claims.validate_claim_providers(before_drop)

      assert {:reject, "Provider NPI 1093462368 has not been in the NPPES file since 2026-10-17, service rendered on 2026-10-18"} =
               Claims.validate_claim_providers(%{before_drop | "service_lines" => [%{"date_of_service" => "2026-10-18"}]})
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
