# Runs every file in test/fixtures/x12_suite/files through the same steps as
# a manual upload (zip extraction, transaction-set and claim splitting, X12
# conversion, normalization), then the NPPES check and the rule engine with
# the active business rules from the dev database, and compares the outcome
# with manifest.json.
#
#   cd phoenix_web
#   RULE_ENGINE_SECRET=... mix run --no-start test/scripts/verify_x12_suite.exs
#   mix run --no-start test/scripts/verify_x12_suite.exs --large test/fixtures/x12_suite/files/large/large_batch_15000.zip
#
# Needs Postgres (dev DB, seeded) and, except with --large, the engine at
# RULE_ENGINE_URL (default http://localhost:8080).
#
# Result per case: PASS, FAIL, XFAIL (a known_issue case that still fails) or
# XPASS (a known_issue case that now passes: remove its known_issue). Exits 1
# on any FAIL or XPASS.

alias MedicaidClaimsChecker.{Claims, Repo}
alias MedicaidClaimsChecker.Claims.Evaluator
alias MedicaidClaimsChecker.X12.{ClaimSplitter, Converter, SegmentMapper}
alias MedicaidClaimsCheckerWeb.RuleLive.PayloadBuilder

defmodule X12SuiteVerify do
  @moduledoc false

  # --- Ingestion: mirrors FetchSourceLive.Index (classify, extract zips,
  # translate_x12_file) so results match a manual upload. ---

  def ingest(path) do
    name = Path.basename(path)
    content = File.read!(path)

    entries =
      case Path.extname(name) |> String.downcase() do
        ".zip" -> unzip(content)
        _ -> [{name, content}]
      end

    Enum.reduce(entries, {[], []}, fn {fname, data}, {claims, failures} ->
      {c, f} =
        case Path.extname(fname) |> String.downcase() do
          ".json" -> json_file(fname, data)
          ext when ext in [".x12", ".edi"] -> x12_file(fname, data)
          _ -> {[], []}
        end

      {claims ++ c, failures ++ f}
    end)
  end

  defp unzip(content) do
    case :zip.unzip(content, [:memory]) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn {name, data} ->
          case Path.safe_relative(to_string(name)) do
            {:ok, safe} -> [{safe, data}]
            :error -> []
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp json_file(fname, data) do
    case JSON.decode(data) do
      {:ok, claim} -> {[%{"filename" => fname, "claim" => SegmentMapper.normalize(claim)}], []}
      {:error, _} -> {[], ["#{fname}: invalid JSON"]}
    end
  end

  defp x12_file(fname, content) do
    case ClaimSplitter.split_transaction_sets(content) do
      {:ok, nil} ->
        x12_single(fname, content)

      {:ok, parts} ->
        Enum.reduce(parts, {[], []}, fn part, {c, f} ->
          {c2, f2} = x12_single(fname, part)
          {c ++ c2, f ++ f2}
        end)

      {:error, reason} ->
        {[], ["#{fname}: #{reason}"]}
    end
  end

  defp x12_single(fname, content) do
    case ClaimSplitter.split_claims_to_x12(content) do
      {:ok, nil} ->
        case translate(content) do
          {:ok, claim} -> {[%{"filename" => fname, "claim" => claim}], []}
          {:error, reason} -> {[], ["#{fname}: #{reason}"]}
        end

      {:ok, parts} ->
        Enum.reduce(parts, {[], []}, fn %{claim_id: cid, x12_content: x12}, {c, f} ->
          case translate(x12) do
            {:ok, claim} -> {c ++ [%{"filename" => fname, "claim" => claim}], f}
            {:error, reason} -> {c, f ++ ["#{fname} (claim #{cid}): #{reason}"]}
          end
        end)

      {:error, reason} ->
        {[], ["#{fname}: #{reason}"]}
    end
  end

  defp translate(x12) do
    with {:ok, flat} <- Converter.convert_content(x12),
         {:ok, semantic} <- SegmentMapper.map_from_json(flat) do
      # Stored claims go through Jason, so use string keys like the DB does.
      {:ok, semantic |> Jason.encode!() |> Jason.decode!()}
    end
  end

  # --- Engine ---

  def active_rules do
    Claims.list_active_business_rules()
    |> Enum.map(fn r ->
      text = String.trim(r.rule_text || "")
      dsl = case Regex.run(~r/RULE\s+(\w+)/, text), do: ([_, n] -> n; _ -> r.name)
      {r.name, dsl, text}
    end)
    |> Enum.reject(fn {_, _, t} -> t == "" end)
  end

  def evaluate(rules, claims) do
    url = Application.get_env(:medicaid_claims_checker, :rule_engine_url, "http://localhost:8080")
    secret = Application.get_env(:medicaid_claims_checker, :rule_engine_secret, "")
    rules_text = rules |> Enum.map(&elem(&1, 2)) |> Enum.join("\n\n")

    claims
    |> Enum.chunk_every(200)
    |> Enum.flat_map(fn chunk ->
      body = Jason.encode!(PayloadBuilder.build_batch_evaluate_payload(rules_text, chunk))

      resp =
        Req.post!("#{url}/api/batch-evaluate",
          body: body,
          headers: [{"content-type", "application/json"}, {"authorization", "Bearer #{secret}"}],
          receive_timeout: 120_000,
          retry: false
        )

      if resp.status != 200, do: raise("engine returned #{resp.status}: #{inspect(resp.body)}")
      body = if is_binary(resp.body), do: Jason.decode!(resp.body), else: resp.body
      body["batchResults"]
    end)
  end
end

{opts, _} = OptionParser.parse!(System.argv(), strict: [large: :string])

Application.put_env(:medicaid_claims_checker, Repo, Keyword.put(Application.get_env(:medicaid_claims_checker, Repo), :pool_size, 2))
{:ok, _} = Application.ensure_all_started([:postgrex, :ecto_sql, :req])
{:ok, _} = Repo.start_link()

suite_dir = "test/fixtures/x12_suite"

if path = opts[:large] do
  meta = path |> String.replace_suffix(".zip", ".json") |> File.read!() |> JSON.decode!()
  {micros, {claims, failures}} = :timer.tc(fn -> X12SuiteVerify.ingest(path) end)
  count = length(claims)
  over_cap = count > Evaluator.max_batch_claims()

  IO.puts("#{path}: #{count} claims translated in #{div(micros, 1_000_000)}s, #{length(failures)} failures")
  IO.puts("Evaluator cap #{Evaluator.max_batch_claims()}: batch would be #{if over_cap, do: "REFUSED", else: "accepted"}")
  ok = count == meta["expect"]["claim_count"] and over_cap == meta["expect"]["over_cap"] and failures == []
  IO.puts(if ok, do: "PASS", else: "FAIL (expected #{inspect(meta["expect"])})")
  System.halt(if ok, do: 0, else: 1)
end

manifest = Path.join(suite_dir, "manifest.json") |> File.read!() |> JSON.decode!()
cases = manifest["cases"]

ingested =
  Map.new(cases, fn c -> {c["file"], X12SuiteVerify.ingest(Path.join([suite_dir, "files", c["file"]]))} end)

rules = X12SuiteVerify.active_rules()
active = MapSet.new(rules, &elem(&1, 0))
db_name = Map.new(rules, fn {name, dsl, _} -> {dsl, name} end)

all_claims = cases |> Enum.flat_map(fn c -> elem(ingested[c["file"]], 0) end)
results = X12SuiteVerify.evaluate(rules, Enum.map(all_claims, & &1["claim"]))

outcome_by_claim =
  all_claims
  |> Enum.zip(results)
  |> Map.new(fn {%{"claim" => claim}, result} ->
    rs = get_in(result, ["report", "results"]) || []
    names = fn pred -> rs |> Enum.filter(pred) |> Enum.map(&Map.get(db_name, &1["resultRuleName"], &1["resultRuleName"])) |> MapSet.new() end

    nppes =
      case Claims.validate_claim_providers(claim) do
        :ok -> "ok"
        {:reject, reason} -> reason
      end

    {claim["claim_id"],
     %{matched: names.(& &1["resultMatched"]), not_checked: names.(& &1["resultUndecided"]), nppes: nppes}}
  end)

check_claim = fn exp ->
  id = exp["claim_id"]

  case outcome_by_claim[id] do
    nil ->
      ["#{id}: no claim produced"]

    got ->
      want = exp["matched"] |> Enum.filter(&MapSet.member?(active, &1)) |> MapSet.new()
      want_nc = (exp["not_checked"] || []) |> Enum.filter(&MapSet.member?(active, &1)) |> MapSet.new()
      fmt = fn set -> set |> Enum.sort() |> Enum.join(", ") end

      problems =
        []
        |> then(fn p ->
          if got.matched == want, do: p,
          else: p ++ ["#{id}: matched [#{fmt.(got.matched)}], expected [#{fmt.(want)}]"]
        end)
        |> then(fn p ->
          missing = MapSet.difference(want_nc, got.not_checked)
          if MapSet.size(missing) == 0, do: p, else: p ++ ["#{id}: expected not checked: #{fmt.(missing)}"]
        end)

      nppes_ok =
        if exp["nppes"] == "ok", do: got.nppes == "ok",
        else: got.nppes != "ok" and String.contains?(got.nppes, exp["nppes"])

      if nppes_ok, do: problems,
      else: problems ++ ["#{id}: NPPES #{inspect(got.nppes)}, expected #{inspect(exp["nppes"])}"]
  end
end

report =
  Enum.map(cases, fn c ->
    {claims, failures} = ingested[c["file"]]
    expect = c["expect"]
    got_ids = claims |> Enum.map(& &1["claim"]["claim_id"]) |> Enum.sort()

    problems =
      cond do
        err = expect["error"] ->
          hit = Enum.any?(failures, &String.contains?(String.downcase(&1), String.downcase(err)))
          if claims == [] and hit, do: [],
          else: ["expected an error containing #{inspect(err)}; got #{length(claims)} claim(s) #{inspect(got_ids)}, failures #{inspect(failures)}"]

        true ->
          want_ids = expect["claims"] |> Enum.map(& &1["claim_id"]) |> Enum.sort()
          id_problem = if got_ids == want_ids, do: [], else: ["claims #{inspect(got_ids)}, expected #{inspect(want_ids)}"]
          id_problem ++ Enum.flat_map(expect["claims"], check_claim) ++ Enum.map(failures, &"translation failure: #{&1}")
      end

    status =
      case {problems, c["known_issue"]} do
        {[], nil} -> "PASS"
        {[], _} -> "XPASS"
        {_, nil} -> "FAIL"
        {_, _} -> "XFAIL"
      end

    {c, status, problems}
  end)

Enum.each(report, fn {c, status, problems} ->
  IO.puts(String.pad_trailing(status, 6) <> c["file"])
  if status in ["FAIL", "XFAIL", "XPASS"], do: Enum.each(problems, &IO.puts("        " <> &1))
  if status == "XFAIL", do: IO.puts("        known issue: " <> c["known_issue"])
  if status == "XPASS", do: IO.puts("        now passes — remove known_issue: " <> c["known_issue"])
end)

always_nc =
  outcome_by_claim |> Map.values() |> Enum.map(& &1.not_checked) |> Enum.reduce(&MapSet.intersection/2)

counts = report |> Enum.frequencies_by(&elem(&1, 1))
IO.puts("\n#{length(cases)} cases, #{map_size(outcome_by_claim)} claims, #{MapSet.size(active)} active rules")
IO.puts(~w(PASS FAIL XFAIL XPASS) |> Enum.map(&"#{&1} #{Map.get(counts, &1, 0)}") |> Enum.join("  "))
if MapSet.size(always_nc) > 0, do: IO.puts("Not checked on every claim: #{always_nc |> Enum.sort() |> Enum.join(", ")}")

System.halt(if Map.get(counts, "FAIL", 0) + Map.get(counts, "XPASS", 0) == 0, do: 0, else: 1)
