defmodule MedicaidClaimsChecker.DuplicateAlertTest do
  @moduledoc "Admin email alerts for refused duplicates, and fetch sources skipping files they already fetched."
  use MedicaidClaimsChecker.DataCase, async: true

  import Swoosh.TestAssertions

  alias MedicaidClaimsChecker.{Accounts, AccountsFixtures, Claims, Ingestion}
  alias MedicaidClaimsChecker.Claims.Batch
  alias MedicaidClaimsChecker.Ingestion.FetchRunner

  @three_claims MedicaidClaimsChecker.MockData.path(
                  "X_x12_files/X4_several_claims_one_transaction_set/three_claims.x12"
                )

  defp admin(attrs \\ %{}) do
    {:ok, user} =
      attrs |> AccountsFixtures.user_fixture() |> Accounts.set_user_admin(true)

    user
  end

  defp claim(id),
    do: %{
      "filename" => "#{id}.json",
      "claim" => %{"claim_id" => id, "financial" => %{"claim_amount" => 100}}
    }

  defp ingest(batch_id, claims),
    do:
      Claims.ingest_batch(%{"batch_id" => batch_id, "batch_name" => batch_id, "claims" => claims})

  defp batches, do: Repo.all(from(b in Batch, order_by: b.id))

  describe "duplicate alert email" do
    test "goes to active admins only, naming each refusal and the earlier batch" do
      first = admin()
      second = admin()
      {:ok, inactive} = admin() |> Accounts.set_user_active(false)
      plain = AccountsFixtures.user_fixture()

      {:ok, _} = ingest("first", [claim("CLM-1"), claim("CLM-2")])
      refute_email_sent()

      {:ok, _} = ingest("second", [claim("CLM-1"), claim("CLM-3")])

      assert_email_sent(fn email ->
        recipients = Enum.map(email.to, &elem(&1, 1))
        assert Enum.sort(recipients) == Enum.sort([first.email, second.email])
        refute inactive.email in recipients
        refute plain.email in recipients
        assert email.subject == "Duplicate submission refused: second"
        assert email.text_body =~ "1 duplicate submission was refused and not evaluated again."
        assert email.text_body =~ "Claims evaluated from this batch: 1"
        assert email.text_body =~ ~s(claim CLM-1 (CLM-1.json\) was already submitted in "first")
      end)
    end

    test "says nothing was evaluated when every claim was refused" do
      admin()
      {:ok, _} = ingest("first", [claim("CLM-1")])
      {:ok, _} = ingest("again", [claim("CLM-1")])

      assert_email_sent(fn email ->
        assert email.text_body =~
                 "Claims evaluated from this batch: none (every claim was already submitted)"
      end)
    end

    test "is not sent when there are no admins, and the page record is kept" do
      {:ok, _} = ingest("first", [claim("CLM-1")])
      {:ok, %{batch: batch}} = ingest("again", [claim("CLM-1")])

      refute_email_sent()
      assert [%{"kind" => "claim"}] = batch.duplicates
    end
  end

  describe "scheduled fetch" do
    setup do
      dir =
        Path.join(System.tmp_dir!(), "fetch_runner_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      {:ok, source} =
        Ingestion.create_fetch_source(%{name: "folder #{dir}", uri: dir, source_type: "local"})

      %{dir: dir, source: Map.take(source, [:id, :name, :uri, :source_type])}
    end

    test "skips files it already fetched, without a batch or an alert", %{
      dir: dir,
      source: source
    } do
      admin()
      File.cp!(@three_claims, Path.join(dir, "daily.x12"))

      assert {:ok, %{edi_files: [_, _, _]}} = FetchRunner.run(source)
      assert {:ok, :nothing_new} = FetchRunner.run(source)
      assert {:ok, :nothing_new} = FetchRunner.run(source)

      assert length(batches()) == 1
      refute_email_sent()
    end

    test "still refuses and alerts on the same claims in a new file", %{dir: dir, source: source} do
      admin()
      File.cp!(@three_claims, Path.join(dir, "daily.x12"))
      {:ok, _} = FetchRunner.run(source)

      File.cp!(@three_claims, Path.join(dir, "daily_resent.x12"))
      assert {:ok, %{edi_files: [], duplicates: [%{"kind" => "file"}]}} = FetchRunner.run(source)

      assert_email_sent(fn email ->
        assert email.text_body =~ "daily_resent.x12 was already submitted in"
      end)

      assert {:ok, :nothing_new} = FetchRunner.run(source)
      refute_email_sent()
    end

    test "fetches a file again when its content changes", %{dir: dir, source: source} do
      path = Path.join(dir, "daily.x12")
      File.cp!(@three_claims, path)
      {:ok, _} = FetchRunner.run(source)

      File.write!(
        path,
        String.replace(File.read!(@three_claims), "CLM*MULTI01*", "CLM*MULTI01B*")
      )

      assert {:ok, %{edi_files: [_], duplicates: [_, _]}} = FetchRunner.run(source)
    end

    test "a file with no claims is recorded, so it isn't re-read every run", %{
      dir: dir,
      source: source
    } do
      File.write!(Path.join(dir, "junk.x12"), "not an x12 file")

      assert {:error, :no_claims_produced} = FetchRunner.run(source)
      assert {:ok, :nothing_new} = FetchRunner.run(source)
    end
  end
end
