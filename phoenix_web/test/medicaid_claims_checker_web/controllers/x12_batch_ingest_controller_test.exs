defmodule MedicaidClaimsCheckerWeb.X12BatchIngestControllerTest do
  use MedicaidClaimsCheckerWeb.ConnCase

  @valid_payload %{
    "batch_id" => "ctrl-test-001",
    "source" => "controller-test",
    "claims" => [
      %{
        "filename" => "claim_a.json",
        "claim" => %{
          "claim_id" => "CLM-A",
          "2300" => %{"CLM" => %{"claim_amount" => 500}},
          "2400" => %{"SV1" => %{"place_of_service" => "11"}}
        }
      },
      %{
        "filename" => "claim_b.json",
        "claim" => %{
          "claim_id" => "CLM-B",
          "2300" => %{"CLM" => %{"claim_amount" => 100_000}},
          "2400" => %{"SV1" => %{"place_of_service" => "22"}}
        }
      }
    ]
  }

  describe "POST /api/x12-batch-ingest" do
    test "returns 201 and accepted status on valid payload", %{conn: conn} do
      conn = post(conn, "/api/x12-batch-ingest", @valid_payload)

      assert %{
               "status" => "accepted",
               "batch_id" => "ctrl-test-001",
               "source" => "controller-test",
               "claims_ingested" => 2
             } = json_response(conn, 201)
    end

    test "returns batch_db_id in response", %{conn: conn} do
      conn = post(conn, "/api/x12-batch-ingest", @valid_payload)
      resp = json_response(conn, 201)

      assert is_integer(resp["batch_db_id"])
    end

    test "returns 422 on duplicate batch_id", %{conn: conn} do
      post(conn, "/api/x12-batch-ingest", @valid_payload)
      conn2 = post(conn, "/api/x12-batch-ingest", @valid_payload)

      assert json_response(conn2, 422)["error"] =~ "failed"
    end

    test "returns 400 on missing batch_id", %{conn: conn} do
      conn = post(conn, "/api/x12-batch-ingest", %{"claims" => []})
      assert json_response(conn, 400)["error"] =~ "Invalid payload"
    end

    test "returns 400 on missing claims", %{conn: conn} do
      conn = post(conn, "/api/x12-batch-ingest", %{"batch_id" => "x"})
      assert json_response(conn, 400)["error"] =~ "Invalid payload"
    end

    test "returns 400 on empty payload", %{conn: conn} do
      conn = post(conn, "/api/x12-batch-ingest", %{})
      assert json_response(conn, 400)["error"] =~ "Invalid payload"
    end
  end

  describe "GET /api/x12-batch-ingest/:batch_id" do
    test "returns batch details after ingest", %{conn: conn} do
      # Ingest first
      post(conn, "/api/x12-batch-ingest", @valid_payload)

      conn2 = get(conn, "/api/x12-batch-ingest/ctrl-test-001")
      resp = json_response(conn2, 200)

      assert resp["batch_id"] == "ctrl-test-001"
      assert resp["status"] == "pending"
      assert resp["file_count"] == 2
      assert length(resp["files"]) == 2

      filenames = Enum.map(resp["files"], & &1["filename"])
      assert "claim_a.json" in filenames
      assert "claim_b.json" in filenames
    end

    test "returns summary counts", %{conn: conn} do
      post(conn, "/api/x12-batch-ingest", @valid_payload)

      conn2 = get(conn, "/api/x12-batch-ingest/ctrl-test-001")
      resp = json_response(conn2, 200)

      assert resp["summary"]["total"] == 2
      assert resp["summary"]["translated"] == 2
    end

    test "returns 404 for unknown batch_id", %{conn: conn} do
      conn = get(conn, "/api/x12-batch-ingest/nonexistent")
      assert json_response(conn, 404)["error"] =~ "not found"
    end
  end
end
