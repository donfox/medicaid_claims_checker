defmodule MedicaidClaimsCheckerWeb.FetchSourceLive.TestResubmissionTest do
  @moduledoc "The development-only \"Test upload: allow re-submission\" checkbox."
  # Not async: the tests change the :allow_test_resubmission setting.
  use MedicaidClaimsCheckerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions

  alias MedicaidClaimsChecker.{Accounts, AccountsFixtures, Claims, MockData, Repo}
  alias MedicaidClaimsChecker.Claims.Batch

  @three_claims MockData.path(
                  "X_x12_files/X4_several_claims_one_transaction_set/three_claims.x12"
                )

  # Alert emails are sent from the LiveView process (Oban runs inline in
  # tests); deliver them to the test process instead.
  setup :set_swoosh_global

  setup %{conn: conn} do
    {:ok, _} = AccountsFixtures.unconfirmed_user_fixture() |> Accounts.set_user_admin(true)
    user = AccountsFixtures.unconfirmed_user_fixture()
    on_exit(fn -> Application.delete_env(:medicaid_claims_checker, :allow_test_resubmission) end)
    %{conn: log_in_user(conn, user)}
  end

  defp allow(on), do: Application.put_env(:medicaid_claims_checker, :allow_test_resubmission, on)

  defp upload(view, name, content) do
    view
    |> file_input("#manual-upload-form", :manual_files, [
      %{name: name, content: content, type: "text/plain"}
    ])
    |> render_upload(name)

    view |> form("#manual-upload-form") |> render_submit()
    render(view)
  end

  defp batches, do: Repo.all(from(b in Batch, order_by: b.id))

  test "the checkbox is not shown unless the setting is on", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    refute has_element?(view, "#allow-resubmission")
  end

  test "ticked (the default), the same file is evaluated every time", %{conn: conn} do
    allow(true)
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#allow-resubmission[checked]")
    content = File.read!(@three_claims)

    for _ <- 1..3,
        do: assert(upload(view, "three_claims.x12", content) =~ "3 X12/EDI claim(s) translated")

    assert Enum.map(batches(), & &1.duplicates) == [[], [], []]
    assert Enum.all?(batches(), &(&1.batch_name =~ "(test re-submission)"))
    refute_email_sent()
  end

  test "unticked, the duplicate check works as in production", %{conn: conn} do
    allow(true)
    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("#allow-resubmission") |> render_click()
    refute has_element?(view, "#allow-resubmission[checked]")
    content = File.read!(@three_claims)

    assert upload(view, "three_claims.x12", content) =~ "3 X12/EDI claim(s) translated"

    assert upload(view, "three_claims.x12", content) =~
             "Nothing was evaluated: every claim was already submitted."

    assert_email_sent()
  end

  test "without the setting, a request to re-submit is ignored" do
    claim = %{"filename" => "a.json", "claim" => %{"claim_id" => "CLM-1"}}
    {:ok, _} = Claims.ingest_batch(%{"batch_id" => "one", "claims" => [claim]})

    assert {:ok, %{edi_files: [], duplicates: [_]}} =
             Claims.ingest_batch(%{
               "batch_id" => "two",
               "claims" => [claim],
               "allow_resubmission" => true
             })
  end
end
