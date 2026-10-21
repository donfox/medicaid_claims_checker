defmodule MedicaidClaimsCheckerWeb.UseCases.UUploadTest do
  @moduledoc """
  U1–U8: upload behaviour: several files at once, refused file types and
  sizes, and duplicate submissions.

  U5–U7 change a mock file in the test (a trailing newline, a doubled claim,
  a frequency code), so the difference from the original is visible here.
  """
  use MedicaidClaimsCheckerWeb.UseCaseCase

  alias MedicaidClaimsChecker.MockData

  @json "R_business_rules/R2_each_rule_alone/HighValueClaim.json"
  @x12 "X_x12_files/X1_837p_professional/clean_office_visit.x12"
  @zip "Z_zip_files/Z1_mixed_file_types/mixed_bundle.zip"
  @clean_json "R_business_rules/R1_clean_claim/office_visit.json"
  @already "Nothing was evaluated: every claim was already submitted."

  defp expected(files) do
    Enum.flat_map(files, fn f -> Enum.find(manifest(), &(&1["file"] == f))["expect"]["claims"] end)
  end

  @tag use_case: "U1"
  test "U1 a .json, an .x12 and a .zip in one upload: every claim is evaluated", %{conn: conn} do
    files = [@json, @x12, @zip]
    %{claims: claims} = upload(conn, files)
    want = expected(files)

    assert Enum.sort(Map.keys(claims)) == want |> Enum.map(& &1["claim_id"]) |> Enum.sort()
    Enum.each(want, &assert_claim(claims[&1["claim_id"]], &1))
  end

  @tag use_case: "U2"
  test "U2 an unsupported file type is refused before upload", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    input =
      file_input(view, "#manual-upload-form", :manual_files, [
        %{name: "notes.txt", content: "hello", type: "text/plain"}
      ])

    assert {:error, [[_ref, :not_accepted]]} = render_upload(input, "notes.txt")
  end

  @tag use_case: "U3"
  test "U3 a file over 10 MB is refused before upload", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    big = %{name: "big.json", content: :binary.copy(" ", 10_000_001), type: "application/json"}
    input = file_input(view, "#manual-upload-form", :manual_files, [big])

    assert {:error, [[_ref, :too_large]]} = render_upload(input, "big.json")
  end

  @tag use_case: "U4"
  test "U4 the same file uploaded twice: the second upload is refused", %{conn: conn} do
    %{claims: first} = upload(conn, [@x12])
    assert map_size(first) == 1

    %{claims: second, message: message} = upload(conn, [@x12])
    assert second == %{}
    assert message =~ @already
  end

  @tag use_case: "U5"
  test "U5 the same claim in a different file is refused", %{conn: conn} do
    upload(conn, [@x12])

    # Same claim, different file: one extra trailing newline.
    %{claims: second, message: message} =
      upload(conn, [{"office_visit_copy.x12", MockData.read!(@x12) <> "\n"}])

    assert second == %{}
    assert message =~ @already
  end

  @tag use_case: "U6"
  test "U6 the same claim twice in one file: only the first is evaluated", %{conn: conn} do
    claim = @clean_json |> MockData.read!() |> Jason.decode!()

    %{claims: claims, batches: [batch]} =
      upload(conn, [{"twice.json", Jason.encode!([claim, claim])}])

    assert Map.keys(claims) == [claim["claim_id"]]
    assert length(batch.duplicates) == 1
  end

  @tag use_case: "U7"
  test "U7 a replacement (frequency 7) or void (8) of a submitted claim is not a duplicate", %{
    conn: conn
  } do
    claim = @clean_json |> MockData.read!() |> Jason.decode!()
    upload(conn, [@clean_json])

    for code <- ["7", "8"] do
      changed = put_in(claim, [Access.key("claim_details", %{}), "frequency_code"], code)

      %{claims: claims, message: message} =
        upload(conn, [{"freq_#{code}.json", Jason.encode!(changed)}])

      refute message =~ @already, "frequency #{code} was refused as a duplicate"
      assert [%{status: "evaluated"}] = Map.values(claims)
    end
  end

  @tag use_case: "U8"
  test "U8 with \"Test upload: allow re-submission\" ticked, the same file is evaluated again", %{
    conn: conn
  } do
    Application.put_env(:medicaid_claims_checker, :allow_test_resubmission, true)
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "input[phx-click=toggle_allow_resubmission][checked]")

    %{claims: first} = upload_into(view, [@x12])
    %{claims: second, batches: [batch]} = upload_into(view, [@x12])

    assert Map.keys(second) == Map.keys(first)
    assert Enum.all?(Map.values(second), &(&1.status == "evaluated"))
    assert batch.batch_name =~ "(test re-submission)"
  end
end
