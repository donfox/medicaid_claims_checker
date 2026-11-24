# Runs every generated file in mock_data/ (the files listed in its
# manifest.json) through the same steps as a manual upload (zip extraction,
# transaction-set and claim splitting, X12 conversion, normalization), then
# the NPPES check and the rule engine with the active business rules from the
# dev database, and compares the outcome with the manifest.
#
# It uses the Phoenix app's own parsing code, so run it with mix from
# phoenix_web:
#
#   cd phoenix_web
#   RULE_ENGINE_SECRET=... mix run --no-start ../mock_data/tools/verify.exs
#   mix run --no-start ../mock_data/tools/verify.exs --only R5        # one use case
#   mix run --no-start ../mock_data/tools/verify.exs --only N         # one group
#   mix run --no-start ../mock_data/tools/verify.exs --large ../mock_data/zip_files/over_15000_claims/large_batch_15001.zip
#   mix run --no-start ../mock_data/tools/verify.exs --suite DIR      # e.g. a retagged copy
#
# --only keeps the cases in one use-case folder or group: R5 matches
# exact_thresholds, R matches claim_rule_checks. Folders and the EDI files
# have no ID in their names, so each ID is mapped to them below. --suite
# checks another directory with a manifest.json in the same format. A case
# with "rules" is evaluated against that rules file instead of the database
# rules.
#
# Needs Postgres (dev DB with seeded rules and an imported NPPES registry)
# and, except with --large, the engine at
# RULE_ENGINE_URL (default http://localhost:8080).
#
# Result per case: PASS, FAIL, XFAIL (a known_issue case that still fails) or
# XPASS (a known_issue case that now passes: remove its known_issue). Exits 1
# on any FAIL or XPASS.

alias MedicaidClaimsChecker.{Claims, Repo}
alias MedicaidClaimsChecker.Claims.{Evaluator, JsonClaim}
alias MedicaidClaimsChecker.X12.FileClaims
alias MedicaidClaimsChecker.Claims.PayloadBuilder

defmodule MockDataVerify do
  @moduledoc false

  # --- Ingestion: mirrors FetchSourceLive.Index (classify, extract zips,
  # read X12 with X12.FileClaims) so results match a manual upload. ---

  def ingest(path) do
    name = Path.basename(path)
    content = File.read!(path)

    entries =
      case Path.extname(name) |> String.downcase() do
        ".zip" -> unzip(content)
        _ -> [{name, content}]
      end

    entries
    |> Enum.reduce({[], []}, fn {fname, data}, {claims, failures} ->
      {c, f} =
        case Path.extname(fname) |> String.downcase() do
          ".json" -> json_file(fname, data)
          ext when ext in [".x12", ".edi"] -> x12_file(fname, data)
          _ -> {[], []}
        end

      {claims ++ c, failures ++ f}
    end)
    |> case do
      # Nothing to read (an empty, corrupt or text-only zip): the upload
      # page says this.
      {[], []} -> {[], ["No processable claims found. Supported file types: .json, .x12, .edi, .zip"]}
      result -> result
    end
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

  # Same parsing as a JSON upload: one claim, a list, or {"claims": [...]}.
  defp json_file(fname, data) do
    case JsonClaim.parse(data) do
      {:ok, claims, refused} ->
        {Enum.map(claims, &%{"filename" => fname, "claim" => &1}),
         Enum.map(refused, &"#{fname}: #{inspect(&1)}")}

      {:error, reason} ->
        {[], ["#{fname}: #{reason}"]}
    end
  end

  # The X12 reading uploads and scheduled fetches share (X12.FileClaims).
  # Stored claims go through Jason, so use string keys like the DB does.
  defp x12_file(fname, content) do
    {claims, problems} = FileClaims.claims(fname, content)

    {Enum.map(claims, &%{"filename" => fname, "claim" => &1["claim"] |> Jason.encode!() |> Jason.decode!()}),
     Enum.map(problems, &"#{&1["filename"]}: #{&1["reason"]}")}
  end

  # --- Engine ---

  # {name, dsl name, text} for each rule in a rules file; names are DSL names.
  def file_rules(path) do
    text = File.read!(path)
    names = Regex.scan(~r/^RULE\s+(\w+)/m, text, capture: :all_but_first) |> List.flatten()
    [{names, nil, text}]
  end

  def rule_names(rules), do: Enum.flat_map(rules, fn {name, _, _} -> List.wrap(name) end)

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

{opts, _} = OptionParser.parse!(System.argv(), strict: [large: :string, suite: :string, only: :string])

Application.put_env(:medicaid_claims_checker, Repo, Keyword.put(Application.get_env(:medicaid_claims_checker, Repo), :pool_size, 2))
{:ok, _} = Application.ensure_all_started([:postgrex, :ecto_sql, :req])
{:ok, _} = Repo.start_link()

suite_dir = opts[:suite] || Path.expand("..", Path.dirname(__ENV__.file))

if path = opts[:large] do
  meta = path |> String.replace_suffix(".zip", ".json") |> File.read!() |> JSON.decode!()
  {micros, {claims, failures}} = :timer.tc(fn -> MockDataVerify.ingest(path) end)
  count = length(claims)
  over_cap = count > Evaluator.max_batch_claims()

  IO.puts("#{path}: #{count} claims translated in #{div(micros, 1_000_000)}s, #{length(failures)} failures")
  IO.puts("Evaluator cap #{Evaluator.max_batch_claims()}: batch would be #{if over_cap, do: "REFUSED", else: "accepted"}")
  ok = count == meta["expect"]["claim_count"] and over_cap == meta["expect"]["over_cap"] and failures == []
  IO.puts(if ok, do: "PASS", else: "FAIL (expected #{inspect(meta["expect"])})")
  System.halt(if ok, do: 0, else: 1)
end

manifest = Path.join(suite_dir, "manifest.json") |> File.read!() |> JSON.decode!()
only = opts[:only]

folder_ids = %{
  "x12_files" => "X",
  "837p_professional" => "X1",
  "837i_institutional" => "X2",
  "dental.x12" => "X3",
  "three_claims.x12" => "X4",
  "two_claims_same_subscriber.x12" => "X4",
  "two_transaction_sets.x12" => "X5",
  "no_newlines.x12" => "X6",
  "crlf_line_endings.x12" => "X6",
  "broken_envelope_or_file" => "X7",
  "zip_files" => "Z",
  "edi_extension" => "E",
  "clean_claim.edi" => "E1",
  "alternate_delimiters.edi" => "E2",
  "not_x12.edi" => "E3",
  "json_files" => "J",
  "routine_office_visit.json" => "J1",
  "two_claims.json" => "J2",
  "claims_wrapper" => "J3",
  "list_with_bad_entries.json" => "J4",
  "patient_record.json" => "J5",
  "rules_text_and_claims.json" => "J6",
  "invalid_json.json" => "J7",
  "dental_837d.json" => "J8",
  "institutional_837i.json" => "J8",
  "nppes_provider_checks" => "N",
  "bad_checksum.x12" => "N2",
  "nine_digit_npi.x12" => "N2",
  "unissued_npi.json" => "N3",
  "unissued_npi.x12" => "N3",
  "deactivated_provider.json" => "N4",
  "deactivated_provider.x12" => "N4",
  "service_before_deactivation.x12" => "N5",
  "deactivated_mid_claim.x12" => "N6",
  "reactivated_provider" => "N7",
  "before_enumeration.json" => "N8",
  "dropped_provider.json" => "N9",
  "missing_billing_npi.x12" => "N10",
  "rendering_npi_deactivated.x12" => "N11",
  "rules_page" => "P",
  "redundancy_levels" => "P2",
  "claim_rule_checks" => "R",
  "clean_claim" => "R1",
  "each_rule_alone" => "R2",
  "several_rules" => "R3",
  "problem_on_second_line" => "R4",
  "exact_thresholds" => "R5",
  "weekend_office_variants" => "R6",
  "inpatient_weekend.x12" => "R7",
  "inpatient_weekend_stay.json" => "R7",
  "missing_taxonomy_new_provider.x12" => "R9",
  "age_out_of_range_or_missing_dob" => "R10",
  "replacement_or_void_claim" => "R11",
  "mixed_file_types.zip" => "Z1",
  "two_json_claims.zip" => "Z2",
  "path_traversal.zip" => "Z3",
  "empty.zip" => "Z4",
  "text_files_only.zip" => "Z4",
  "zip_inside_zip.zip" => "Z5",
  "corrupt.zip" => "Z6",
  "over_15000_claims" => "Z7"
}

cases =
  Enum.filter(manifest["cases"], fn c ->
    is_nil(only) or
      c["file"] |> Path.dirname() |> Path.split() |> Enum.any?(&String.starts_with?(&1, only <> "_")) or
      c["file"] |> Path.split() |> Enum.any?(&(folder_ids[&1] == only))
  end)

if cases == [], do: raise("no cases match --only #{only}")
files_dir = suite_dir

ingested =
  Map.new(cases, fn c -> {c["file"], MockDataVerify.ingest(Path.join(files_dir, c["file"]))} end)

# Cases naming a rules file are evaluated against it; the rest against the
# active database rules. Only database-rule cases must list every rule that
# comes back "not checked": a rules file may test fields a claim lacks.
outcome_by_claim =
  cases
  |> Enum.group_by(& &1["rules"])
  |> Enum.flat_map(fn {rules_file, group} ->
    rules =
      if rules_file,
        do: MockDataVerify.file_rules(Path.join(suite_dir, rules_file)),
        else: MockDataVerify.active_rules()

    active = MapSet.new(MockDataVerify.rule_names(rules))
    db_name = Map.new(rules, fn {name, dsl, _} -> {dsl, name} end) |> Map.delete(nil)
    claims = Enum.flat_map(group, fn c -> elem(ingested[c["file"]], 0) end)
    results = MockDataVerify.evaluate(rules, Enum.map(claims, & &1["claim"]))
    claims |> Enum.zip(results) |> Enum.map(fn {c, result} -> {c, result, active, db_name, is_nil(rules_file)} end)
  end)
  |> Map.new(fn {%{"claim" => claim}, result, active, db_name, strict} ->
    rs = get_in(result, ["report", "results"]) || []
    names = fn pred -> rs |> Enum.filter(pred) |> Enum.map(&Map.get(db_name, &1["resultRuleName"], &1["resultRuleName"])) |> MapSet.new() end

    nppes =
      case Claims.validate_claim_providers(claim) do
        :ok -> "ok"
        {:reject, reason} -> reason
      end

    {claim["claim_id"],
     %{
       matched: names.(& &1["resultMatched"]),
       not_checked: names.(& &1["resultUndecided"]),
       nppes: nppes,
       active: active,
       strict: strict
     }}
  end)

check_claim = fn exp ->
  id = exp["claim_id"]

  case outcome_by_claim[id] do
    nil ->
      ["#{id}: no claim produced"]

    got ->
      want = exp["matched"] |> Enum.filter(&MapSet.member?(got.active, &1)) |> MapSet.new()
      want_nc = (exp["not_checked"] || []) |> Enum.filter(&MapSet.member?(got.active, &1)) |> MapSet.new()
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
        |> then(fn p ->
          extra = MapSet.difference(got.not_checked, want_nc)
          if not got.strict or MapSet.size(extra) == 0, do: p, else: p ++ ["#{id}: unexpectedly not checked: #{fmt.(extra)}"]
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
  case outcome_by_claim |> Map.values() |> Enum.map(& &1.not_checked) do
    # Only files with no claims selected (e.g. --only X7).
    [] -> MapSet.new()
    sets -> Enum.reduce(sets, &MapSet.intersection/2)
  end

counts = report |> Enum.frequencies_by(&elem(&1, 1))
active_count = MockDataVerify.active_rules() |> length()
IO.puts("\n#{length(cases)} cases, #{map_size(outcome_by_claim)} claims, #{active_count} active rules")
IO.puts(~w(PASS FAIL XFAIL XPASS) |> Enum.map(&"#{&1} #{Map.get(counts, &1, 0)}") |> Enum.join("  "))
if MapSet.size(always_nc) > 0, do: IO.puts("Not checked on every claim: #{always_nc |> Enum.sort() |> Enum.join(", ")}")

System.halt(if Map.get(counts, "FAIL", 0) + Map.get(counts, "XPASS", 0) == 0, do: 0, else: 1)
