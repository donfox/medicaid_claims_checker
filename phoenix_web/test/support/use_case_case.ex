defmodule MedicaidClaimsCheckerWeb.UseCaseCase do
  @moduledoc """
  Test case for the frontend use-case tests in `test/use_cases/`.

  Each test uses the app as a person would: it uploads mock data files on
  the home page (or enters rules on the Rules page), and the real Haskell
  engine evaluates them against the 17 seeded business rules. Expected
  results come from `mock_data/manifest.json`.

  Every test is tagged with its use-case ID (`use_case: "R5"`) and the whole
  set is excluded from a plain `mix test`, because it needs the engine
  running. `./test.sh` at the repo root starts one and runs them:

      ./test.sh          # every use case
      ./test.sh R5       # one use case

  Setup per test (all inside the test's database sandbox):

    * runs `priv/repo/seeds.exs`, so the business rules are the seeded ones
    * loads `mock_data/nppes_extract.json`, the registry rows for every NPI
      the mock data uses
    * points the app at the engine (RULE_ENGINE_URL, RULE_ENGINE_SECRET)
      and turns on evaluation after upload, which plain tests skip
    * logs in a user
  """

  use ExUnit.CaseTemplate

  import Ecto.Query
  import Phoenix.ConnTest, only: [get: 2]
  import Phoenix.LiveViewTest
  import ExUnit.Assertions

  alias MedicaidClaimsChecker.{AccountsFixtures, Claims, MockData, Repo}
  alias MedicaidClaimsChecker.Claims.{Batch, BusinessRule, NppesProvider}

  @endpoint MedicaidClaimsCheckerWeb.Endpoint

  using do
    quote do
      @endpoint MedicaidClaimsCheckerWeb.Endpoint
      use MedicaidClaimsCheckerWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import MedicaidClaimsCheckerWeb.UseCaseCase

      @moduletag :use_case
    end
  end

  setup tags do
    MedicaidClaimsChecker.DataCase.setup_sandbox(Map.put(tags, :async, false))
    previous = Application.get_all_env(:medicaid_claims_checker) |> Keyword.take(env_keys())

    Application.put_env(
      :medicaid_claims_checker,
      :rule_engine_url,
      System.get_env("RULE_ENGINE_URL") || "http://localhost:8080"
    )

    Application.put_env(
      :medicaid_claims_checker,
      :rule_engine_secret,
      System.get_env("RULE_ENGINE_SECRET") || "dev-secret-change-in-production"
    )

    Application.put_env(:medicaid_claims_checker, :skip_async_evaluation, false)

    on_exit(fn ->
      Enum.each(env_keys(), &Application.delete_env(:medicaid_claims_checker, &1))
      Enum.each(previous, fn {k, v} -> Application.put_env(:medicaid_claims_checker, k, v) end)
    end)

    ExUnit.CaptureIO.capture_io(fn -> Code.eval_file(seeds_path()) end)
    load_nppes_extract()

    user = AccountsFixtures.user_fixture()
    %{conn: MedicaidClaimsCheckerWeb.ConnCase.log_in_user(Phoenix.ConnTest.build_conn(), user)}
  end

  defp env_keys,
    do: [:rule_engine_url, :rule_engine_secret, :skip_async_evaluation, :allow_test_resubmission]

  defp seeds_path, do: Path.expand("../../priv/repo/seeds.exs", __DIR__)

  defp load_nppes_extract do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    date = fn
      nil -> nil
      s -> Date.from_iso8601!(s)
    end

    rows =
      MockData.read!("nppes_extract.json")
      |> Jason.decode!()
      |> Map.fetch!("providers")
      |> Enum.map(fn p ->
        %{
          npi: p["npi"],
          entity_type: p["entity_type"],
          provider_name: p["provider_name"],
          credential: p["credential"],
          taxonomy: p["taxonomy"],
          state: p["state"],
          enumeration_date: date.(p["enumeration_date"]),
          deactivation_date: date.(p["deactivation_date"]),
          reactivation_date: date.(p["reactivation_date"]),
          last_update_date: date.(p["last_update_date"]),
          dropped_on: date.(p["dropped_on"]),
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(NppesProvider, rows)
  end

  # --- manifest.json ---

  @manifest MockData.read!("manifest.json") |> Jason.decode!() |> Map.fetch!("cases")

  @doc "The manifest cases whose use-case ID (from the folder name) is in `ids`."
  def manifest_cases(ids) do
    Enum.filter(@manifest, &(use_case_id(&1["file"]) in List.wrap(ids)))
  end

  @doc ~S|The use-case ID of a mock_data path: "R_business_rules/R5_exact_thresholds/x.x12" -> "R5".|
  def use_case_id(rel_path) do
    rel_path
    |> Path.split()
    |> Enum.find_value(fn part ->
      case Regex.run(~r/^([A-Z]\d+)_/, part) do
        [_, id] -> id
        _ -> nil
      end
    end)
  end

  @doc """
  Defines one test per manifest case for the given use-case IDs. Each test
  uploads the case's file and checks the outcome against its `expect`.
  """
  defmacro manifest_tests(ids) do
    quote bind_quoted: [ids: ids] do
      for c <- MedicaidClaimsCheckerWeb.UseCaseCase.manifest_cases(ids) do
        @tag use_case: MedicaidClaimsCheckerWeb.UseCaseCase.use_case_id(c["file"])
        @tag manifest_case: c
        test "#{MedicaidClaimsCheckerWeb.UseCaseCase.use_case_id(c["file"])} #{Path.basename(c["file"])}: #{c["purpose"]}",
             %{conn: conn, manifest_case: c} do
          MedicaidClaimsCheckerWeb.UseCaseCase.check_manifest_case(conn, c)
        end
      end
    end
  end

  @doc """
  Like `manifest_tests/1`, for a use case without its own folder: runs the
  manifest cases of `files` (mock_data paths) under the ID `id`.
  """
  defmacro manifest_tests_as(id, files) do
    quote bind_quoted: [id: id, files: files] do
      for file <- files,
          c = Enum.find(MedicaidClaimsCheckerWeb.UseCaseCase.manifest(), &(&1["file"] == file)) do
        @tag use_case: id
        @tag manifest_case: c
        test "#{id} #{Path.basename(file)}: #{c["purpose"]}", %{conn: conn, manifest_case: c} do
          MedicaidClaimsCheckerWeb.UseCaseCase.check_manifest_case(conn, c)
        end
      end
    end
  end

  @doc "Every manifest case."
  def manifest, do: @manifest

  @doc "Uploads a manifest case's file and asserts its expected outcome."
  def check_manifest_case(conn, c) do
    if rules_file = c["rules"], do: use_rules_file(rules_file)

    %{view: view, claims: claims} = upload(conn, [c["file"]])
    expect = c["expect"]

    if err = expect["error"] do
      assert claims == %{}, "expected no claims, got #{inspect(Map.keys(claims))}"
      message = upload_message(view)

      assert String.contains?(String.downcase(message), String.downcase(err)),
             "expected the upload message to mention #{inspect(err)}; it was: #{inspect(message)}"
    else
      want_ids = expect["claims"] |> Enum.map(& &1["claim_id"]) |> Enum.sort()
      assert Enum.sort(Map.keys(claims)) == want_ids

      Enum.each(
        expect["claims"],
        &assert_claim(claims[&1["claim_id"]], &1, strict: is_nil(c["rules"]))
      )
    end
  end

  @doc """
  Checks one evaluated claim against a manifest claim expectation.
  `strict: true` (database rules) also fails on rules unexpectedly "not
  checked"; a rules file may test fields a claim lacks.
  """
  def assert_claim(got, exp, opts \\ []) do
    id = exp["claim_id"]
    assert got, "#{id}: no claim produced"
    assert got.status == "evaluated", "#{id}: status #{got.status}, expected evaluated"

    active = active_rule_names()
    want = exp["matched"] |> Enum.filter(&(&1 in active)) |> MapSet.new()
    want_nc = (exp["not_checked"] || []) |> Enum.filter(&(&1 in active)) |> MapSet.new()

    assert got.matched == want,
           "#{id}: matched #{inspect(Enum.sort(got.matched))}, expected #{inspect(Enum.sort(want))}"

    missing = MapSet.difference(want_nc, got.not_checked)

    assert MapSet.size(missing) == 0,
           "#{id}: expected not checked: #{inspect(Enum.sort(missing))}"

    if Keyword.get(opts, :strict, true) do
      extra = MapSet.difference(got.not_checked, want_nc)

      assert MapSet.size(extra) == 0,
             "#{id}: unexpectedly not checked: #{inspect(Enum.sort(extra))}"
    end

    case exp["nppes"] do
      "ok" ->
        assert got.nppes == "ok", "#{id}: NPPES #{inspect(got.nppes)}, expected ok"

      reason ->
        assert got.nppes != "ok" and String.contains?(got.nppes, reason),
               "#{id}: NPPES #{inspect(got.nppes)}, expected #{inspect(reason)}"
    end
  end

  # Replaces the active business rules with one rule holding a whole rules
  # file, as when every rule in it has been saved on the Rules page.
  defp use_rules_file(rel) do
    Repo.update_all(BusinessRule, set: [active: false])
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert!(%BusinessRule{
      name: Path.basename(rel, ".dsl"),
      rule_text: MockData.read!(rel),
      active: true,
      inserted_at: now,
      updated_at: now
    })
  end

  # --- Uploading ---

  @doc """
  Uploads files through the home page's Manual Upload form and waits for
  evaluation. `files` are mock_data paths or `{name, content}` pairs.

  Returns the view, the upload message, the batches the upload created and
  `claims`: claim_id => %{status, matched, not_checked, nppes, file}, with
  rule names as the database names them.
  """
  def upload(conn, files) do
    before = Repo.aggregate(Batch, :max, :id) || 0
    {:ok, view, _html} = live(conn, "/")
    upload_into(view, files, before)
  end

  @doc "Like `upload/2`, into a view already open (e.g. with a box ticked)."
  def upload_into(view, files, before \\ nil) do
    before = before || Repo.aggregate(Batch, :max, :id) || 0

    entries =
      Enum.map(files, fn
        {name, content} ->
          %{name: name, content: content, type: "application/octet-stream"}

        rel ->
          %{
            name: Path.basename(rel),
            content: MockData.read!(rel),
            type: "application/octet-stream"
          }
      end)

    # One file_input per file: several entries in one input don't all reach
    # the view in LiveViewTest.
    Enum.each(entries, fn entry ->
      view
      |> file_input("#manual-upload-form", :manual_files, [entry])
      |> render_upload(entry.name)
    end)

    view |> form("#manual-upload-form") |> render_submit()

    # Evaluation ran inline during the submit and broadcast its result back
    # to the view; render again so the view has handled it.
    render(view)

    batches = Repo.all(from(b in Batch, where: b.id > ^before, order_by: b.id))
    %{view: view, message: upload_message(view), batches: batches, claims: claims_in(batches)}
  end

  @doc "The text of the upload status message, or \"\" when none is shown."
  def upload_message(view) do
    if has_element?(view, "#upload-message"),
      do:
        view
        |> element("#upload-message")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.text()
        |> String.trim(),
      else: ""
  end

  defp claims_in(batches) do
    names = rule_name_map()

    batches
    |> Enum.flat_map(&Claims.list_files_for_batch(&1.id))
    |> Map.new(fn f ->
      results = (f.evaluation_report || %{})["results"] || []
      {nppes, rules} = Enum.split_with(results, &(&1["resultRuleName"] == "NPPESProviderLookup"))
      name = &Map.get(names, &1["resultRuleName"], &1["resultRuleName"])

      {f.json_output["claim_id"],
       %{
         file: f.filename,
         status: f.status,
         matched: rules |> Enum.filter(& &1["resultMatched"]) |> MapSet.new(name),
         not_checked: rules |> Enum.filter(& &1["resultUndecided"]) |> MapSet.new(name),
         nppes:
           case nppes do
             [] -> "ok"
             [r | _] -> r["resultDetails"]
           end
       }}
    end)
  end

  # The engine reports rules by their DSL name (RULE high_value_claim); the
  # manifest uses the database name (HighValueClaim). A rules-file rule has
  # no database name and keeps its DSL name.
  defp rule_name_map do
    Claims.list_active_business_rules()
    |> Enum.flat_map(fn r ->
      case dsl_names(r) do
        [dsl] -> [{dsl, r.name}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  defp dsl_names(rule),
    do:
      Regex.scan(~r/^\s*RULE\s+(\w+)/m, rule.rule_text || "", capture: :all_but_first)
      |> List.flatten()

  defp active_rule_names do
    Enum.flat_map(Claims.list_active_business_rules(), fn r ->
      case dsl_names(r) do
        [_] -> [r.name]
        many -> many
      end
    end)
  end
end
