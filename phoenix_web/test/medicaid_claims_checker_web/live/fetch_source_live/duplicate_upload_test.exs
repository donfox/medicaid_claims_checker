defmodule MedicaidClaimsCheckerWeb.FetchSourceLive.DuplicateUploadTest do
  @moduledoc "Re-submitting real X12 files through the upload form."
  use MedicaidClaimsCheckerWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias MedicaidClaimsChecker.AccountsFixtures
  alias MedicaidClaimsChecker.Claims
  alias MedicaidClaimsChecker.Claims.{Batch, EdiFile}
  alias MedicaidClaimsChecker.Repo

  @three_claims Path.expand("../../../fixtures/x12_suite/files/multi/01_three_claims.x12", __DIR__)

  setup %{conn: conn} do
    user = AccountsFixtures.unconfirmed_user_fixture()
    %{conn: log_in_user(conn, user)}
  end

  defp upload(conn, name, content) do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> file_input("#manual-upload-form", :manual_files, [%{name: name, content: content, type: "text/plain"}])
    |> render_upload(name)

    view |> form("#manual-upload-form") |> render_submit()

    # A fully refused upload broadcasts :batch_failed back to this view;
    # render again so it is handled before the test (and its DB owner) exits.
    render(view)
  end

  defp batches, do: Repo.all(from(b in Batch, order_by: b.id))

  # Uploads the same file twice and returns the view showing the refusal.
  defp refused_view(conn) do
    content = File.read!(@three_claims)
    upload(conn, "01_three_claims.x12", content)
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> file_input("#manual-upload-form", :manual_files, [%{name: "again.x12", content: content, type: "text/plain"}])
    |> render_upload("again.x12")

    view |> form("#manual-upload-form") |> render_submit()
    assert render(view) =~ "Nothing was evaluated: every claim was already submitted."
    assert has_element?(view, "#dismiss-upload-message")
    view
  end

  describe "the refusal message can be cleared" do
    test "by its dismiss button", %{conn: conn} do
      view = refused_view(conn)
      view |> element("#dismiss-upload-message") |> render_click()
      refute has_element?(view, "#dismiss-upload-message")
    end

    test "by Clear display", %{conn: conn} do
      view = refused_view(conn)
      unless has_element?(view, "#clear-history-display") do
        view |> element("button[aria-controls=batch-history-panel]") |> render_click()
      end

      view |> element("#clear-history-display") |> render_click()
      refute has_element?(view, "#dismiss-upload-message")
    end

    test "by choosing new files", %{conn: conn} do
      view = refused_view(conn)
      view |> form("#manual-upload-form") |> render_change()
      refute has_element?(view, "#dismiss-upload-message")
    end
  end

  test "the same file uploaded again is refused and names the first upload", %{conn: conn} do
    content = File.read!(@three_claims)

    assert upload(conn, "01_three_claims.x12", content) =~ "3 X12/EDI claim(s) translated"
    html = upload(conn, "daily_copy.x12", content)

    assert html =~ "Nothing was evaluated: every claim was already submitted."
    assert html =~ "daily_copy.x12 was already submitted in &quot;Manual Upload - "

    [first, second] = batches()
    assert second.status == "failed"
    assert second.file_count == 0
    assert [%{"kind" => "file", "previous_batch_id" => id}] = second.duplicates
    assert id == first.batch_id
    assert Repo.aggregate(EdiFile, :count) == 3
  end

  test "the same claims in a new interchange envelope are refused claim by claim", %{conn: conn} do
    content = File.read!(@three_claims)
    upload(conn, "01_three_claims.x12", content)

    resent =
      content
      |> String.replace("*000000101*0*T*", "*000000909*0*T*")
      |> String.replace("IEA*1*000000101", "IEA*1*000000909")
      |> String.replace("*261016*1200*^", "*261018*0900*^")

    html = upload(conn, "01_three_claims_resent.x12", resent)

    assert html =~ "Nothing was evaluated: every claim was already submitted."
    assert html =~ "was already submitted in"

    [_first, second] = batches()
    assert length(second.duplicates) == 3
    assert Enum.all?(second.duplicates, &(&1["kind"] == "claim"))
    assert Enum.all?(second.duplicates, &(Claims.describe_duplicate(&1) =~ "01_three_claims_"))
  end

  test "a void of an uploaded claim is accepted", %{conn: conn} do
    content = File.read!(@three_claims)
    upload(conn, "01_three_claims.x12", content)

    # CLM05-3 frequency code 1 (original) -> 8 (void), in a new envelope.
    voided =
      content
      |> String.replace(~r/(CLM\*[^*~]*\*[^*~]*\*\*\*\d+:B:)1/, "\\g{1}8")
      |> String.replace("*000000101*0*T*", "*000000910*0*T*")
      |> String.replace("IEA*1*000000101", "IEA*1*000000910")

    assert voided != content
    assert upload(conn, "01_three_claims_void.x12", voided) =~ "3 X12/EDI claim(s) translated"

    frequency_codes =
      Repo.all(from(f in EdiFile, order_by: f.id, select: f.json_output["claim_details"]["frequency_code"]))

    assert frequency_codes == ["1", "1", "1", "8", "8", "8"]
  end

  describe "retag_test_data.exs copies" do
    @retag Path.expand("../../../scripts/retag_test_data.exs", __DIR__)
    @office_visit Path.expand("../../../../../mock_data/claims/clean/office_visit.json", __DIR__)

    @tag :tmp_dir
    test "are accepted after the originals, X12 and JSON alike", %{conn: conn, tmp_dir: tmp_dir} do
      {_, 0} = System.cmd("elixir", [@retag, "--tag", "2", "--out", tmp_dir, @three_claims, @office_visit])
      x12 = File.read!(@three_claims)
      json = File.read!(@office_visit)

      assert upload(conn, "01_three_claims.x12", x12) =~ "3 X12/EDI claim(s) translated"
      assert upload(conn, "office_visit.json", json) =~ "1 JSON claim(s) submitted"
      assert upload(conn, "01_three_claims.x12", x12) =~ "Nothing was evaluated"
      assert upload(conn, "office_visit.json", json) =~ "Nothing was evaluated"

      assert upload(conn, "01_three_claims.x12", File.read!(Path.join(tmp_dir, "01_three_claims.x12"))) =~
               "3 X12/EDI claim(s) translated"

      assert upload(conn, "office_visit.json", File.read!(Path.join(tmp_dir, "office_visit.json"))) =~
               "1 JSON claim(s) submitted"

      ids = Repo.all(from(f in EdiFile, order_by: f.id, select: f.json_output["claim_id"]))
      assert ids == ~w(MULTI01 MULTI02 MULTI03 SMP-CLEAN-001 MULTI01-2 MULTI02-2 MULTI03-2 SMP-CLEAN-001-2)
    end
  end
end
